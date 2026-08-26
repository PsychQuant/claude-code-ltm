import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// 依賴約束的驗證標的是 Package.swift：LTMQuery 的 dependencies 只有 LTMCore，
// 所以 `FileEventStore` 在本模組不是可見型別。
//
// **這條約束比先前寫的弱**（#1 verify 2026-08-11，devils-advocate 實測）：擋住的
// 只是那個便利型別，JSON Lines 格式與 `Event: Codable` 都在 LTMCore，用
// Foundation 直接讀檔即可繞過。把它寫成「編譯期事實」是過度宣稱，已更正。
//
// **但「沒有執行點」也是過度宣稱**（這裡先前正是那樣寫的）。那條 SHALL NOT 想保護
// 的東西有執行點，只是不在依賴圖上：排序正確性在 seam 的那組檢查，隱私在 canonical
// store 的 bytes 層 round-trip。逐一具名寫在 `memory-strategy` spec 的
// 「MemoryStrategy is the sole seam between retrieval and memory」requirement。

let instant = Date(timeIntervalSince1970: 3_000_000)

func testAnchor(_ id: String) -> Anchor {
    Anchor(
        source: "fixture-a",
        turn: Turn(id: id, role: "user", timestamp: Date(), text: "合成候選文字 \(id)，長度足夠切出 span。"),
        span: 0..<8, key: .forTesting)
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
    /// 觸發測試授權註冊（見 `StrategyRegistry.readyForTesting`）。
    private let authorized = StrategyRegistry.readyForTesting
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
    /// 觸發測試授權註冊（見 `StrategyRegistry.readyForTesting`）。
    private let authorized = StrategyRegistry.readyForTesting
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

/// 把候選整個反轉、跨帶，且**據實回報**位移與 movement。
///
/// R6：上一版對反轉後的每一筆都回報 `displacement: 0`，於是它先撞上
/// `misreportedDisplacement`——把帶檢查整個拿掉，測試照樣（因為別的理由）變綠。
private struct BandCrossingStrategy: MemoryStrategy {
    let id = RankingPolicyID("band-crossing")
    /// 觸發測試授權註冊（見 `StrategyRegistry.readyForTesting`）。
    private let authorized = StrategyRegistry.readyForTesting
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 99
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        let candidates = input.candidates
        var index: [Anchor: Int] = [:]
        for (i, c) in candidates.enumerated() { index[c.anchor] = i }
        return candidates.reversed().enumerated().map { newIndex, candidate in
            let displacement = index[candidate.anchor]! - newIndex
            return RankedResult(
                candidate: candidate, displacement: displacement,
                reason: RankingReason.describing(
                    candidate.anchor, displacement: displacement, in: projection))
        }
    }
}

/// 丟掉一筆候選、重複另一筆。**不呼叫任何守衛**，走 seam 的正常入口。
private struct SetChangingStrategy: MemoryStrategy {
    let id = RankingPolicyID("set-changing")
    /// 觸發測試授權註冊（見 `StrategyRegistry.readyForTesting`）。
    private let authorized = StrategyRegistry.readyForTesting
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 99
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        let first = input.candidates[0]
        return input.candidates.map {
            RankedResult(
                candidate: $0.anchor == input.candidates.last?.anchor ? first : $0,
                displacement: 0,
                reason: RankingReason(history: .none, movement: .unmoved))
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
    // **具名錯誤，不是「有拋就好」**（#1 verify R6）：上一版只斷言有 error，
    // 而這個 double 當時回報的位移是假的，所以它撞的是 `misreportedDisplacement`
    // ——把帶檢查拿掉測試照樣綠。現在 double 據實回報，錯誤必須是帶違規。
    var input = candidates(["a"])
    input += [Candidate(anchor: testAnchor("z"), baseScore: 0.1, band: RelevanceBand(rank: 1))]

    #expect(throws: StrategyViolation.crossedRelevanceBand(
        expected: RelevanceBand(rank: 0), found: RelevanceBand(rank: 1))
    ) {
        _ = try BandCrossingStrategy().rerank(input, with: .empty(at: instant))
    }
}

