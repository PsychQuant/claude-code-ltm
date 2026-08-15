import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// #17 裁決（2026-08-15）：`conservative` 以 tie-breaker-only 復活。
// 初版把它移除的論證只對了一半——±5% 封頂確實無法表達，但「僅作 tie-breaker」
// 完全可以。部分為真的論證被用來支撐全稱結論。

/// 造一組候選，讓指定的幾個位置 base score 完全相等（模擬 RRF 平手）。
private func tiedCandidates(_ ids: [String], tiedScore: Double = 0.5) -> [Candidate] {
    ids.map { Candidate(anchor: testAnchor($0), baseScore: tiedScore, band: RelevanceBand(rank: 0)) }
}

private func strengths(_ entries: [(String, Double)]) -> Projection {
    var stats: [Anchor: AnchorStatistics] = [:]
    for (id, strength) in entries {
        stats[testAnchor(id)] = AnchorStatistics(
            reinforcement: strength, suppression: 0, impressions: 0,
            lastDeliberateInteraction: instant, deliberateCounts: [.cited: Int(strength)])
    }
    return Projection(statistics: stats, instant: instant)
}

@Test func conservativeBreaksTiesByStrength() throws {
    let input = tiedCandidates(["a", "b", "c"])  // base score 全部相同
    let output = try ConservativeStrategy()
        .rerank(input, with: strengths([("c", 5), ("b", 2)]))

    #expect(output.map(\.candidate.anchor) == [testAnchor("c"), testAnchor("b"), testAnchor("a")])
}

@Test func conservativeNeverReordersCandidatesWithDifferentBaseScores() throws {
    // 這是它與 human-like 的分界：檢索有意見的地方，記憶不插手。
    let input = candidates(["a", "b", "c"])  // baseScore 遞減、互不相等
    let output = try ConservativeStrategy()
        .rerank(input, with: strengths([("c", 100), ("b", 50)]))

    #expect(output.map(\.candidate.anchor) == input.map(\.anchor))
    #expect(output.allSatisfy { $0.displacement == 0 })
}

@Test func conservativeAndHumanLikeDivergeExactlyOnNonTiedInput() throws {
    // 同一份輸入，兩檔策略給出不同結果——這證明它們是不同的策略，
    // 而不是同一個策略配不同參數。
    let input = candidates(["a", "b", "c"])
    let projection = strengths([("c", 5)])

    let conservative = try ConservativeStrategy().rerank(input, with: projection)
    let humanLike = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: projection)

    #expect(conservative.map(\.candidate.anchor) != humanLike.map(\.candidate.anchor))
    #expect(conservative.allSatisfy { $0.displacement == 0 })
    #expect(humanLike.contains { $0.displacement > 0 })
}

@Test func conservativeIsNotHumanLikeWithBoundZero() throws {
    // 反面確認：把 human-like 的上限調到 0 得不到 tie-breaking，只得到「什麼都不做」。
    // 所以這兩檔的差別是機制，不是幅度——spec 的「策略由訊號集合定義、不由幅度
    // 定義」那條規則因此沒有被違反。
    let tied = tiedCandidates(["a", "b", "c"])
    let projection = strengths([("c", 5), ("b", 2)])

    let boundZero = try HumanLikeStrategy(displacementBound: 0).rerank(tied, with: projection)
    let conservative = try ConservativeStrategy().rerank(tied, with: projection)

    #expect(boundZero.map(\.candidate.anchor) == tied.map(\.anchor))  // 完全不動
    #expect(conservative.map(\.candidate.anchor) != tied.map(\.anchor))  // 有動
}

@Test func conservativeStaysWithinItsRelevanceBand() throws {
    // 平手判準含 band：跨帶就算 base score 碰巧相同也不合併成一個平手區段。
    var input = tiedCandidates(["a", "b"], tiedScore: 0.5)
    input += [Candidate(anchor: testAnchor("z"), baseScore: 0.5, band: RelevanceBand(rank: 1))]

    let output = try ConservativeStrategy()
        .rerank(input, with: strengths([("z", 100)]))

    #expect(output.map(\.candidate.band.rank) == [0, 0, 1])
}

@Test func conservativeReportsOrphanedHistoryLikeHumanLike() throws {
    let input = tiedCandidates(["a", "b"])
    let p = Projection(statistics: [:], instant: instant, orphanedAnchors: [testAnchor("b")])
    let output = try ConservativeStrategy().rerank(input, with: p)

    #expect(output.first { $0.candidate.anchor == testAnchor("b") }?.reason == .orphanedHistoryIgnored)
}

@Test func threeStrategiesNowCoexistAndAreDistinguishable() throws {
    // issue #1 的 Expected 要三檔並存。這條把「並存」釘成一個可執行的事實。
    let all: [any MemoryStrategy] = [ArchivalStrategy(), ConservativeStrategy(), HumanLikeStrategy()]
    #expect(Set(all.map(\.id)) .count == 3)
    #expect(ArchivalStrategy().consumedSignals.isEmpty)
    #expect(!ConservativeStrategy().consumedSignals.isEmpty)
    #expect(ConservativeStrategy().consumedSignals == HumanLikeStrategy().consumedSignals)
}
