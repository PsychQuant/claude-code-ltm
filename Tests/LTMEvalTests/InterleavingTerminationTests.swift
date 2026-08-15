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

/// 回傳非排列的策略。不呼叫 RankingGuard——`MemoryStrategy` 並不強制，
/// 這正是問題所在。
private struct TruncatingStrategy: MemoryStrategy {
    let id = RankingPolicyID("truncating")
    let consumedSignals: Set<EventKind> = []
    func rerank(_ candidates: [Candidate], with projection: Projection) throws -> [RankedResult] {
        candidates.dropLast().map {
            RankedResult(candidate: $0, displacement: 0, reason: .noAdjustment)
        }
    }
}

@Test func duplicateAnchorsInCandidatesAreRejectedRatherThanSpinning() {
    let a = evalCandidates(["a"])[0]
    let b = evalCandidates(["b"])[0]
    let withDuplicate = [a, a, b]

    #expect(throws: InterleavingViolation.duplicateCandidate(a.anchor)) {
        _ = try InterleavingHarness(generation: evalGeneration).present(
            query: "測試查詢", candidates: withDuplicate, projection: .empty(at: evalInstant),
            a: ArchivalStrategy(), b: HumanLikeStrategy(), startingSide: .a)
    }
}

@Test func aStrategyReturningANonPermutationIsRejected() {
    let input = evalCandidates(["a", "b", "c"])

    #expect(throws: InterleavingViolation.strategyReturnedNonPermutation(
        policy: RankingPolicyID("truncating"))
    ) {
        _ = try InterleavingHarness(generation: evalGeneration).present(
            query: "測試查詢", candidates: input, projection: .empty(at: evalInstant),
            a: TruncatingStrategy(), b: ArchivalStrategy(), startingSide: .a)
    }
}

@Test func harnessTerminatesOnASingleCandidate() throws {
    let input = evalCandidates(["only"])
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: "測試查詢", candidates: input, projection: .empty(at: evalInstant),
        a: ArchivalStrategy(), b: HumanLikeStrategy(), startingSide: .a)

    #expect(result.presented.count == 1)
}

@Test func harnessTerminatesOnAnEmptyCandidateList() throws {
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: "測試查詢", candidates: [], projection: .empty(at: evalInstant),
        a: ArchivalStrategy(), b: HumanLikeStrategy(), startingSide: .a)

    #expect(result.presented.isEmpty)
}