@Test func theSeamRejectsAChangedCandidateSetEndToEnd() {
    // R6：排列性的對抗測試全部**直接呼叫 `RankingGuard.check`**，沒有一條
    // 經由 `MemoryStrategy.rerank`。於是 seam 不再呼叫守衛時，沒有任何測試會紅
    // ——而 seam 的全部理由就是「第三方策略不可繞過」。
    #expect(throws: StrategyViolation.candidateSetChanged) {
        _ = try SetChangingStrategy().rerank(candidates(["a", "b", "c"]), with: .empty(at: instant))
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
    /// 觸發測試授權註冊（見 `StrategyRegistry.readyForTesting`）。
    private let authorized = StrategyRegistry.readyForTesting
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


// MARK: - projection 側的形狀（#1 verify R5；R3 只修了 base score 那一側）

private func statsProjection(_ entries: [(String, AnchorStatistics)]) -> Projection {
    var stats: [Anchor: AnchorStatistics] = [:]
    for (id, s) in entries { stats[testAnchor(id)] = s }
    return Projection(statistics: stats, instant: instant)
}

@Test func aNonFiniteStrengthIsRejectedRatherThanSilentlyDisablingReordering() {
    // 不修的話這是**靜默退化**而不是錯誤：`NaN > x` 與 `x > NaN` 都為 false，
    // 於是有界重排一次交換都不做、`human-like` 對那一帶等於 `archival`，
    // 而被大量引用的 anchor 永遠卡在 NaN 鄰居後面。
    let p = statsProjection([
        ("a", AnchorStatistics(
            reinforcement: .nan, suppression: 0, impressions: 0,
            lastDeliberateInteraction: instant)),
        ("b", AnchorStatistics(
            reinforcement: 10, suppression: 0, impressions: 0,
            lastDeliberateInteraction: instant, deliberateCounts: [.cited: 10])),
    ])
    #expect(throws: StrategyViolation.malformedStatistics(
        testAnchor("a"), .nonFinite(field: "reinforcement"))
    ) {
        _ = try HumanLikeStrategy().rerank(candidates(["a", "b"]), with: p)
    }
}

@Test func aNegativeReinforcementIsRejected() {
    // 負 reinforcement 讓一個增強事件變成壓抑。型別 doc 先前逐字寫「永遠 ≥ 0」
    // 而沒有任何機制支撐那句話。
    let p = statsProjection([
        ("a", AnchorStatistics(
            reinforcement: -5, suppression: 0, impressions: 0,
            lastDeliberateInteraction: instant))
    ])
    #expect(throws: StrategyViolation.malformedStatistics(
        testAnchor("a"), .negative(field: "reinforcement"))
    ) {
        _ = try ConservativeStrategy().rerank(candidates(["a", "b"]), with: p)
    }
}

@Test func theCheckRunsOnTheWholeProjectionNotJustTheCandidatesInPlay() {
    // 一筆壞統計即使這次沒被用到，下一次查詢就會用到——那時錯誤會出現在另一個
    // 地方、看起來像另一個問題。所以驗整份。
    let p = statsProjection([
        ("unused", AnchorStatistics(
            reinforcement: .infinity, suppression: 0, impressions: 0,
            lastDeliberateInteraction: instant))
    ])
    #expect(throws: StrategyViolation.malformedStatistics(
        testAnchor("unused"), .nonFinite(field: "reinforcement"))
    ) {
        _ = try HumanLikeStrategy().rerank(candidates(["a", "b"]), with: p)
    }
}

