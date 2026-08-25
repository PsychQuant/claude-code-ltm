import Foundation

/// 單一 anchor 的統計。**不會被寫回 store**——它是可重算的衍生值。
///
/// 這正是「存事件不存聚合值」那條決策的具體形狀：改公式只需要重跑 projection，
/// 不需要改任何一筆歷史紀錄。
public struct AnchorStatistics: Sendable, Equatable {
    /// 來自 opened／cited／pinned 的加權衰減和。
    ///
    /// **這個型別的建構子不驗證任何東西**，所以「≥ 0」是生產端的性質而不是
    /// 型別保證——先前這裡逐字寫「永遠 ≥ 0」，那是一句沒有機制支撐的宣稱
    /// （#1 verify R5）。要驗的地方在 seam：`MemoryStrategySupport`
    /// `.requireWellFormedStatistics` 會擋非有限值與負值。
    ///
    /// 為什麼不在建構子擋：`Projection` 是 seam 的**公開輸入型別**，而 seam 的
    /// 教訓已經重複兩輪——檢查放在「呼叫端要記得走的路徑」上就會有人不走。
    /// 放在 seam 是唯一無條件會執行的位置。
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

    /// 形狀問題。`nil` 代表這筆統計沒問題。
    ///
    /// 回傳而不是 throw，讓呼叫端決定要拋什麼——LTMCore 不該知道
    /// `StrategyViolation` 這種上層型別。
    public var malformation: Malformation? {
        if !reinforcement.isFinite { return .nonFinite(field: "reinforcement") }
        if !suppression.isFinite { return .nonFinite(field: "suppression") }
        if reinforcement < 0 { return .negative(field: "reinforcement") }
        if suppression < 0 { return .negative(field: "suppression") }
        if impressions < 0 { return .negative(field: "impressions") }
        for (kind, count) in deliberateCounts {
            if count < 0 { return .negative(field: "deliberateCounts[\(kind.rawValue)]") }
            // `shown` 是曝光，不是 deliberate 訊號。spec 明寫「只有曝光等同於
            // 沒有事件」，而這個欄位的名字就叫 deliberateCounts——放它進來會讓
            // 一次曝光在 reason 裡冒充成增強訊號（#1 verify R6）。
            if kind == .shown { return .impressionAsDeliberateSignal }
        }
        // **淨強度非零就必須指得出訊號**（#21 item 4）。
        //
        // `AnchorStatistics(reinforcement: 5, …, deliberateCounts: [:])` 先前是
        // 合法的，於是 `RankingReason.describing` 會產出
        // `history: .counted(signals: [:], netStrength: 5)`——一句「有訊號促成」
        // 而指不出任何訊號。
        //
        // 那是 provenance 說不出話，與 `misreportedHistory` 擋的「provenance 說謊」
        // 是同一條線的兩側：一個編造來源，一個宣稱有來源卻拿不出來。兩者對讀者
        // 的後果相同——他讀到的不是實際發生的事。
        //
        // 擋在 `malformation` 而不是建構子，理由與這個型別的其餘檢查相同（見上）：
        // `Projection` 是 seam 的公開輸入型別，而檢查放在呼叫端要記得走的路徑上
        // 就會有人不走。seam 是唯一無條件會執行的位置。
        if netStrength != 0 && deliberateCounts.isEmpty {
            return .countedWithoutSignals
        }
        return nil
    }

    public enum Malformation: Sendable, Equatable {
        /// 淨強度非零，卻沒有任何具名的 deliberate 訊號。
        ///
        /// reason 會因此說「有訊號促成」而指不出是哪些（#21 item 4）。
        case countedWithoutSignals

        /// NaN／Infinity。**這是靜默失效而不是崩潰**：`NaN > x` 與 `x > NaN`
        /// 都為 false，於是有界重排的比較恆偽、策略不重排也不報錯，直接退化成
        /// `archival`——正是守衛存在要防的「不合規策略偽裝成合規」。
        /// 與 R3 抓到的 NaN 無限迴圈是同一個根因的另一側（那次落在 `==`）。
        case nonFinite(field: String)
        /// 負值。負 reinforcement 會讓一個增強事件變成壓抑。
        case negative(field: String)
        /// `deliberateCounts` 含 `.shown`。曝光不是 deliberate 訊號。
        case impressionAsDeliberateSignal
    }
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
    /// 因為時間戳晚於評估時點而**被丟棄**的事件數。
    ///
    /// 存在的理由與 `ComparisonReport.SkippedEvents` 完全相同（#1 verify R5）：
    /// 一個裸 `continue` 讓那些事件消失得無影無蹤，而一個整段歷史都在未來的
    /// anchor 與一個從沒被碰過的 anchor 在 projection 裡完全無法區分。
    /// 而註解自己指名的觸發情境（備份被竄改、時鐘回捲）正是最不該看不見的那種。
    public let futureDatedEventsIgnored: Int
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
        orphanedAnchors: Set<Anchor> = [],
        futureDatedEventsIgnored: Int = 0
    ) {
        self.futureDatedEventsIgnored = futureDatedEventsIgnored
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
