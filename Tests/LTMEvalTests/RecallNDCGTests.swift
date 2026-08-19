import Foundation
import Testing

@testable import LTMCore
@testable import LTMEval

/// 兩階段指標（Recall@20 → nDCG@10）與三軌分報（lexical/vector/fused）的測試。
///
/// 這裡的斷言故意用具體數字釘住 nDCG@10 的計算，不只驗證「有沒有回傳」——
/// 呼應 #28 診斷抓到的教訓：測試要能為了對的理由失敗。

@Test func recallAt20ConfirmsPresenceBeforeAnyRankingScore() {
    let expected = evalAnchor("target")
    // top-20 裡不含 expected anchor：20 個其他 anchor。
    let retrieved = (0..<20).map { evalAnchor("other-\($0)") }
    let outcome = scoreRecallAndRanking(retrieved: retrieved, expected: expected)
    #expect(outcome == .notRecalled)
}

@Test func anEmptyRetrievedListIsNotRecalled() {
    let expected = evalAnchor("target")
    let outcome = scoreRecallAndRanking(retrieved: [], expected: expected)
    #expect(outcome == .notRecalled)
}

@Test func rankOneYieldsThePerfectNDCG() {
    let expected = evalAnchor("target")
    let retrieved = [expected] + (0..<19).map { evalAnchor("other-\($0)") }
    guard case .recalled(let ndcg) = scoreRecallAndRanking(retrieved: retrieved, expected: expected)
    else {
        Issue.record("expected .recalled — anchor is at rank 1, well within top 20")
        return
    }
    // IDCG 與 DCG 相同（唯一相關項排第一名），nDCG@10 因此恰為 1.0。
    #expect(ndcg == 1.0)
}

@Test func rankTenYieldsALowerButNonzeroNDCG() {
    let expected = evalAnchor("target")
    var retrieved = (0..<9).map { evalAnchor("other-\($0)") }
    retrieved.append(expected)  // rank 10（0-indexed 位置 9）
    retrieved.append(contentsOf: (9..<19).map { evalAnchor("other-\($0)") })
    guard case .recalled(let ndcg) = scoreRecallAndRanking(retrieved: retrieved, expected: expected)
    else {
        Issue.record("expected .recalled — anchor is at rank 10, still within top 10 window")
        return
    }
    // DCG = 1/log2(10+1)，IDCG = 1/log2(1+1) = 1。手算核對，不只驗證「比 1 小」。
    let want = 1.0 / log2(11.0)
    #expect(abs(ndcg - want) < 1e-9)
    #expect(ndcg < 1.0, "rank 10 必須嚴格低於 rank 1 的滿分")
}

@Test func recalledButOutsideTheNDCGWindowScoresZero() {
    let expected = evalAnchor("target")
    // expected 排在第 15 名：在 top-20 recall 窗內，但在 top-10 nDCG 窗外。
    var retrieved = (0..<14).map { evalAnchor("other-\($0)") }
    retrieved.append(expected)
    retrieved.append(contentsOf: (14..<19).map { evalAnchor("other-\($0)") })
    guard case .recalled(let ndcg) = scoreRecallAndRanking(retrieved: retrieved, expected: expected)
    else {
        Issue.record("expected .recalled — anchor is within top 20 even though outside top 10")
        return
    }
    #expect(ndcg == 0.0, "top-10 窗外沒有貢獻，但仍算 recalled（區別於完全沒被檢索到）")
}

// MARK: - 三軌分報（Task 2.1/2.2）

@Test func singleChannelDegradationIsVisibleInTheBreakdown() {
    let expected = evalAnchor("target")
    let others = (0..<19).map { evalAnchor("other-\($0)") }

    // lexical 完全沒找到；vector 與 fused 都在第一名找到。
    let lexicalOnly = others
    let vectorOnly = [expected] + others
    let fused = [expected] + others

    let breakdown = ChannelBreakdown(
        lexical: scoreRecallAndRanking(retrieved: lexicalOnly, expected: expected),
        vector: scoreRecallAndRanking(retrieved: vectorOnly, expected: expected),
        fused: scoreRecallAndRanking(retrieved: fused, expected: expected))

    #expect(breakdown.lexical == .notRecalled)
    guard case .recalled(let vectorNDCG) = breakdown.vector else {
        Issue.record("vector channel should have recalled the expected anchor")
        return
    }
    guard case .recalled(let fusedNDCG) = breakdown.fused else {
        Issue.record("fused channel should have recalled the expected anchor")
        return
    }
    #expect(vectorNDCG == 1.0)
    #expect(fusedNDCG == 1.0)
}
