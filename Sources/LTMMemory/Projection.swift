import Foundation
import LTMCore

// `AnchorStatistics` 與 `Projection` 這兩個型別住在 LTMCore，見該檔的說明：
// 那是為了讓 LTMQuery 收得下 projection 卻依賴不到事件存放。摺疊的動作
// （下面的 `project`）留在這一層，因為它要讀事件。

/// projection 的可調參數。
///
/// 全部是衍生層的東西，改了不影響任何既存事件——這就是把它們留成參數的理由。
public struct ProjectionParameters: Sendable, Equatable {
    /// 冪次衰減指數。`weight * (1 + ageDays)^(-exponent)`。
    public let decayExponent: Double
    public let openedWeight: Double
    public let citedWeight: Double
    public let pinnedWeight: Double
    public let dismissedWeight: Double

    /// **這些預設值全部未經校準，方向也未知。**
    ///
    /// 形式（power-law decay）沿用 `PsychQuant/ai4o` 的
    /// `docs/memory/implementation/`，那套已按 Wixted & Ebbesen (1991) 調過；
    /// 但**參數值是在日常聊天語料上調的**，而本專案是技術對話，性質差很多。
    /// 在評估集就緒之前沒有任何證據支持任何特定數字（#1 verify R5：先前這裡
    /// 沒有任何標記，而 diff 同時刪掉了 README 裡記載出處的那一段）。
    public init(
        decayExponent: Double = 0.5,
        openedWeight: Double = 1.0,
        citedWeight: Double = 2.0,
        pinnedWeight: Double = 3.0,
        dismissedWeight: Double = 2.0
    ) {
        // 參數是程式／設定層的東西，錯了是程式錯誤 → trap（#1 verify R5）。
        // 先前完全不驗，於是：`decayExponent: -1` 讓「衰減」變成越舊權重越大；
        // `openedWeight: -1` 讓一個增強事件產生負 reinforcement；任何一個 NaN
        // 都會讓強度比較恆偽、策略靜默退化成 archival。
        for (name, value) in [
            ("decayExponent", decayExponent), ("openedWeight", openedWeight),
            ("citedWeight", citedWeight), ("pinnedWeight", pinnedWeight),
            ("dismissedWeight", dismissedWeight),
        ] {
            precondition(value.isFinite, "ProjectionParameters.\(name) 必須是有限值，實得 \(value)")
            precondition(value >= 0, "ProjectionParameters.\(name) 不得為負，實得 \(value)")
        }
        // **指數必須嚴格為正。** `pow(1 + ageDays, -0) == 1`，也就是完全沒有衰減
        // ——而 spec 的 SHALL 是「同一事件於較晚時點必須嚴格較小」，那條需求存在的
        // 理由逐字是「否則一個線性計數、從不讀 timestamp 的實作也滿足所有其他
        // scenario」。零值讓一個合法的 `human-like` 設定移除掉它命名的核心機制
        // （#1 verify R7）。要「關掉衰減」得是另一個策略身分，不是這一檔的參數值。
        precondition(
            decayExponent > 0,
            "ProjectionParameters.decayExponent 必須 > 0（0 等於關閉衰減），實得 \(decayExponent)")
        self.decayExponent = decayExponent
        self.openedWeight = openedWeight
        self.citedWeight = citedWeight
        self.pinnedWeight = pinnedWeight
        self.dismissedWeight = dismissedWeight
    }

    public static let `default` = ProjectionParameters()
}

