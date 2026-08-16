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
    /// team-draft 的起手方。
    ///
    /// 第 1 個位置的點擊率遠高於其後，所以起手方是**已知的混淆變項**。記下來
    /// 才能事後檢查分派是否平衡、必要時分層計分（#1 verify R4：R3 拿掉了它的
    /// 預設值以消除偏誤，卻沒有把實際用了哪一邊留下來，於是偏誤是否真的消除
    /// 變成無法驗證的宣稱）。
    public let startingSide: InterleavingHarness.Side
    /// 兩邊排序完全相同。此時不得把互動記給任何一方。
    public let isNullComparison: Bool

    /// 歸屬的形狀只有兩種，沒有第三種。
    ///
    /// - `isNullComparison == false`：**每一個** anchor 都恰好記在某一邊。
    /// - `isNullComparison == true`：**每一個** anchor 都沒有歸屬。
    ///
    /// 這是封閉列舉，不得依性質相似類推出「部分歸屬」的第三種。spec 先前寫
    /// 「每個 anchor 對應到恰好一個策略」這句全稱，而同一條需求底下的 null
    /// comparison 情境要求不得記給任何一方——兩句在字面上互斥（#1 verify R4）。
    /// 混合形狀會讓 per-presentation rate 的分母沒有定義。
    public enum ShapeViolation: Error, Sendable, Equatable {
        case nullComparisonWithAttributedAnchor(Anchor)
        case realComparisonWithUnattributedAnchor(Anchor)
    }

    public init(
        id: PresentationID,
        queryClass: QueryClass,
        strategyA: RankingPolicyID,
        strategyB: RankingPolicyID,
        generation: GenerationID,
        attribution: [AnchorAttribution],
        startingSide: InterleavingHarness.Side,
        isNullComparison: Bool
    ) throws {
        for entry in attribution {
            switch (isNullComparison, entry.creditedTo) {
            case (true, .some):
                throw ShapeViolation.nullComparisonWithAttributedAnchor(entry.anchor)
            case (false, nil):
                throw ShapeViolation.realComparisonWithUnattributedAnchor(entry.anchor)
            default: break
            }
        }
        self.id = id
        self.queryClass = queryClass
        self.strategyA = strategyA
        self.strategyB = strategyB
        self.generation = generation
        self.attribution = attribution
        self.startingSide = startingSide
        self.isNullComparison = isNullComparison
    }

    /// 解碼走同一條驗證：外來紀錄不得帶著混合形狀進到計分。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try c.decode(PresentationID.self, forKey: .id),
            queryClass: try c.decode(QueryClass.self, forKey: .queryClass),
            strategyA: try c.decode(RankingPolicyID.self, forKey: .strategyA),
            strategyB: try c.decode(RankingPolicyID.self, forKey: .strategyB),
            generation: try c.decode(GenerationID.self, forKey: .generation),
            attribution: try c.decode([AnchorAttribution].self, forKey: .attribution),
            startingSide: try c.decode(InterleavingHarness.Side.self, forKey: .startingSide),
            isNullComparison: try c.decode(Bool.self, forKey: .isNullComparison))
    }

    /// 呈現順序。
    public var presented: [Anchor] { attribution.map(\.anchor) }

    /// 某一邊在**這筆紀錄裡**貢獻了幾個位置。
    ///
    /// **這不是 `ComparisonScorer` 用的分母**（#1 verify R5 更正了這段 doc）。
    /// scorer 的分母是 `.shown` 事件數，也就是呼叫端**真的送出了幾筆曝光**；
    /// 這個函式數的是紀錄裡的位置數。兩者在「只對可見的 top-k 記 shown」這種
    /// 完全正常的做法下並不相等，而舊 doc 指的是不會被用到的那一個。
    ///
    /// 留著它是因為它是紀錄自身的性質（檢查歸屬是否平均分佈時要用），但它與
    /// 計分無關。哪一個才該當分母是評估設計的問題，追蹤於 #16。
    public func presentedCount(for policy: RankingPolicyID) -> Int {
        attribution.count { $0.creditedTo == policy }
    }

    public func credit(for anchor: Anchor) -> RankingPolicyID? {
        attribution.first { $0.anchor == anchor }?.creditedTo
    }
}
