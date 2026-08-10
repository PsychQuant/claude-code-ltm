import Foundation
import LTMCore

/// 交錯呈現裡的某一個位置由哪一邊貢獻。
public struct AnchorAttribution: Sendable, Equatable, Codable {
    public let anchor: Anchor
    /// 這個位置該記在誰頭上。`nil` 只出現在 null comparison（兩邊排序相同）。
    public let creditedTo: RankingPolicyID?

    public init(anchor: Anchor, creditedTo: RankingPolicyID?) {
        self.anchor = anchor
        self.creditedTo = creditedTo
    }
}

/// 一次交錯呈現的紀錄。
///
/// 欄位清單是刻意的最小集：class label（統計）、策略對、generation、逐位歸屬。
/// **沒有 query 原文**——它在 harness 裡被算成 label 之後就丟掉了。
public struct PresentationRecord: Sendable, Equatable, Codable {
    /// 這次呈現的識別碼。事件帶著它回來，歸屬才有辦法是精確的而不是猜的。
    public let id: PresentationID
    public let queryClass: QueryClass
    public let strategyA: RankingPolicyID
    public let strategyB: RankingPolicyID
    public let generation: GenerationID
    public let attribution: [AnchorAttribution]
    /// 兩邊排序完全相同。此時不得把互動記給任何一方。
    public let isNullComparison: Bool

    public init(
        id: PresentationID,
        queryClass: QueryClass,
        strategyA: RankingPolicyID,
        strategyB: RankingPolicyID,
        generation: GenerationID,
        attribution: [AnchorAttribution],
        isNullComparison: Bool
    ) {
        self.id = id
        self.queryClass = queryClass
        self.strategyA = strategyA
        self.strategyB = strategyB
        self.generation = generation
        self.attribution = attribution
        self.isNullComparison = isNullComparison
    }

    /// 呈現順序。
    public var presented: [Anchor] { attribution.map(\.anchor) }

    /// 某一邊貢獻了幾個位置。per-presentation rate 的分母用它，而不是用互動總數。
    public func presentedCount(for policy: RankingPolicyID) -> Int {
        attribution.count { $0.creditedTo == policy }
    }

    public func credit(for anchor: Anchor) -> RankingPolicyID? {
        attribution.first { $0.anchor == anchor }?.creditedTo
    }
}
