import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// 這一檔記錄一段來回，因為結論看起來像退步：
//
// - **R1**（2026-08-11）：verify 抓到 `HumanLikeStrategy` 對一般輸入拋
//   `displacementBoundExceeded`——當時契約是**對稱**上限，演算法卻只約束提升。
// - **R1 的修法**：swap 前檢查被越過方的累計下移，超限就放棄提升。
// - **R2**（2026-08-14）：量化證明那個修法選錯邊。對稱上限的算術讓「一條帶的
//   提升總數上限＝bound，與帶大小無關」——32 個候選、31 個有歷史，bound 1 時
//   實際上移總數是 **1**。策略差異量不到。
// - **裁決**（#17，2026-08-15）：改契約——上限只約束**提升**，下移是他人提升的
//   後果，據實回報但不另設限。圍住傷害的是相關性帶，不是位移上限。
//
// 所以本檔的斷言從 `abs(displacement) <= bound` 改為 `displacement <= bound`，
// 並**明確斷言下移可以超過上限**——那是刻意的語意，不是漏網。

private func multiStrengthProjection(_ entries: [(Anchor, Double)]) -> Projection {
    var stats: [Anchor: AnchorStatistics] = [:]
    for (anchor, strength) in entries {
        stats[anchor] = AnchorStatistics(
            reinforcement: strength, suppression: 0, impressions: 0,
            lastDeliberateInteraction: instant, deliberateCounts: [.cited: Int(strength)])
    }
    return Projection(statistics: stats, instant: instant)
}

@Test func promotionNeverExceedsTheBoundWhenManyPeersAreReinforced() throws {
    // R1 的反例：bound = 1，同帶 [a:0, b:6, c:4, d:2]。
    let input = candidates(["a", "b", "c", "d"])
    let projection = multiStrengthProjection([
        (testAnchor("b"), 6), (testAnchor("c"), 4), (testAnchor("d"), 2),
    ])

    let output = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: projection)

    for result in output {
        #expect(
            result.displacement <= 1,
            "\(result.candidate.anchor.turnID) 提升 \(result.displacement) 名，超過上限")
    }
}

@Test func demotionMayExceedTheBoundAndThatIsTheContract() throws {
    // 同一個輸入：a 沒有歷史，被 b、c、d 各跳過一次 → 下移三格。
    // **這是契約，不是違規。** R1 那版會為此拋錯，代價是整條帶只剩一次提升。
    let input = candidates(["a", "b", "c", "d"])
    let projection = multiStrengthProjection([
        (testAnchor("b"), 6), (testAnchor("c"), 4), (testAnchor("d"), 2),
    ])

    let output = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: projection)
    let positions = output.map(\.candidate.anchor)

    #expect(positions == [testAnchor("b"), testAnchor("c"), testAnchor("d"), testAnchor("a")])
    let a = output.first { $0.candidate.anchor == testAnchor("a") }!
    #expect(a.displacement == -3)  // 下移三格，超過 bound 1
}

@Test func everyReinforcedCandidateGetsPromotedNotJustTheFirst() throws {
    // R2 量化的那件事的反面：對稱上限之下這條會失敗（整帶只有 1 次提升）。
    // 單向上限之下，每個有歷史的候選都真的往前走。
    let ids = (0..<12).map { "c\($0)" }
    let input = candidates(ids)
    // 第 0 名沒有歷史（帶首擋路者），其餘遞減強度。
    let entries = ids.dropFirst().enumerated().map { (testAnchor($1), Double(12 - $0)) }

    let output = try HumanLikeStrategy(displacementBound: 1)
        .rerank(input, with: multiStrengthProjection(entries))

    let promoted = output.filter { $0.displacement > 0 }.count
    #expect(promoted >= 10, "只有 \(promoted) 個候選被提升——帶首擋路者又把整條帶卡住了")
}

@Test(arguments: [1, 2, 3])
func promotionBoundHoldsAcrossManyStrengthPatterns(bound: Int) throws {
    let ids = ["c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7"]
    let input = candidates(ids)
    let strengths: [Double] = [0, 7, 3, 0, 5, 1, 6, 2]

    for rotation in 0..<ids.count {
        let entries = ids.enumerated().map { index, id -> (Anchor, Double) in
            (testAnchor(id), strengths[(index + rotation) % strengths.count])
        }
        let output = try HumanLikeStrategy(displacementBound: bound)
            .rerank(input, with: multiStrengthProjection(entries.filter { $0.1 > 0 }))

        #expect(output.count == input.count)
        for result in output {
            #expect(
                result.displacement <= bound,
                "rotation \(rotation) bound \(bound)：\(result.candidate.anchor.turnID) 提升 \(result.displacement)")
        }
        // 排列性質仍然成立——下移不設限不代表可以憑空增刪。
        #expect(Set(output.map(\.candidate.anchor)) == Set(input.map(\.anchor)))
    }
}

@Test func aStrategyThatLeapsBeyondTheBoundStillFailsLoudly() {
    // 上限單向化之後，守衛仍必須擋住「單一項目暴衝」——那才是它要防的東西。
    let input = candidates(["a", "b", "c", "d", "e"])
    let leapt = [input[4]] + input.dropLast()  // 第 4 名跳到第 0 名

    #expect(throws: StrategyViolation.displacementBoundExceeded(bound: 1, attempted: 4)) {
        _ = try RankingGuard.check(original: input, reordered: leapt, bound: 1)
    }
}
