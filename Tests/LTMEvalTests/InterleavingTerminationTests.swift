import Foundation
import Testing

@testable import LTMCore
@testable import LTMEval
@testable import LTMQuery

// #1 verify 2026-08-11（logic lens）：舊的 team-draft 迴圈只用「已呈現數」當終止
// 條件，兩邊都取盡時在兩個 guard 之間無限翻面。實測 test bundle 掛住、CPU
// 累積 3:44，須 kill -9。上線等同整條查詢路徑 hang 而不是回一個錯誤。
//
// 這一檔的每條測試都必須在有限時間內返回——它們本身就是「不會掛住」的證據。

/// 回傳非排列的策略。**它照樣不呼叫任何守衛**——重點正在這裡：R4 之前
/// `MemoryStrategy` 不強制，這種策略能一路跑到交錯器裡；現在 seam 的
/// `rerank` 是 extension 上的非 customization point，它連出 seam 都出不去。
private struct TruncatingStrategy: MemoryStrategy {
    let id = RankingPolicyID("truncating")
    /// 觸發測試授權註冊（見 `StrategyRegistry.readyForTesting`）。
    private let authorized = StrategyRegistry.readyForTesting
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 99
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws -> [RankedResult] {
        let candidates = input.candidates
        return candidates.dropLast().map {
            RankedResult(candidate: $0, displacement: 0, reason: RankingReason(history: .none, movement: .unmoved))
        }
    }
}

@Test(.timeLimit(.minutes(1))) func duplicateAnchorsInCandidatesAreRejectedRatherThanSpinning() {
    let a = evalCandidates(["a"])[0]
    let b = evalCandidates(["b"])[0]
    let withDuplicate = [a, a, b]

    #expect(throws: InterleavingViolation.duplicateCandidate(a.anchor)) {
        _ = try InterleavingHarness(generation: evalGeneration).present(
            query: "測試查詢", candidates: withDuplicate, projection: .empty(at: evalInstant),
            a: ArchivalStrategy(), b: HumanLikeStrategy(), startingSide: .a)
    }
}

@Test(.timeLimit(.minutes(1))) func aStrategyReturningANonPermutationIsRejected() {
    let input = evalCandidates(["a", "b", "c"])

    // 錯誤由 seam 產生、交錯器只補上「是哪一邊」。這條同時釘住兩件事：
    // 契約被強制（`candidateSetChanged`），以及歸屬沒有遺失（`truncating`）。
    #expect(throws: InterleavingViolation.strategyMisbehaved(
        policy: RankingPolicyID("truncating"), violation: .candidateSetChanged)
    ) {
        _ = try InterleavingHarness(generation: evalGeneration).present(
            query: "測試查詢", candidates: input, projection: .empty(at: evalInstant),
            a: TruncatingStrategy(), b: ArchivalStrategy(), startingSide: .a)
    }
}

@Test(.timeLimit(.minutes(1))) func harnessTerminatesOnASingleCandidate() throws {
    let input = evalCandidates(["only"])
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: "測試查詢", candidates: input, projection: .empty(at: evalInstant),
        a: ArchivalStrategy(), b: HumanLikeStrategy(), startingSide: .a)

    #expect(result.presented.count == 1)
}

@Test(.timeLimit(.minutes(1))) func harnessTerminatesOnAnEmptyCandidateList() throws {
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: "測試查詢", candidates: [], projection: .empty(at: evalInstant),
        a: ArchivalStrategy(), b: HumanLikeStrategy(), startingSide: .a)

    #expect(result.presented.isEmpty)
}
