import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// #32：策略的額外條件由 seam 執行，不由被約束者自己執行。
//
// 這一整檔的存在理由是「回歸鎖必須驅動生產路徑」。先前唯一覆蓋 tie-run 約束的
// 測試從不建構策略——它把手工排列直接餵給 `RankingGuard.checkTieRunsOnly`。
// 於是守衛的**邏輯**有覆蓋，守衛**在生產路徑上被呼叫**這件事沒有：實測把
// `ConservativeStrategy` 那一行換掉，67 條測試全綠。
//
// 下面的 conformer 刻意違規，並且**只透過 `rerank`**（seam 的唯一入口）被呼叫。

/// spec example 的候選：band 1 內 `A: 0.5`, `B: 0.5`, `C: 0.3`。
/// 等分區段是 `{A, B}` 與 `{C}`。
private func exampleCandidates() -> [Candidate] {
    [
        Candidate(anchor: testAnchor("A"), baseScore: 0.5, band: RelevanceBand(rank: 1)),
        Candidate(anchor: testAnchor("B"), baseScore: 0.5, band: RelevanceBand(rank: 1)),
        Candidate(anchor: testAnchor("C"), baseScore: 0.3, band: RelevanceBand(rank: 1)),
    ]
}

/// 一個**刻意不守規矩**的策略：照給定順序回傳，宣告什麼由建構時決定。
///
/// 它自己不做任何檢查——這正是重點。守衛存在的全部理由是攔截這種實作，而在
/// #32 之前，這條路徑從來沒有被走過。
private struct MisbehavingStrategy: MemoryStrategy {
    let id = RankingPolicyID("misbehaving")
    let consumedSignals: Set<EventKind> = []
    let displacementBound: Int
    let placementConstraints: Set<PlacementConstraint>
    /// 要回傳的 anchor 順序。
    let order: [String]

    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        var byAnchor: [Anchor: Candidate] = [:]
        for candidate in input.candidates { byAnchor[candidate.anchor] = candidate }
        var originalIndex: [Anchor: Int] = [:]
        for (i, candidate) in input.candidates.enumerated() { originalIndex[candidate.anchor] = i }

        var results: [RankedResult] = []
        for (newIndex, id) in order.enumerated() {
            let anchor = testAnchor(id)
            guard let candidate = byAnchor[anchor], let from = originalIndex[anchor] else {
                continue
            }
            // 自報的 displacement 必須與實際位置變化一致，否則會撞到 seam 的另一條
            // 後置條件而以錯誤的理由變紅——那會讓這條測試「為錯的理由紅」。
            results.append(
                RankedResult(
                    candidate: candidate,
                    displacement: from - newIndex,
                    reason: RankingReason(history: .none, movement: movement(from: from - newIndex))))
        }
        return results
    }

    private func movement(from displacement: Int) -> RankingReason.Movement {
        if displacement > 0 { return .advanced(positions: displacement) }
        if displacement < 0 { return .receded(positions: -displacement) }
        return .unmoved
    }
}

@Test func aDeclaredTieRunConstraintIsEnforcedBySeamOnAViolatingStrategy() throws {
    // spec scenario「A declared constraint is enforced on a strategy that violates it」
    // 與 example table 第二列：宣告 `[.withinTieRuns]`、回傳 `[C, A, B]`。
    //
    // C 從自己的區段 `{C}` 移進 `{A, B}`——策略自己完全沒檢查，seam 必須擋下。
    let strategy = MisbehavingStrategy(
        displacementBound: 2, placementConstraints: [.withinTieRuns], order: ["C", "A", "B"])

    #expect(throws: StrategyViolation.movedAcrossTieRuns) {
        _ = try strategy.rerank(exampleCandidates(), with: .empty(at: instant))
    }
}

@Test func aDeclaredTieRunConstraintAcceptsMovementInsideARun() throws {
    // example table 第一列：宣告 `[.withinTieRuns]`、回傳 `[B, A, C]` → 通過。
    // 沒有這一列，上一條測試可能是因為「seam 擋掉所有重排」而過，而不是因為
    // 它認得區段邊界。
    let strategy = MisbehavingStrategy(
        displacementBound: 2, placementConstraints: [.withinTieRuns], order: ["B", "A", "C"])

    let results = try strategy.rerank(exampleCandidates(), with: .empty(at: instant))
    #expect(results.map(\.candidate.anchor) == [testAnchor("B"), testAnchor("A"), testAnchor("C")])
}

@Test func aStrategyDeclaringNoConstraintIsNotSubjectedToTheTieRunCheck() throws {
    // spec scenario「A strategy that declares no constraint is not subjected to it」
    // 與 example table **第三列**：宣告 `[]`、同樣回傳 `[C, A, B]` → 通過。
    //
    // 這一列是整組測試的關鍵：**同一個輸出**在第一條測試裡被拒、在這裡被接受，
    // 差別只有宣告。它證明宣告真的在 gate，而不是一條對所有策略都成立的規則。
    // 若把 protocol extension 的預設從空集合翻成 `[.withinTieRuns]`，這條會紅。
    let strategy = MisbehavingStrategy(
        displacementBound: 2, placementConstraints: [], order: ["C", "A", "B"])

    let results = try strategy.rerank(exampleCandidates(), with: .empty(at: instant))
    #expect(results.map(\.candidate.anchor) == [testAnchor("C"), testAnchor("A"), testAnchor("B")])
}

@Test func theShippedStrategiesDeclareTheConstraintsTheSpecSays() throws {
    // 預設方向的鎖：翻成「預設受約束」時，`human-like` 帶內任意重排會被自己的
    // seam 擋掉——而那個失敗會看起來像策略的 bug。
    #expect(ArchivalStrategy().placementConstraints.isEmpty)
    #expect(HumanLikeStrategy().placementConstraints.isEmpty)
    #expect(ConservativeStrategy().placementConstraints == [.withinTieRuns])
}