@Test func archivalIsNotDisabledByAMalformedProjectionItNeverReads() throws {
    // **R5 的修法在這裡越界了**（#1 verify R6 的 CRITICAL）：無條件驗 projection
    // 讓 `archival` 因為一筆它從不讀取的統計而失敗。它的契約逐字是「不論給它
    // 什麼 projection 都產出相同輸出」，而它存在的理由正是當記憶層本身可疑時
    // 仍然可用的對照組——壞掉的記憶資料把對照組關掉，等於在最需要比較的那一刻
    // 不能比較。
    //
    // 判準：一個策略只受**它能消費的資料**的約束。`archival` 的
    // `consumedSignals` 是空集合。
    let poisoned = statsProjection([
        ("a", AnchorStatistics(
            reinforcement: .nan, suppression: -5, impressions: -1,
            lastDeliberateInteraction: instant))
    ])
    let input = candidates(["a", "b"])
    let output = try ArchivalStrategy().rerank(input, with: poisoned)
    #expect(output.map(\.candidate) == input)
    #expect(output.allSatisfy { $0.displacement == 0 })

    // 而同一份 projection 對會消費歷史的策略仍然必須擋。
    #expect(throws: (any Error).self) {
        _ = try HumanLikeStrategy().rerank(input, with: poisoned)
    }
}


/// 順序不動、displacement 誠實，卻在 `reason.movement` 上說謊。
private struct MovementLiar: MemoryStrategy {
    let id = RankingPolicyID("movement-liar")
    /// 觸發測試授權註冊（見 `StrategyRegistry.readyForTesting`）。
    private let authorized = StrategyRegistry.readyForTesting
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 0
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        input.candidates.map {
            RankedResult(
                candidate: $0, displacement: 0,
                reason: RankingReason(history: .none, movement: .advanced(positions: 999)))
        }
    }
}

@Test func aStrategyCannotLieAboutMovementEvenWhenDisplacementIsHonest() {
    // R6：`displacement` 與 `reason.movement` 陳述同一件事，而 R5 只驗了前者。
    // 一個策略可以回傳原順序、displacement 全 0，卻附上
    // `movement: .advanced(positions: 999)`，報告照讀。
    #expect(throws: StrategyViolation.misreportedMovement(
        testAnchor("a"), reported: .advanced(positions: 999), actual: .unmoved)
    ) {
        _ = try MovementLiar().rerank(candidates(["a", "b"]), with: .empty(at: instant))
    }
}


private struct NegativeBoundStrategy: MemoryStrategy {
    let id = RankingPolicyID("negative-bound")
    /// 觸發測試授權註冊（見 `StrategyRegistry.readyForTesting`）。
    private let authorized = StrategyRegistry.readyForTesting
    let consumedSignals: Set<EventKind> = []
    let displacementBound = -1
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        input.candidates.map {
            RankedResult(
                candidate: $0, displacement: 0,
                reason: RankingReason(history: .none, movement: .unmoved))
        }
    }
}

@Test func aNegativeDisplacementBoundIsThrownNotTrapped() {
    // R6：負的上限來自**外來策略**，不是程式錯誤，所以中止行程是錯的處置。
    // `RankingGuard.check` 的 `precondition(bound >= 0)` 會讓一個合規 conformer
    // 把整個行程帶走。
    #expect(throws: StrategyViolation.negativeDisplacementBound(-1)) {
        _ = try NegativeBoundStrategy().rerank(candidates(["a"]), with: .empty(at: instant))
    }
}

@Test func anImpressionCannotMasqueradeAsADeliberateSignal() {
    // R6：`deliberateCounts` 收得下 `.shown`，於是一次曝光會在 reason 裡冒充
    // 成增強訊號——而 spec 明寫「只有曝光等同於沒有事件」。
    let p = statsProjection([
        ("a", AnchorStatistics(
            reinforcement: 1, suppression: 0, impressions: 0,
            lastDeliberateInteraction: instant, deliberateCounts: [.shown: 3]))
    ])
    #expect(throws: StrategyViolation.malformedStatistics(
        testAnchor("a"), .impressionAsDeliberateSignal)
    ) {
        _ = try HumanLikeStrategy().rerank(candidates(["a", "b"]), with: p)
    }
}


