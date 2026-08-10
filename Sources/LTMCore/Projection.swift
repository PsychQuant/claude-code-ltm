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
/// 變成編譯期事實：LTMQuery 根本看不到 `EventStore` 這個型別。
public struct Projection: Sendable, Equatable {
    public let statistics: [Anchor: AnchorStatistics]
    /// 產生這份 projection 的評估時點。留著是為了讓 reason 能誠實說明依據。
    public let instant: Date

    public init(statistics: [Anchor: AnchorStatistics], instant: Date) {
        self.statistics = statistics
        self.instant = instant
    }

    public subscript(anchor: Anchor) -> AnchorStatistics? { statistics[anchor] }

    /// 未知或 orphan 的 anchor 一律 0，而不是 nil 再讓每個呼叫端各自決定。
    public func reinforcement(for anchor: Anchor) -> Double {
        statistics[anchor]?.reinforcement ?? 0
    }

    public func netStrength(for anchor: Anchor) -> Double {
        statistics[anchor]?.netStrength ?? 0
    }

    public static func empty(at instant: Date) -> Projection {
        Projection(statistics: [:], instant: instant)
    }
}
