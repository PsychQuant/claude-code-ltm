import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// MARK: - 5.2 archival：什麼都不動

@Test func archivalReturnsInputOrderWithZeroDisplacement() throws {
    let input = candidates(["a", "b", "c", "d", "e"])
    let output = try ArchivalStrategy().rerank(input, with: .empty(at: instant))

    #expect(output.map(\.candidate.anchor) == input.map(\.anchor))
    #expect(output.allSatisfy { $0.displacement == 0 })
    #expect(output.allSatisfy { $0.reason == RankingReason(history: .none, movement: .unmoved) })
}

@Test func archivalIgnoresUsageHistoryEntirely() throws {
    let input = candidates(["a", "b", "c", "d", "e"])
    let strategy = ArchivalStrategy()

    let withoutHistory = try strategy.rerank(input, with: .empty(at: instant))
    let dense = projection([
        (testAnchor("e"), [.cited: 50, .pinned: 10]),
        (testAnchor("d"), [.opened: 30]),
    ])
    let withHistory = try strategy.rerank(input, with: dense)

    #expect(withoutHistory.map(\.candidate.anchor) == withHistory.map(\.candidate.anchor))
    #expect(withHistory.allSatisfy { $0.displacement == 0 })
}

// MARK: - 5.3 human-like：帶內上移、違規外顯、orphan 惰性

@Test func humanLikePromotesACitedBandPeer() throws {
    let input = candidates(["a", "b", "c"])
    let cited = testAnchor("c")
    let output = try HumanLikeStrategy(displacementBound: 3)
        .rerank(input, with: projection([(cited, [.cited: 3])]))

    let positions = output.map(\.candidate.anchor)
    let citedIndex = positions.firstIndex(of: cited)!
    let peerIndex = positions.firstIndex(of: testAnchor("b"))!
    #expect(citedIndex < peerIndex)

    let result = output[citedIndex]
    #expect(result.displacement > 0)
    guard case .counted(let signals, let net) = result.reason.history else {
        Issue.record("預期 counted history，實得 \(result.reason.history)")
        return
    }
    #expect(result.reason.movement == .advanced(positions: result.displacement))
    #expect(signals[.cited] == 3)  // reason 必須指名是引用促成的
    #expect(net > 0)
}

@Test func humanLikeNeverCrossesARelevanceBand() throws {
    // 第 0 帶兩筆、第 1 帶一筆；第 1 帶那筆被大量引用。
    var input = candidates(["a", "b"], band: 0)
    input += candidates(["z"], band: 1)

    let output = try HumanLikeStrategy(displacementBound: 10)
        .rerank(input, with: projection([(testAnchor("z"), [.cited: 100, .pinned: 20])]))

    // 再多的歷史也不能把低相關帶的東西推過高相關帶。
    #expect(output.map(\.candidate.band.rank) == [0, 0, 1])
}

@Test func crossingABandIsReportedNotClamped() {
    let input = candidates(["a"], band: 0) + candidates(["z"], band: 1)
    let rogue = RogueStrategy(mode: .crossBand)

    // 參數名改過（R5）：`expected` 是這個位置本來該有的帶，`found` 是現在的。
    #expect(throws: StrategyViolation.crossedRelevanceBand(
        expected: RelevanceBand(rank: 0), found: RelevanceBand(rank: 1))
    ) {
        _ = try rogue.rerank(input, with: .empty(at: instant))
    }
}

@Test func exceedingTheDisplacementBoundIsReportedNotClamped() {
    let input = candidates(["a", "b", "c", "d", "e"])
    let rogue = RogueStrategy(mode: .jumpFourPlaces(bound: 1))

    #expect(throws: StrategyViolation.displacementBoundExceeded(bound: 1, attempted: 4)) {
        _ = try rogue.rerank(input, with: .empty(at: instant))
    }
}