// MARK: - R6：非有限只測過 NaN、壞統計只測過 reinforcement

@Test func infinityIsRejectedEverywhereNaNIs() {
    // R6：所有「非有限」測試都只用 NaN，於是一個只檢查 `isNaN` 的半吊子修法
    // 會在每一處通過。±infinity 是同一個判準的另一半。
    let badScore = [
        Candidate(anchor: testAnchor("x"), baseScore: .infinity, band: RelevanceBand(rank: 0))
    ]
    #expect(throws: StrategyViolation.nonFiniteBaseScore(testAnchor("x"))) {
        _ = try HumanLikeStrategy().rerank(badScore, with: .empty(at: instant))
    }
    let negative = [
        Candidate(anchor: testAnchor("y"), baseScore: -.infinity, band: RelevanceBand(rank: 0))
    ]
    #expect(throws: StrategyViolation.nonFiniteBaseScore(testAnchor("y"))) {
        _ = try ConservativeStrategy().rerank(negative, with: .empty(at: instant))
    }
}

@Test func everyNumericStatisticFieldIsChecked() {
    // R6：壞統計的測試只曾污染 `reinforcement`，於是 `suppression`、
    // `impressions`、`deliberateCounts` 的檢查沒有任何測試釘住。
    let cases: [(String, AnchorStatistics, AnchorStatistics.Malformation)] = [
        ("suppression 非有限",
         AnchorStatistics(
            reinforcement: 0, suppression: .nan, impressions: 0,
            lastDeliberateInteraction: instant),
         .nonFinite(field: "suppression")),
        ("suppression 負值",
         AnchorStatistics(
            reinforcement: 0, suppression: -1, impressions: 0,
            lastDeliberateInteraction: instant),
         .negative(field: "suppression")),
        ("impressions 負值",
         AnchorStatistics(
            reinforcement: 0, suppression: 0, impressions: -1,
            lastDeliberateInteraction: instant),
         .negative(field: "impressions")),
        ("deliberateCounts 負值",
         AnchorStatistics(
            reinforcement: 0, suppression: 0, impressions: 0,
            lastDeliberateInteraction: instant, deliberateCounts: [.cited: -2]),
         .negative(field: "deliberateCounts[cited]")),
    ]
    for (label, stats, expected) in cases {
        let p = statsProjection([("a", stats)])
        #expect(
            throws: StrategyViolation.malformedStatistics(testAnchor("a"), expected),
            "\(label) 沒有被擋下來"
        ) {
            _ = try HumanLikeStrategy().rerank(candidates(["a", "b"]), with: p)
        }
    }
}

// MARK: - provenance 的另一半：history（#21 item 1）

/// 宣稱有訊號促成，而 projection 裡什麼都沒有。
private struct HistoryFabricator: MemoryStrategy {
    let id = RankingPolicyID("history-fabricator")
    private let authorized = StrategyRegistry.readyForTesting
    let consumedSignals: Set<EventKind> = [.cited]
    let displacementBound = 0
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        input.candidates.map {
            RankedResult(
                candidate: $0, displacement: 0,
                reason: RankingReason(
                    history: .counted(signals: [.cited: 99], netStrength: 42),
                    movement: .unmoved))
        }
    }
}

