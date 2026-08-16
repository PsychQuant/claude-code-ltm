import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// #1 verify 2026-08-11：守衛原本只檢查 count、逐位 band、以及「每個輸出 anchor
// 在原輸入中找得到」。三者的交集**不等於**排列——重複與遺漏都能通過。

@Test func duplicatedCandidateInOutputIsRejected() {
    let original = candidates(["a", "b", "c"])
    // [A, B, C] → [A, A, C]：count 相同、band 逐位相同、每筆都查得到原索引，
    // 而 B 被靜默吞掉。
    let forged = [original[0], original[0], original[2]]

    #expect(throws: StrategyViolation.candidateSetChanged) {
        _ = try RankingGuard.check(original: original, reordered: forged, bound: 1)
    }
}

@Test func candidateWithTamperedFieldsIsRejected() {
    let original = candidates(["a", "b"])
    // 同一個 anchor、換掉 baseScore。只比 anchor 的守衛會放行。
    let tampered = [
        Candidate(anchor: original[0].anchor, baseScore: 999, band: original[0].band),
        original[1],
    ]

    #expect(throws: StrategyViolation.candidateSetChanged) {
        _ = try RankingGuard.check(original: original, reordered: tampered, bound: 1)
    }
}

@Test func duplicateAnchorsInInputAreRejected() {
    // 上游沒去重（lexical 與 vector 送了同一段）。必須外顯，因為下游的交錯器
    // 會因為相異 anchor 少於 count 而空轉。
    let a = candidates(["a"])[0]
    let original = [a, a]

    #expect(throws: StrategyViolation.candidateSetChanged) {
        _ = try RankingGuard.check(original: original, reordered: original, bound: 1)
    }
}

@Test func anOverBoundDemotionIsRejectedJustLikeAnOverBoundPromotion() {
    // #1 verify R4 CRITICAL：**把守衛的 `abs()` 拿掉（改回單向），118 個測試
    // 全部照過**——套件裡沒有任何一條測試餵給守衛一個超限的**下移**。
    //
    // 唯一那條違規測試（`exceedingTheDisplacementBoundIsReportedNotClamped`）
    // 驅動的是 +4 的**提升**，單向檢查一樣擋得住。所以對稱契約——這一輪的
    // 招牌修復——完全沒有被釘住。
    let original = candidates(["a", "b", "c", "d", "e"])
    // 第 0 名沉到最後：位移 -4，提升側完全沒有超限。
    let demoted = Array(original.dropFirst()) + [original[0]]

    #expect(throws: StrategyViolation.displacementBoundExceeded(bound: 1, attempted: 4)) {
        _ = try RankingGuard.check(original: original, reordered: demoted, bound: 1)
    }
    // 界內的下移仍然放行——否則上面那條可以被一個「拒絕所有下移」滿足。
    let swapped = [original[1], original[0]] + Array(original.dropFirst(2))
    #expect(throws: Never.self) {
        _ = try RankingGuard.check(original: original, reordered: swapped, bound: 1)
    }
}

@Test func genuinePermutationStillPasses() throws {
    let original = candidates(["a", "b", "c"])
    let swapped = [original[1], original[0], original[2]]

    let placements = try RankingGuard.check(original: original, reordered: swapped, bound: 1)
    #expect(placements.map(\.displacement) == [1, -1, 0])
}
