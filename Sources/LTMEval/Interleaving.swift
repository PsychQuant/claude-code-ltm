import Foundation
import LTMCore
import LTMQuery

/// 交錯呈現的結果。
public struct Interleaving: Sendable, Equatable {
    public let presented: [Candidate]
    public let record: PresentationRecord
}

/// 交錯器的前提被違反。全部外顯，因為它們的舊行為是**掛住**而不是回錯。
public enum InterleavingViolation: Error, Sendable, Equatable {
    /// 候選清單裡有重複的 anchor。
    case duplicateCandidate(Anchor)
    /// 某個策略回傳的不是候選集合的排列。
    case strategyReturnedNonPermutation(policy: RankingPolicyID)
}

/// 驗證某個策略的輸出確實是候選集合的排列。
private func requirePermutation(
    _ ranking: [Candidate], of candidates: [Candidate], from policy: RankingPolicyID
) throws {
    guard ranking.count == candidates.count else {
        throw InterleavingViolation.strategyReturnedNonPermutation(policy: policy)
    }
    var unconsumed: [Anchor: Candidate] = [:]
    for candidate in candidates { unconsumed[candidate.anchor] = candidate }
    for candidate in ranking {
        guard let expected = unconsumed.removeValue(forKey: candidate.anchor), expected == candidate
        else {
            throw InterleavingViolation.strategyReturnedNonPermutation(policy: policy)
        }
    }
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

        // 候選內的 anchor 必須唯一。不唯一時（例如 lexical 與 vector 兩路送了同一段
        // 而沒去重），下面的 `taken` 去重會讓可取出的相異 anchor 少於 count——
        // 舊版迴圈會因此在兩個 guard 之間無限翻面空轉、CPU 燒滿而不是回錯。
        // （#1 verify 2026-08-11，logic lens 實測 test bundle 掛住需 kill -9。）
        var seen: Set<Anchor> = []
        for candidate in candidates where !seen.insert(candidate.anchor).inserted {
            throw InterleavingViolation.duplicateCandidate(candidate.anchor)
        }

        let rankingA = try a.rerank(candidates, with: projection).map(\.candidate)
        let rankingB = try b.rerank(candidates, with: projection).map(\.candidate)

        // 策略是可插拔的，而 `MemoryStrategy` 並不強制走 RankingGuard——
        // `ArchivalStrategy` 自己就沒呼叫。所以「回傳的是排列」在 seam 上只是慣例，
        // 必須在消費端自己驗一次。spec 的「presented list contains each candidate
        // exactly once」原本沒有任何執行點，違反時的表現是無限迴圈而不是 fail loudly。
        try requirePermutation(rankingA, of: candidates, from: a.id)
        try requirePermutation(rankingB, of: candidates, from: b.id)

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

        // 連續多少次翻面都沒取到東西。兩邊都取盡時它會到 2，迴圈結束——
        // 沒有這個計數器就沒有跳出路徑（見上方 duplicateCandidate 的說明）。
        var consecutiveEmptyTurns = 0

        while presented.count < candidates.count, consecutiveEmptyTurns < 2 {
            let (list, policy) = turn == .a ? (rankingA, a.id) : (rankingB, b.id)
            var cursor = turn == .a ? indexA : indexB
            while cursor < list.count, taken.contains(list[cursor].anchor) { cursor += 1 }
            if turn == .a { indexA = cursor } else { indexB = cursor }

            guard cursor < list.count else {
                // 這一邊已無未選項目，換另一邊繼續。
                consecutiveEmptyTurns += 1
                turn = turn == .a ? .b : .a
                continue
            }
            consecutiveEmptyTurns = 0

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