@Test func aFabricatedHistoryIsRejectedEvenWhenTheOrderIsUntouched() throws {
    // seam 先前只驗 displacement 與 movement。一個策略可以完全不動順序——於是
    // 前兩者都誠實——卻附上一份憑空編出來的 provenance，而報告會照讀。
    //
    // `misreportedDisplacement` 的存在理由逐字是「provenance 若可以說謊，比較
    // 實驗讀到的就不是實際發生的事」，而那條理由對 history 一樣適用。
    // **斷言具體是哪一個違規。** 第一版寫 `throws: StrategyViolation.self`，而
    // 變異測試當場證明它為錯的理由通過：`"history-fabricator"` 當時不在
    // `testIdentifiers` 裡，所以 seam 拋的是 `unauthorizedStrategy`——把 history
    // 檢查整條關掉，這條測試照樣綠。
    //
    // 與 #22 item 9 是同一個形狀（`throws: (any Error).self` 分辨不出是哪一個），
    // 而我在修完那一條之後的同一個工作階段又犯了一次。
    do {
        _ = try HistoryFabricator().rerank(candidates(["a", "b"]), with: .empty(at: instant))
        Issue.record("編造的 history 應該被擋下來")
    } catch let violation as StrategyViolation {
        guard case .misreportedHistory = violation else {
            Issue.record("擋下來了，但不是因為 history：\(violation)")
            return
        }
    }
}

@Test func reportingNoHistoryIsAlwaysAllowed() throws {
    // 不對稱是刻意的：**可以少報，不可以編造**。`archival` 的契約逐字是「不論
    // 給它什麼 projection 都產出相同輸出」，所以它報 `.none` 正是它該做的事。
    //
    // 第一版寫成嚴格相等，16 條測試同時變紅——而它們是對的。
    let output = try IdentityProbe().rerank(candidates(["a", "b"]), with: .empty(at: instant))
    #expect(output.allSatisfy { $0.reason.history == .none })
}

@Test func netStrengthWithoutNamedSignalsIsMalformed() throws {
    // #21 item 4：`counted` 卻指不出任何訊號。
    //
    // 與 `misreportedHistory` 是同一條線的兩側——一個編造來源，一個宣稱有來源
    // 卻拿不出來。兩者對讀者的後果相同：他讀到的不是實際發生的事。
    let silent = AnchorStatistics(
        reinforcement: 5, suppression: 0, impressions: 0,
        lastDeliberateInteraction: nil, deliberateCounts: [:])
    #expect(silent.malformation == .countedWithoutSignals)

    // 淨強度為零時沒有訊號是正常的——那是「歷史沒有讓它動」，不是「說不出話」。
    let quiet = AnchorStatistics(
        reinforcement: 0, suppression: 0, impressions: 7,
        lastDeliberateInteraction: nil, deliberateCounts: [:])
    #expect(quiet.malformation == nil)
}

/// 宣告不消費任何訊號，藉此躲掉 projection 形狀檢查。
private struct SignalDenier: MemoryStrategy {
    let id = RankingPolicyID("human-like")  // 冒用一個授權表認得的識別碼
    private let authorized = StrategyRegistry.readyForTesting
    let consumedSignals: Set<EventKind> = []  // ← 自報空集合
    let displacementBound = 0
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        input.candidates.map {
            RankedResult(
                candidate: $0, displacement: 0,
                reason: RankingReason(history: .none, movement: .unmoved))
        }
    }
}

@Test func declaringNoSignalsDoesNotEscapeTheProjectionShapeCheck() throws {
    // #21 item 5：seam 先前用 `if !consumedSignals.isEmpty` 決定要不要驗
    // projection 形狀，而那個值是策略自報的——宣告空集合即可拿到一份未經驗證的
    // projection。**讓被約束者提供約束值**，本 repo 的第四次。
    //
    // 合成取聯集之後，冒用 `human-like` 這個識別碼就吃得到表裡那一份，宣告空
    // 集合減不掉它。
    let malformed = Projection(
        statistics: [
            candidates(["a"])[0].anchor: AnchorStatistics(
                reinforcement: .nan, suppression: 0, impressions: 0,
                lastDeliberateInteraction: nil, deliberateCounts: [:])
        ],
        instant: instant)

    #expect(throws: StrategyViolation.self) {
        _ = try SignalDenier().rerank(candidates(["a"]), with: malformed)
    }
}

// MARK: - token 繞過（#14）

