import Foundation
import LTMCore
import LTMQuery

/// 交錯呈現的結果。
public struct Interleaving: Sendable, Equatable {
    public let presented: [Candidate]
    public let record: PresentationRecord
}

/// 兩策略比較的交錯器（team-draft）。
///
/// 為什麼是交錯而不是重放歷史查詢：不留 query 原文，就不可能把舊查詢重跑一次。
/// 交錯只需要已經同意記錄的事件（shown/opened/cited），代價是它只能比較「現在
/// 這兩個策略」，不能回溯比較。這個代價是隱私最小化的直接後果，不是疏忽。
public struct InterleavingHarness: Sendable {
    public enum Side: Sendable, Equatable { case a, b }

    public let generation: GenerationID

    public init(generation: GenerationID) {
        self.generation = generation
    }

    /// 產生交錯清單與其紀錄。
    ///
    /// `query` 只用來算 class label，**不被保存**：出了這個函式，字串就沒有
    /// 任何持有者。`startingSide` 由呼叫端指定而非內部隨機，理由是結果必須
    /// 可重現——隨機起手要靠外部種子注入，不能藏在這裡。
    public func present(
        query: String,
        candidates: [Candidate],
        projection: Projection,
        a: some MemoryStrategy,
        b: some MemoryStrategy,
        startingSide: Side = .a
    ) throws -> Interleaving {
        let queryClass = QueryClassifier.classify(query)
        let presentationID = PresentationID.random()

        let rankingA = try a.rerank(candidates, with: projection).map(\.candidate)
        let rankingB = try b.rerank(candidates, with: projection).map(\.candidate)

        // 兩邊排序一樣 → 這次呈現無法分辨任何差異。硬記給某一邊會憑空製造
        // 偏好，所以標成 null comparison 讓計分整批略過。
        if rankingA.map(\.anchor) == rankingB.map(\.anchor) {
            return Interleaving(
                presented: rankingA,
                record: PresentationRecord(
                    id: presentationID,
                    queryClass: queryClass,
                    strategyA: a.id, strategyB: b.id,
                    generation: generation,
                    attribution: rankingA.map { AnchorAttribution(anchor: $0.anchor, creditedTo: nil) },
                    isNullComparison: true))
        }

        var presented: [Candidate] = []
        var attribution: [AnchorAttribution] = []
        var taken: Set<Anchor> = []
        var indexA = 0
        var indexB = 0
        var turn = startingSide

        while presented.count < candidates.count {
            let (list, policy) = turn == .a ? (rankingA, a.id) : (rankingB, b.id)
            var cursor = turn == .a ? indexA : indexB
            while cursor < list.count, taken.contains(list[cursor].anchor) { cursor += 1 }
            if turn == .a { indexA = cursor } else { indexB = cursor }

            guard cursor < list.count else {
                // 這一邊已無未選項目，換另一邊繼續。
                turn = turn == .a ? .b : .a
                continue
            }

            let pick = list[cursor]
            taken.insert(pick.anchor)
            presented.append(pick)
            attribution.append(AnchorAttribution(anchor: pick.anchor, creditedTo: policy))
            turn = turn == .a ? .b : .a
        }

        return Interleaving(
            presented: presented,
            record: PresentationRecord(
                id: presentationID,
                queryClass: queryClass,
                strategyA: a.id, strategyB: b.id,
                generation: generation,
                attribution: attribution,
                isNullComparison: false))
    }
}