@Test func anEmptyProjectionEarnsNoPromotion() throws {
    // **改名，因為舊名字說謊**（#1 verify R5）：它叫
    // `orphanedHistoryEarnsNoPromotion`，卻餵 `.empty(at:)`——裡面一個 orphan
    // 都沒有。空 projection 之下任何策略都不會動，把 orphan 機制整個拿掉它
    // 照樣綠。這是 R4 清理「名字比證據強」時漏掉的同類殘留。
    //
    // 它仍然有價值（策略對空 projection 不得崩潰或給預設值），所以留著、
    // 但改成它實際驗的名字。真正的 orphan 覆蓋在 `OrphanReasonTests`。
    let input = candidates(["a", "b", "c"])
    let output = try HumanLikeStrategy(displacementBound: 3)
        .rerank(input, with: .empty(at: instant))

    #expect(output.map(\.candidate.anchor) == input.map(\.anchor))
    #expect(output.allSatisfy { $0.displacement == 0 })
}

// MARK: - 5.4 上限是設定、身分由訊號集合決定

@Test func displacementBoundIsConstructionTimeConfiguration() throws {
    let input = candidates(["a", "b", "c", "d", "e", "f"])
    let heavilyCited = testAnchor("f")  // 原本在第 5 位
    let p = projection([(heavilyCited, [.cited: 40, .pinned: 10])])

    let bound1 = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: p)
    let bound3 = try HumanLikeStrategy(displacementBound: 3).rerank(input, with: p)

    #expect(bound1.map(\.candidate.anchor).firstIndex(of: heavilyCited) == 4)
    #expect(bound3.map(\.candidate.anchor).firstIndex(of: heavilyCited) == 2)
}

@Test func defaultDisplacementBoundIsOne() throws {
    let input = candidates(["a", "b", "c", "d", "e", "f"])
    let heavilyCited = testAnchor("f")
    let output = try HumanLikeStrategy()
        .rerank(input, with: projection([(heavilyCited, [.cited: 40])]))

    #expect(HumanLikeStrategy().displacementBound == 1)
    #expect(output.map(\.candidate.anchor).firstIndex(of: heavilyCited) == 4)
}

@Test func differentBoundsAreTheSameStrategy() {
    // 幅度不是策略軸。第三檔必須用「消費哪些訊號」**或「在什麼條件下作用」**
    // 定義——`conservative` 走的是後者（同訊號、只在等分時作用）。這句先前只寫
    // 訊號集合，於是在字面上禁止了後來加進來的 conservative（#1 verify R3）。
    #expect(HumanLikeStrategy(displacementBound: 1).id == HumanLikeStrategy(displacementBound: 9).id)
    #expect(HumanLikeStrategy().id != ArchivalStrategy().id)
}

@Test func strategiesDeclareTheSignalsTheyConsume() {
    #expect(ArchivalStrategy().consumedSignals.isEmpty)
    #expect(HumanLikeStrategy().consumedSignals == [.opened, .cited, .pinned, .dismissed])
}

// MARK: - 測試用的違規策略

/// 刻意違規的策略，用來確認守衛真的會擋。合規的策略永遠不該長這樣。
private struct RogueStrategy: MemoryStrategy {
    enum Mode {
        case crossBand
        case jumpFourPlaces(bound: Int)
    }
    let mode: Mode
    let id = RankingPolicyID("rogue")
    /// 觸發測試授權註冊（見 `TestStrategyAuthority`）。
    private let authorized = StrategyRegistry.readyForTesting
    let consumedSignals: Set<EventKind> = []

    let displacementBound = 99
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws -> [RankedResult] {
        let candidates = input.candidates
        switch mode {
        case .crossBand:
            let reordered = Array(candidates.reversed())  // 把第 1 帶推到第 0 帶前面
            return try RankingGuard.check(original: candidates, reordered: reordered, bound: 99)
                .map { RankedResult(candidate: $0.candidate, displacement: $0.displacement, reason: RankingReason(history: .none, movement: .unmoved)) }
        case .jumpFourPlaces(let bound):
            var reordered = candidates
            let moved = reordered.remove(at: 4)
            reordered.insert(moved, at: 0)
            return try RankingGuard.check(original: candidates, reordered: reordered, bound: bound)
                .map { RankedResult(candidate: $0.candidate, displacement: $0.displacement, reason: RankingReason(history: .none, movement: .unmoved)) }
        }
    }
}