/// 把事件序列摺成 per-anchor 統計。
///
/// 三個輸入決定結果，沒有隱藏狀態、不寫入任何地方。需要 `corpus` 是因為
/// orphan 過濾放在 projection 這一層：文字已經不是當初那段的 anchor 不該
/// 貢獻任何強度，而要判斷這件事就得 dereference。
///
/// 這是函式不是模組：摺疊事件只有一種做法，沒有呼叫端需要替換它。真的長出
/// 快取或增量更新的生命週期時，再讓它升格。
public func project(
    _ events: [Event],
    at instant: Date,
    resolvedBy corpus: some CorpusReader,
    parameters: ProjectionParameters = .default
) -> Projection {
    var reinforcement: [Anchor: Double] = [:]
    var suppression: [Anchor: Double] = [:]
    var impressions: [Anchor: Int] = [:]
    var lastDeliberate: [Anchor: Date] = [:]
    var counts: [Anchor: [EventKind: Int]] = [:]
    var orphanCache: [Anchor: Bool] = [:]

    func isLive(_ anchor: Anchor) -> Bool {
        if let cached = orphanCache[anchor] { return cached }
        let live = anchor.dereference(in: corpus).resolvedText != nil
        orphanCache[anchor] = live
        return live
    }

    var orphaned: Set<Anchor> = []
    var futureDated = 0
    for event in events {
        // 評估時點之後的事件不可能已經發生。先前的 `max(0, ...)` 把未來時間戳
        // 夾成 age 0，也就是 decay = 1.0 的**最大權重，而且永遠維持**——竄改
        // 備份（或時鐘倒退）只要把 timestamp 寫到未來，就能把某筆結果永久釘在
        // 帶首（#1 verify R3）。夾成最大值是最糟的一種夾法。
        guard event.timestamp <= instant else {
            // **數出來，不要靜默丟掉**（#1 verify R5）。裸 `continue` 讓一個
            // 整段歷史都在未來的 anchor 與一個從沒被碰過的 anchor 完全無法
            // 區分，而上面那段註解自己指名的觸發情境（竄改備份、時鐘回捲）
            // 正是最不該看不見的那種。同一輪 `ComparisonScorer` 就是為了這個
            // 理由把它的四個 `continue` 拆開計數的，這裡當時沒有一起改。
            futureDated += 1
            continue
        }

        guard isLive(event.anchor) else {
            // 記下來而不是丟掉：策略必須能說出「這筆有歷史但已 orphan」，
            // 否則 design.md 的 never-silent 承諾在結構上無法履行。
            orphaned.insert(event.anchor)
            continue
        }

        let ageDays = max(0, instant.timeIntervalSince(event.timestamp)) / 86_400
        let decay = pow(1 + ageDays, -parameters.decayExponent)

        if event.kind != .shown {
            counts[event.anchor, default: [:]][event.kind, default: 0] += 1
        }

        switch event.kind {
        case .shown:
            // 曝光不增強。計數只為了當分母——把它算進增強會形成
            // 「出現過就更容易再出現」的迴圈，與有沒有用無關。
            impressions[event.anchor, default: 0] += 1
        case .opened:
            reinforcement[event.anchor, default: 0] += parameters.openedWeight * decay
            lastDeliberate[event.anchor] = max(lastDeliberate[event.anchor] ?? .distantPast, event.timestamp)
        case .cited:
            reinforcement[event.anchor, default: 0] += parameters.citedWeight * decay
            lastDeliberate[event.anchor] = max(lastDeliberate[event.anchor] ?? .distantPast, event.timestamp)
        case .pinned:
            reinforcement[event.anchor, default: 0] += parameters.pinnedWeight * decay
            lastDeliberate[event.anchor] = max(lastDeliberate[event.anchor] ?? .distantPast, event.timestamp)
        case .dismissed:
            suppression[event.anchor, default: 0] += parameters.dismissedWeight * decay
            lastDeliberate[event.anchor] = max(lastDeliberate[event.anchor] ?? .distantPast, event.timestamp)
        }
    }

    var statistics: [Anchor: AnchorStatistics] = [:]
    let touched = Set(reinforcement.keys)
        .union(suppression.keys)
        .union(impressions.keys)
    for anchor in touched {
        statistics[anchor] = AnchorStatistics(
            reinforcement: reinforcement[anchor] ?? 0,
            suppression: suppression[anchor] ?? 0,
            impressions: impressions[anchor] ?? 0,
            lastDeliberateInteraction: lastDeliberate[anchor],
            deliberateCounts: counts[anchor] ?? [:])
    }
    return Projection(
        statistics: statistics, instant: instant, orphanedAnchors: orphaned,
        futureDatedEventsIgnored: futureDated)
}
