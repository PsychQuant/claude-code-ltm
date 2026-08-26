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
    /// 一筆 reinforcement 事件（`opened`/`cited`/`pinned`）擴散給同框呈現、
    /// 但未被直接互動的 anchor 的比例。0 等於關閉擴散。**不對 `dismissed`
    /// 生效**——見 `project(_:at:resolvedBy:parameters:)` 的擴散那一段與
    /// #15 design.md 的理由。
    ///
    /// **這個值找不到 AI4o 原始出處。** 動手實作前查過
    /// `PsychQuant/ai4o` 的 `docs/memory/implementation/`，沒有找到對應的
    /// spreading-activation 設定（該 repo 的 recall boost 機制與這裡要做的
    /// 共現擴散不是同一件事）。所以這裡的預設值**不是**沿用 AI4o 的參數
    /// （與其他四個參數的來源不同），是本次實作挑的一個保守估計，同樣
    /// 完全未經本語料驗證。
    ///
    /// **必須嚴格小於 1**（下方 `init` 的 precondition 執行這件事）。這個
    /// 保證的範圍是**逐筆貢獻**：每一筆擴散貢獻（`factor * entry.contribution`）
    /// 嚴格小於它衍生自的那筆直接互動貢獻（`entry.contribution`）——這件事
    /// factor < 1 就足以保證，不需要更多。**這個保證不涵蓋一個 anchor 的
    /// 總 reinforcement**：一個 anchor 若同框於多個群組、各自收到不同來源的
    /// 擴散貢獻，加總起來仍可能超過任一單筆直接互動的量（#15 fix-round-2
    /// verify devils-advocate finding：先前的宣稱沒有區分「逐筆」與「總量」，
    /// 讀起來像是在保證後者，而 factor < 1 這件事本身修不好那個更強的宣稱）。
    public let spreadingActivationFactor: Double

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
        dismissedWeight: Double = 2.0,
        spreadingActivationFactor: Double = 0.3
    ) {
        // 參數是程式／設定層的東西，錯了是程式錯誤 → trap（#1 verify R5）。
        // 先前完全不驗，於是：`decayExponent: -1` 讓「衰減」變成越舊權重越大；
        // `openedWeight: -1` 讓一個增強事件產生負 reinforcement；任何一個 NaN
        // 都會讓強度比較恆偽、策略靜默退化成 archival。同一條紀律套用到
        // `spreadingActivationFactor`（#15）——它一樣是外部可控的乘數。
        for (name, value) in [
            ("decayExponent", decayExponent), ("openedWeight", openedWeight),
            ("citedWeight", citedWeight), ("pinnedWeight", pinnedWeight),
            ("dismissedWeight", dismissedWeight),
            ("spreadingActivationFactor", spreadingActivationFactor),
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
        // **必須嚴格小於 1**，否則「每筆擴散貢獻嚴格小於它衍生自的直接互動貢獻」
        // 這條 memory-events spec 的 SHALL 不成立（factor == 1 讓兩者相等，不是
        // 嚴格小於）。先前沒有這條 precondition，design.md 卻宣稱它存在
        // （#15 fix-round-2 verify finding）——這條 precondition 補上後那句話
        // 才是真的，但只涵蓋逐筆貢獻，見上方欄位說明。
        precondition(
            spreadingActivationFactor < 1,
            "ProjectionParameters.spreadingActivationFactor 必須 < 1（否則擴散貢獻不會嚴格小於"
                + "它衍生自的直接互動貢獻），實得 \(spreadingActivationFactor)")
        self.decayExponent = decayExponent
        self.openedWeight = openedWeight
        self.citedWeight = citedWeight
        self.pinnedWeight = pinnedWeight
        self.dismissedWeight = dismissedWeight
        self.spreadingActivationFactor = spreadingActivationFactor
    }

    public static let `default` = ProjectionParameters()
}