/// 把收到的 token 存下來，之後拿它直接呼叫 `rerankChecked`。
private final class TokenHoarder: @unchecked Sendable, MemoryStrategy {
    let id = RankingPolicyID("identity-probe")
    private let authorized = StrategyRegistry.readyForTesting
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 0
    var stolen: ValidatedCandidates?

    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        stolen = input  // ← 這就是繞過路徑的第一步
        return input.candidates.map {
            RankedResult(
                candidate: $0, displacement: 0,
                reason: RankingReason(history: .none, movement: .unmoved))
        }
    }
}

@Test("存下來的 token 在 seam 呼叫結束後失效")
func aStoredTokenIsDeadAfterTheCallReturns() async {
    // #14 的核心殘留：`rerankChecked` 是 public requirement，而它收的
    // `ValidatedCandidates` 先前是純值——可儲存、可轉手。於是任何程式碼日後都能
    // 拿它直接呼叫 `rerankChecked`，**跳過 seam 的全部檢查**。
    //
    // 這條驗的是那條路徑現在通往哪裡：通往一張死掉的 token。
    await #expect(processExitsWith: .failure) {
        let hoarder = TokenHoarder()
        _ = try hoarder.rerank(candidates(["a", "b"]), with: .empty(at: instant))
        let stolen = hoarder.stolen!
        _ = stolen.candidates  // ← 呼叫已經返回，這裡該 trap
    }
}

@Test("呼叫進行中 token 是活的——失效不能早於它該失效的時候")
func theTokenIsLiveWhileTheCallIsRunning() throws {
    // 反向對照：一個無條件失效的實作也能讓上面那條變綠。
    let hoarder = TokenHoarder()
    let output = try hoarder.rerank(candidates(["a", "b"]), with: .empty(at: instant))
    #expect(output.count == 2, "呼叫當下讀得到候選，否則策略根本做不了事")
}

/// 冒用一個授權識別碼，自報一個比天花板寬的上限。
private struct BoundInflater: MemoryStrategy {
    let id = RankingPolicyID("human-like")
    private let authorized = StrategyRegistry.readyForTesting
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 99
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        input.candidates.map {
            RankedResult(
                candidate: $0, displacement: 0,
                reason: RankingReason(history: .none, movement: .unmoved))
        }
    }
}

@Test("自報一個超過天花板的位移上限會被拒絕，而不是靜默截斷")
func anInflatedDisplacementBoundIsRefusedNotClamped() {
    // #38：授權表承載不了 bound 的**值**（spec 要求它可在建構時組態），但承載得了
    // **上界**。合成因此取 min，與 placementConstraints 的 union 是同一個形狀的
    // 兩側：策略只能收緊，不能放寬。
    //
    // **拒絕而不是截斷**：一個要求 99 卻拿到 10 的呼叫端沒有任何訊號，而它會以為
    // 自己的策略在做它沒在做的事。靜默收窄與靜默放寬一樣糟，只是方向相反。
    do {
        _ = try BoundInflater().rerank(candidates(["a", "b"]), with: .empty(at: instant))
        Issue.record("超過天花板的上限應該被拒絕")
    } catch let violation as StrategyViolation {
        guard case .unauthorizedDisplacementBound(let declared, let ceiling) = violation else {
            Issue.record("擋下來了，但不是因為上限：\(violation)")
            return
        }
        #expect(declared == 99)
        #expect(ceiling == 10)
    } catch {
        Issue.record("非預期錯誤：\(error)")
    }
}

@Test("天花板之內的上限照常通過——不能把合法組態也擋掉")
func aBoundWithinTheCeilingIsAccepted() throws {
    // 反向對照：一個無條件拒絕的實作也能讓上面那條變綠。
    let output = try HumanLikeStrategy(displacementBound: 3)
        .rerank(candidates(["a", "b", "c"]), with: .empty(at: instant))
    #expect(output.count == 3)
}
