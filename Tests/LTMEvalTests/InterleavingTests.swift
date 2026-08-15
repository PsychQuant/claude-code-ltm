import Foundation
import Testing

@testable import LTMCore
@testable import LTMEval
@testable import LTMQuery

let evalInstant = Date(timeIntervalSince1970: 4_000_000)
let evalGeneration = GenerationID("build-eval-1")

/// 測試裡用的查詢原文。序列化測試會在輸出裡搜尋它，必須 0 次命中。
let 查詢原文 = "釘選版本然後做比較"

func evalAnchor(_ id: String) -> Anchor {
    Anchor(
        source: "fixture-a",
        turn: Turn(id: id, role: "user", timestamp: Date(), text: "合成候選 \(id)，長度足夠切 span。"),
        span: 0..<8)
}

func evalCandidates(_ ids: [String]) -> [Candidate] {
    ids.enumerated().map {
        Candidate(anchor: evalAnchor($1), baseScore: 1 - Double($0) * 0.01, band: RelevanceBand(rank: 0))
    }
}

func evalProjection(_ entries: [(Anchor, [EventKind: Int])]) -> Projection {
    var stats: [Anchor: AnchorStatistics] = [:]
    for (anchor, counts) in entries {
        let cited: Int = counts[.cited] ?? 0
        let opened: Int = counts[.opened] ?? 0
        stats[anchor] = AnchorStatistics(
            reinforcement: Double(cited) * 2 + Double(opened),
            suppression: 0, impressions: 0,
            lastDeliberateInteraction: evalInstant, deliberateCounts: counts)
    }
    return Projection(statistics: stats, instant: evalInstant)
}

@Test func interleavedListContainsEachCandidateExactlyOnce() throws {
    let input = evalCandidates(["a", "b", "c", "d"])
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: 查詢原文, candidates: input,
        projection: evalProjection([(evalAnchor("d"), [.cited: 5])]),
        a: ArchivalStrategy(), b: HumanLikeStrategy(displacementBound: 3), startingSide: .a)

    #expect(result.presented.count == input.count)
    #expect(Set(result.presented.map(\.anchor)) == Set(input.map(\.anchor)))
}

@Test func everyPresentedPositionIsCreditedToExactlyOneStrategy() throws {
    let input = evalCandidates(["a", "b", "c", "d"])
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: 查詢原文, candidates: input,
        projection: evalProjection([(evalAnchor("d"), [.cited: 5])]),
        a: ArchivalStrategy(), b: HumanLikeStrategy(displacementBound: 3), startingSide: .a)

    #expect(!result.record.isNullComparison)
    for attribution in result.record.attribution {
        #expect(attribution.creditedTo != nil)
    }
    let credits = Set(result.record.attribution.compactMap(\.creditedTo))
    #expect(credits == [RankingPolicyID("archival"), RankingPolicyID("human-like")])

    // 逐位歸屬互斥且窮盡：兩邊的貢獻數加起來等於呈現長度。
    let total = result.record.presentedCount(for: RankingPolicyID("archival"))
        + result.record.presentedCount(for: RankingPolicyID("human-like"))
    #expect(total == result.presented.count)
}

@Test func identicalRankingsYieldANullComparison() throws {
    let input = evalCandidates(["a", "b", "c"])
    // 沒有任何使用歷史 → human-like 與 archival 產生相同排序。
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: 查詢原文, candidates: input, projection: .empty(at: evalInstant),
        a: ArchivalStrategy(), b: HumanLikeStrategy(), startingSide: .a)

    #expect(result.record.isNullComparison)
    #expect(result.record.attribution.allSatisfy { $0.creditedTo == nil })
    #expect(result.record.presentedCount(for: RankingPolicyID("archival")) == 0)
}

@Test func serializedPresentationRecordsContainNoQueryText() throws {
    let input = evalCandidates(["a", "b", "c", "d"])
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: 查詢原文, candidates: input,
        projection: evalProjection([(evalAnchor("d"), [.cited: 5])]),
        a: ArchivalStrategy(), b: HumanLikeStrategy(displacementBound: 3), startingSide: .a)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(result.record)
    let text = String(decoding: bytes, as: UTF8.self)

    #expect(!text.contains(查詢原文))
    #expect(!text.contains("釘選"))
    #expect(!text.contains("比較"))

    // 四個該留的欄位確實有留——否則上面的斷言可能只是因為輸出是空的。
    #expect(text.contains("cjk-4plus"))  // class label
    #expect(text.contains("archival") && text.contains("human-like"))  // 策略對
    #expect(text.contains("build-eval-1"))  // generation
    #expect(text.contains("creditedTo"))  // 逐位歸屬
}

@Test func startingSideIsExplicitSoResultsAreReproducible() throws {
    let input = evalCandidates(["a", "b", "c", "d"])
    let projection = evalProjection([(evalAnchor("d"), [.cited: 5])])
    let harness = InterleavingHarness(generation: evalGeneration)

    let fromA = try harness.present(
        query: 查詢原文, candidates: input, projection: projection,
        a: ArchivalStrategy(), b: HumanLikeStrategy(displacementBound: 3), startingSide: .a)
    let fromB = try harness.present(
        query: 查詢原文, candidates: input, projection: projection,
        a: ArchivalStrategy(), b: HumanLikeStrategy(displacementBound: 3), startingSide: .b)

    #expect(fromA.record.attribution.first?.creditedTo == RankingPolicyID("archival"))
    #expect(fromB.record.attribution.first?.creditedTo == RankingPolicyID("human-like"))
}
