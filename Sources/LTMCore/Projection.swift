import Foundation

/// 單一 anchor 的統計。**不會被寫回 store**——它是可重算的衍生值。
///
/// 這正是「存事件不存聚合值」那條決策的具體形狀：改公式只需要重跑 projection，
/// 不需要改任何一筆歷史紀錄。
public struct AnchorStatistics: Sendable, Equatable {
    /// 來自 opened／cited／pinned 的加權衰減和。永遠 ≥ 0。
    public let reinforcement: Double
    /// 來自 dismissed 的加權衰減和。以正值表示「壓抑的量」。
    public let suppression: Double
    /// shown 次數。只作為比較報告的分母，不參與排序。
    public let impressions: Int
    /// 最後一次 deliberate 互動的時間。
    public let lastDeliberateInteraction: Date?
    /// 各種 deliberate 事件各發生幾次。存在的理由是 reason 必須**指名**是哪個
    /// 訊號讓某筆結果上移——只給一個總分的話，provenance 就退化成「因為分數高」。
    public let deliberateCounts: [EventKind: Int]

    public init(
        reinforcement: Double, suppression: Double, impressions: Int,
        lastDeliberateInteraction: Date?, deliberateCounts: [EventKind: Int] = [:]
    ) {
        self.reinforcement = reinforcement
        self.suppression = suppression
        self.impressions = impressions
        self.lastDeliberateInteraction = lastDeliberateInteraction
        self.deliberateCounts = deliberateCounts
    }

    public var netStrength: Double { reinforcement - suppression }
}

/// 一次 projection 的結果。
///
/// 型別住在 LTMCore 而不是 LTMMemory，是為了讓 `LTMQuery` 能收下 projection
/// 卻**不必**依賴 LTMMemory——於是「retrieval 不得直接讀事件存放」從一條紀律
/// 少一個依賴：LTMQuery 看不到 `FileEventStore`。
///
/// **誠實邊界**：這只擋住那個便利型別。JSON Lines 的格式與 `Event: Codable`
/// 都在本模組，所以 LTMQuery 用 Foundation 仍能直接讀 canonical 事件檔——
/// #1 verify 的 devils-advocate 實測做到了。原本寫的「編譯期事實」是過度宣稱。
public struct Projection: Sendable, Equatable {
    public let statistics: [Anchor: AnchorStatistics]
    /// 產生這份 projection 的評估時點。留著是為了讓 reason 能誠實說明依據。
    public let instant: Date
    /// 有歷史、但 anchor 已 orphan 而被排除的那些。
    ///
    /// 存在的理由是 design.md 承諾「orphan **never** silently treated as a normal
    /// miss」。orphan 過濾發生在 projection，若不把這件事帶出來，策略在結構上
    /// 就不可能履行那個承諾——#1 verify 指出 `orphanedHistoryIgnored` 因此是一個
    /// 永不產生的死 case，而 spec delta 剛好被寫得比 design.md 弱、弱到與 code 相符。
    public let orphanedAnchors: Set<Anchor>

    public init(
        statistics: [Anchor: AnchorStatistics], instant: Date,
        orphanedAnchors: Set<Anchor> = []
    ) {
        // **orphan 的統計在建構時就被移除**，不是留著讓每個讀取端記得跳過。
        //
        // #1 verify R4：先前同一個 anchor 可以同時出現在 `statistics` 與
        // `orphanedAnchors`。策略排序只讀 `netStrength(for:)`（不看 orphan），
        // 所以一個高強度的 orphan **會真的被提升**；等到組 reason 時才回報
        // 「歷史已忽略」。同一筆結果因 orphan 歷史而移動、又聲稱該歷史被忽略。
        //
        // 更糟的是 spec 的 scenario 描述的**正是**這個輸入形狀（「GIVEN a
        // projection in which the most heavily reinforced anchor is orphaned」），
        // 而所有測試都用 `statistics: [:]` 建 Projection，所以沒有一條覆蓋它。
        // 目前只因為 `project(...)` 剛好不會產生重疊而倖免——但 `Projection` 是
        // seam 的公開輸入型別，不變式不能靠生產端的巧合維持。
        self.statistics = statistics.filter { !orphanedAnchors.contains($0.key) }
        self.instant = instant
        self.orphanedAnchors = orphanedAnchors
    }

    public subscript(anchor: Anchor) -> AnchorStatistics? { statistics[anchor] }

    /// 未知或 orphan 的 anchor 一律 0，而不是 nil 再讓每個呼叫端各自決定。
    public func reinforcement(for anchor: Anchor) -> Double {
        statistics[anchor]?.reinforcement ?? 0
    }

    public func netStrength(for anchor: Anchor) -> Double {
        statistics[anchor]?.netStrength ?? 0
    }

    /// 這個 anchor 有歷史，但因為 orphan 而不計入。
    public func isOrphaned(_ anchor: Anchor) -> Bool { orphanedAnchors.contains(anchor) }

    public static func empty(at instant: Date) -> Projection {
        Projection(statistics: [:], instant: instant)
    }
}
