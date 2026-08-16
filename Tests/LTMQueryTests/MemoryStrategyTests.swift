import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// 依賴約束的驗證標的是 Package.swift：LTMQuery 的 dependencies 只有 LTMCore，
// 所以 `FileEventStore` 在本模組不是可見型別。
//
// **這條約束比先前寫的弱**（#1 verify 2026-08-11，devils-advocate 實測）：擋住的
// 只是那個便利型別，JSON Lines 格式與 `Event: Codable` 都在 LTMCore，用
// Foundation 直接讀檔即可繞過。spec 的 "Retrieval SHALL NOT read the event store
// directly" 目前**沒有執行點**——把它寫成「編譯期事實」是過度宣稱，已更正。

let instant = Date(timeIntervalSince1970: 3_000_000)

func testAnchor(_ id: String) -> Anchor {
    Anchor(
        source: "fixture-a",
        turn: Turn(id: id, role: "user", timestamp: Date(), text: "合成候選文字 \(id)，長度足夠切出 span。"),
        span: 0..<8)
}

func candidates(_ ids: [String], band: Int = 0) -> [Candidate] {
    ids.enumerated().map {
        Candidate(anchor: testAnchor($1), baseScore: 1.0 - Double($0) * 0.01, band: RelevanceBand(rank: band))
    }
}

func projection(_ entries: [(Anchor, [EventKind: Int])]) -> Projection {
    var stats: [Anchor: AnchorStatistics] = [:]
    for (anchor, counts) in entries {
        let opened: Int = counts[.opened] ?? 0
        let cited: Int = counts[.cited] ?? 0
        let pinned: Int = counts[.pinned] ?? 0
        let dismissed: Int = counts[.dismissed] ?? 0
        let reinforcement = Double(opened) + Double(cited) * 2 + Double(pinned) * 3
        let suppression = Double(dismissed) * 2
        stats[anchor] = AnchorStatistics(
            reinforcement: reinforcement, suppression: suppression, impressions: 0,
            lastDeliberateInteraction: instant, deliberateCounts: counts)
    }
    return Projection(statistics: stats, instant: instant)
}

/// 只做恆等的最小策略，用來驗 seam 本身的契約（不是 archival 的替身——那個
/// 有自己的測試）。
private struct IdentityProbe: MemoryStrategy {
    let id = RankingPolicyID("identity-probe")
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 99
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws -> [RankedResult] {
        let candidates = input.candidates
        return candidates.map { RankedResult(candidate: $0, displacement: 0, reason: RankingReason(history: .none, movement: .unmoved)) }
    }
}

@Test func rerankReturnsAPermutationOfItsInput() throws {
    let input = candidates(["a", "b", "c", "d"])
    let output = try IdentityProbe().rerank(input, with: .empty(at: instant))

    #expect(output.count == input.count)
    #expect(Set(output.map(\.candidate.anchor)) == Set(input.map(\.anchor)))
}

@Test func everyResultCarriesDisplacementAndReason() throws {
    let input = candidates(["a", "b", "c"])
    let output = try IdentityProbe().rerank(input, with: .empty(at: instant))

    // 零位移也必須有 reason——「沒調整」是一個要被說出口的事實，不是空白。
    for result in output {
        #expect(result.displacement == 0)
        #expect(result.reason == RankingReason(history: .none, movement: .unmoved))
    }
}

@Test func strategyIdentityIsAPolicyIdentifier() {
    #expect(IdentityProbe().id == RankingPolicyID("identity-probe"))
}

// MARK: - seam 是強制的，不是自願的（#1 verify R4）

/// 什麼守衛都不呼叫、而且**謊報** displacement 的策略。
///
/// R4 之前這種策略完全合法：`requireFiniteBaseScores` 與 `RankingGuard` 都由
/// 每個策略自己想起來呼叫，不呼叫就不受任何約束——而「seam」的定義就是不可
/// 繞過。現在 `rerank` 在 extension 上、不是 customization point，所以下面
/// 三條測的都不是這個型別的自律，是 seam 的強制。
private struct LyingStrategy: MemoryStrategy {
    let id = RankingPolicyID("lying")
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 99
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        let candidates = input.candidates
        // 順序原封不動，卻宣稱每一筆都上移了三名。
        return candidates.map { RankedResult(candidate: $0, displacement: 3, reason: RankingReason(history: .none, movement: .unmoved)) }
    }
}

/// 把候選整個反轉、跨帶，同樣什麼都不驗。
private struct BandCrossingStrategy: MemoryStrategy {
    let id = RankingPolicyID("band-crossing")
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 99
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        let candidates = input.candidates
        return candidates.reversed().map {
            RankedResult(candidate: $0, displacement: 0, reason: RankingReason(history: .none, movement: .unmoved))
        }
    }
}

@Test func aStrategyCannotLieAboutItsOwnDisplacement() {
    // provenance 若可以說謊，比較實驗讀到的就不是實際發生的事。
    let input = candidates(["a", "b"])
    #expect(
        throws: StrategyViolation.misreportedDisplacement(
            testAnchor("a"), reported: 3, actual: 0)
    ) {
        _ = try LyingStrategy().rerank(input, with: .empty(at: instant))
    }
}

