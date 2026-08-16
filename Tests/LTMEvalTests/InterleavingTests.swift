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

// MARK: - 起手方：平衡機制與紀錄（#1 verify R4）

@Test func theStartingSideIsRecordedSoThePositionEffectStaysCheckable() throws {
    let input = evalCandidates(["a", "b", "c"])
    let projection = Projection(
        statistics: [evalAnchor("c"): AnchorStatistics(
            reinforcement: 5, suppression: 0, impressions: 0,
            lastDeliberateInteraction: evalInstant, deliberateCounts: [.cited: 5])],
        instant: evalInstant)

    for side in [InterleavingHarness.Side.a, .b] {
        let result = try InterleavingHarness(generation: evalGeneration).present(
            query: "測試", candidates: input, projection: projection,
            a: ArchivalStrategy(), b: HumanLikeStrategy(), startingSide: side)
        #expect(result.record.startingSide == side)
    }
}

@Test func balancedStartingSideIsReproducibleAcrossProcesses() {
    // **golden 值，刻意寫死。** 這條擋的是「有人把 FNV-1a 換成 `hashValue`」：
    // Swift 的 `Hasher` 每個 process 隨機種子化，換過去之後這些斷言會在**某些**
    // 執行失敗——而分派不可重現這件事本身不會有任何其他症狀。
    #expect(InterleavingHarness.Side.balanced(seed: "presentation-0") == .a)
    #expect(InterleavingHarness.Side.balanced(seed: "presentation-1") == .b)
    #expect(InterleavingHarness.Side.balanced(seed: "presentation-10") == .b)
    #expect(InterleavingHarness.Side.balanced(seed: "presentation-11") == .a)
}

@Test func balancedStartingSideActuallySplitsEvenly() {
    // 平衡是這個機制存在的理由，所以要量而不是相信。
    let aCount = (0..<200).count { InterleavingHarness.Side.balanced(seed: "p\($0)") == .a }
    #expect(aCount == 100)
}

// MARK: - 歸屬的形狀只有兩種（#1 verify R4）

@Test func aNullComparisonCannotCarryAnAttributedAnchor() {
    #expect(throws: PresentationRecord.ShapeViolation.nullComparisonWithAttributedAnchor(
        evalAnchor("a"))
    ) {
        _ = try PresentationRecord(
            id: .random(), queryClass: .cjk2char,
            strategyA: RankingPolicyID("archival"), strategyB: RankingPolicyID("human-like"),
            generation: evalGeneration,
            attribution: [AnchorAttribution(
                anchor: evalAnchor("a"), creditedTo: RankingPolicyID("archival"))],
            startingSide: .a, isNullComparison: true)
    }
}

@Test func aRealComparisonCannotCarryAnUnattributedAnchor() {
    // 混合形狀會讓 per-presentation rate 的分母沒有定義——spec 的全稱句與
    // null comparison 情境先前在字面上互斥，這條把封閉列舉釘成可執行的事實。
    #expect(throws: PresentationRecord.ShapeViolation.realComparisonWithUnattributedAnchor(
        evalAnchor("b"))
    ) {
        _ = try PresentationRecord(
            id: .random(), queryClass: .cjk2char,
            strategyA: RankingPolicyID("archival"), strategyB: RankingPolicyID("human-like"),
            generation: evalGeneration,
            attribution: [
                AnchorAttribution(anchor: evalAnchor("a"), creditedTo: RankingPolicyID("archival")),
                AnchorAttribution(anchor: evalAnchor("b"), creditedTo: nil),
            ],
            startingSide: .a, isNullComparison: false)
    }
}