/// 擴散生效的同框呈現群組大小上限。**防禦性上限，非校準值**——見
/// `project(_:at:resolvedBy:parameters:)` 擴散那一段的用法與理由
/// （add-spreading-activation-fixes Decision 4）。
///
/// **設在 2000，不是 50**（#15 fix-round-2 verify finding）：`ltm query --k`
/// 有文件支援的上限是 1000（`Sources/ltm/Commands.swift` 驗證範圍 1–1000），
/// 原本挑的 50 比這個上限低了 20 倍——任何用到 `--k` 中段以上的正常查詢，
/// 都會在完全合規的使用下靜默關掉整組擴散，而不是只在異常情況觸發。
/// 2000 高於文件支援的上限、留有餘裕，讓這個上限只防禦超出 CLI 能產生範圍
/// 的群組（竄改或損壞的事件檔）。
private let maxSpreadingGroupSize = 2000

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
    key: AnchorKey,
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
        let live = anchor.dereference(in: corpus, key: key).resolvedText != nil
        orphanCache[anchor] = live
        return live
    }

    var orphaned: Set<Anchor> = []
    var futureDated = 0
    // 擴散激發（spreading activation，#15）的兩個輸入，跟主迴圈**同一遍**蒐集：
    //
    // - `presentationGroups`：哪些 anchor 曾經同框呈現過。任何帶 `presentation`
    //   的存活事件都算數，不限事件種類——目前生產路徑只有 `.shown` 會帶這個
    //   欄位，但邊界不寫死在「只看 shown」，未來 deliberate 事件（Stage 2 MCP，
    //   #24）帶著同一個識別碼出現時，這個群組會自動吃到。
    // - `deliberateContributions`：每一筆 reinforcement 來源事件（`opened`/
    //   `cited`/`pinned`）自己的（anchor、呈現群組、已套衰減的權重貢獻）。
    //   `dismissed` 刻意不收集——擴散只做 reinforcement，理由見 design.md。
    //
    // 兩者都只收「已經通過未來時間戳與 orphan 兩道檢查」的事件——跟主迴圈
    // 共用同一份過濾，不是另開一遍重新判斷。
    var presentationGroups: [PresentationID: Set<Anchor>] = [:]
    var deliberateContributions: [(anchor: Anchor, group: PresentationID, contribution: Double)] = []
    // 排除擴散目標用**事件是否存在**判斷，不是 `suppression` 的數值大小
    // （#15 fix-round-2 verify finding）：`dismissedWeight: 0` 是合法參數值，
    // 這種設定下 `suppression[anchor]` 恆為 0，magnitude-based 判斷會靜默
    // 放行。與 `MemoryStrategy.swift` 的 `RankingReason.History.none` 記過的
    // 同一個混淆——用權重算出來的數值代理事件本身的存在。
    var dismissedAnchors: Set<Anchor> = []
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

        if let group = event.presentation {
            presentationGroups[group, default: []].insert(event.anchor)
        }

        switch event.kind {
        case .shown:
            // 曝光不增強。計數只為了當分母——把它算進增強會形成
            // 「出現過就更容易再出現」的迴圈，與有沒有用無關。
            impressions[event.anchor, default: 0] += 1
        case .opened:
            let contribution = parameters.openedWeight * decay
            reinforcement[event.anchor, default: 0] += contribution
            lastDeliberate[event.anchor] = max(lastDeliberate[event.anchor] ?? .distantPast, event.timestamp)
            if let group = event.presentation {
                deliberateContributions.append((event.anchor, group, contribution))
            }
        case .cited:
            let contribution = parameters.citedWeight * decay
            reinforcement[event.anchor, default: 0] += contribution
            lastDeliberate[event.anchor] = max(lastDeliberate[event.anchor] ?? .distantPast, event.timestamp)
            if let group = event.presentation {
                deliberateContributions.append((event.anchor, group, contribution))
            }
        case .pinned:
            let contribution = parameters.pinnedWeight * decay
            reinforcement[event.anchor, default: 0] += contribution
            lastDeliberate[event.anchor] = max(lastDeliberate[event.anchor] ?? .distantPast, event.timestamp)
            if let group = event.presentation {
                deliberateContributions.append((event.anchor, group, contribution))
            }
        case .dismissed:
            // 擴散刻意不涵蓋 dismissed：見 design.md「Spreading activation is
            // a second pass」段落——把「同框但未互動」的 anchor 也標成較差，
            // 是遠比 reinforcement 擴散更重的宣稱，本次不做。
            suppression[event.anchor, default: 0] += parameters.dismissedWeight * decay
            lastDeliberate[event.anchor] = max(lastDeliberate[event.anchor] ?? .distantPast, event.timestamp)
            // 記事件是否存在，跟 `suppression` 的數值分開——`dismissedWeight`
            // 可以合法設成 0，那時 `suppression` 讀不出「這個 anchor 曾被
            // dismissed」這件事，但這個集合讀得出。
            dismissedAnchors.insert(event.anchor)
        }
    }

    // 擴散激發：每一筆 reinforcement 來源事件，把它的（已衰減）貢獻乘上
    // `spreadingActivationFactor`，分給同框呈現裡**其他**存活的 anchor。
    // 只做一跳——這裡讀的是 `deliberateContributions`（主迴圈蒐集的原始
    // 事件貢獻），不是 spreading 之後的 `reinforcement`，所以一個 anchor
    // 收到的擴散不會再被當成新的擴散來源。
    for entry in deliberateContributions {
        guard let members = presentationGroups[entry.group] else { continue }
        // 群組大小超過防禦性上限時整體跳過擴散——不是無界放大，是視為異常
        // （add-spreading-activation-fixes Decision 4）。上限本身（`maxSpreadingGroupSize`
        // 常數，目前 2000）的選值理由見該常數上方的文件註解，不在這裡重複——
        // fix-round-3 verify 抓到這裡曾經留著已經過時的「50」，跟常數本身不符。
        guard members.count <= maxSpreadingGroupSize else { continue }
        for other in members where other != entry.anchor {
            guard isLive(other) else { continue }
            // 已被使用者明確 dismissed 的 anchor 不再接受擴散：那是一個明確的負面
            // 訊號，不該被同框的正面訊號部分抵銷（add-spreading-activation-fixes
            // Decision 4）。用「dismissed 事件是否存在」判斷，不是 `suppression`
            // 的數值——`dismissedWeight: 0` 是合法設定，數值判斷在那種情況下
            // 會靜默放行（#15 fix-round-2 verify finding）。
            guard !dismissedAnchors.contains(other) else { continue }
            reinforcement[other, default: 0] += parameters.spreadingActivationFactor * entry.contribution
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