@Test func aStrategyThatChecksNothingStillCannotCrossABand() {
    var input = candidates(["a"])
    input += [Candidate(anchor: testAnchor("z"), baseScore: 0.1, band: RelevanceBand(rank: 1))]

    #expect(throws: (any Error).self) {
        _ = try BandCrossingStrategy().rerank(input, with: .empty(at: instant))
    }
}

@Test func nonFiniteInputIsRejectedForAStrategyThatNeverChecksIt() {
    // `LyingStrategy` 沒有一行在看 base score。前置條件由 seam 施加。
    let bad = [Candidate(anchor: testAnchor("nan"), baseScore: .nan, band: RelevanceBand(rank: 0))]
    #expect(throws: StrategyViolation.nonFiniteBaseScore(testAnchor("nan"))) {
        _ = try LyingStrategy().rerank(bad, with: .empty(at: instant))
    }
}

// MARK: - 位移上限與帶圍籬由 seam 執行（#1 verify R5）

/// 誠實回報自己位移、但跳很遠的策略。宣告的上限是 1。
///
/// R5 的反例逐字版：把同帶五筆從 `[A,B,C,D,E]` 排成 `[E,A,B,C,D]`，回報
/// `[4,-1,-1,-1,-1]`。上一版的 seam 只驗排列與 displacement 誠實性，兩者它都
/// 通過——因為上限當時還留給各策略自願呼叫守衛。
private struct FarJumpingStrategy: MemoryStrategy {
    let id = RankingPolicyID("far-jumping")
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 1

    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        let candidates = input.candidates
        var reordered = candidates
        let last = reordered.removeLast()
        reordered.insert(last, at: 0)
        var index: [Anchor: Int] = [:]
        for (i, c) in candidates.enumerated() { index[c.anchor] = i }
        return reordered.enumerated().map { newIndex, candidate in
            RankedResult(
                candidate: candidate,
                displacement: index[candidate.anchor]! - newIndex,  // 據實回報
                reason: RankingReason(history: .none, movement: .unmoved))
        }
    }
}

@Test func theSeamEnforcesTheDisplacementBoundEvenWhenTheStrategyReportsItHonestly() {
    let input = candidates(["a", "b", "c", "d", "e"])
    #expect(throws: StrategyViolation.displacementBoundExceeded(bound: 1, attempted: 4)) {
        _ = try FarJumpingStrategy().rerank(input, with: .empty(at: instant))
    }
}

@Test func archivalDeclaresAZeroBoundSoAnyMovementWouldBeCaught() {
    // 這一檔的「永遠不動」先前只是註解。現在 seam 用 `displacementBound = 0`
    // 呼叫守衛，所以它是守衛會擋的事。
    #expect(ArchivalStrategy().displacementBound == 0)
}

@Test func nonMonotonicBandsAreRejectedAtTheSeamEntry() {
    // R5：守衛的帶圍籬是**逐位**比對，只在同一個帶形成單一連續區段時才等價於
    // 「不得跨帶移動」。反例 `[A(0), B(1), C(0)]` → `[C, B, A]`：逐位帶序列
    // 仍是 `[0,1,0]`、集合沒變、位移在上限內，全部放行——但 A 與 C 都跨過了 B。
    // 與其把圍籬改成兩兩比較，不如在入口要求輸入有序：檢索本來就是照相關性
    // 排出來的。
    let outOfOrder = [
        Candidate(anchor: testAnchor("a"), baseScore: 0.9, band: RelevanceBand(rank: 0)),
        Candidate(anchor: testAnchor("b"), baseScore: 0.5, band: RelevanceBand(rank: 1)),
        Candidate(anchor: testAnchor("c"), baseScore: 0.4, band: RelevanceBand(rank: 0)),
    ]
    #expect(throws: StrategyViolation.bandsOutOfOrder(at: 2)) {
        _ = try HumanLikeStrategy().rerank(outOfOrder, with: .empty(at: instant))
    }
    // 三檔都必須擋——這是 seam 的前置條件，不是某一檔的自律。
    #expect(throws: StrategyViolation.bandsOutOfOrder(at: 2)) {
        _ = try ArchivalStrategy().rerank(outOfOrder, with: .empty(at: instant))
    }
    #expect(throws: StrategyViolation.bandsOutOfOrder(at: 2)) {
        _ = try ConservativeStrategy().rerank(outOfOrder, with: .empty(at: instant))
    }
}

@Test func theGuardWouldOtherwiseAcceptTheNonMonotonicBandSwap() throws {
    // 把上一條的理由釘成事實：**守衛本身**確實會放行那個交換。沒有這條，
    // 「入口前置條件是必要的」只是我的說法。
    let original = [
        Candidate(anchor: testAnchor("a"), baseScore: 0.9, band: RelevanceBand(rank: 0)),
        Candidate(anchor: testAnchor("b"), baseScore: 0.5, band: RelevanceBand(rank: 1)),
        Candidate(anchor: testAnchor("c"), baseScore: 0.4, band: RelevanceBand(rank: 0)),
    ]
    let swapped = [original[2], original[1], original[0]]
    #expect(throws: Never.self, "守衛放行了跨帶移動——這正是入口要擋的原因") {
        _ = try RankingGuard.check(original: original, reordered: swapped, bound: 2)
    }
}
