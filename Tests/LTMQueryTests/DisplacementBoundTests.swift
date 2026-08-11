import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// 這一檔全部來自 #1 的 verify（2026-08-11）：codex 與 logic 兩個 lens 各自
// 獨立重現「內建策略違反自己的位移上限」，而原本的測試套件系統性地避開了
// 會觸發它的輸入——每個 bound 測試都只讓**單一**候選有強度。
//
// 教訓寫在這裡而不只是 commit message：**同帶多個候選同時有歷史，是常態不是
// 邊角**。任何新的重排策略都應該先過這一檔。

private func multiStrengthProjection(_ entries: [(Anchor, Double)]) -> Projection {
    var stats: [Anchor: AnchorStatistics] = [:]
    for (anchor, strength) in entries {
        stats[anchor] = AnchorStatistics(
            reinforcement: strength, suppression: 0, impressions: 0,
            lastDeliberateInteraction: instant, deliberateCounts: [.cited: Int(strength)])
    }
    return Projection(statistics: stats, instant: instant)
}

@Test func boundHoldsWhenThreeStrongerPeersJumpOneWeakCandidate() throws {
    // codex 的反例：bound = 1，同帶 [a:0, b:6, c:4, d:2]。
    // 舊實作讓 a 連續被 b、c、d 跳過而下移三格 → 對合法輸入拋
    // displacementBoundExceeded(bound: 1, attempted: 3)。
    let input = candidates(["a", "b", "c", "d"])
    let projection = multiStrengthProjection([
        (testAnchor("b"), 6), (testAnchor("c"), 4), (testAnchor("d"), 2),
    ])

    let output = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: projection)

    for result in output {
        #expect(abs(result.displacement) <= 1, "\(result.candidate.anchor.turnID) 位移 \(result.displacement) 越界")
    }
}

@Test func boundHoldsWhenTwoStrongerPeersJumpOneWeakCandidate() throws {
    // logic lens 的反例：bound = 1，同帶 [Y:1, X1:3, X2:2]。
    // 舊實作讓 Y 下移兩格 → displacementBoundExceeded(bound: 1, attempted: 2)。
    let input = candidates(["Y", "X1", "X2"])
    let projection = multiStrengthProjection([
        (testAnchor("X1"), 3), (testAnchor("X2"), 2), (testAnchor("Y"), 1),
    ])

    let output = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: projection)
    #expect(output.allSatisfy { abs($0.displacement) <= 1 })
}

@Test(arguments: [1, 2, 3])
func boundHoldsForEveryCandidateAcrossManyStrengthPatterns(bound: Int) throws {
    // 窮舉式的性質測試：8 個同帶候選、強度由固定的偽隨機序列指派，
    // 對每一種輪轉都斷言「每一筆的位移都在界內」。單一反例只證明單一情形，
    // 這裡要的是不變式。
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
                abs(result.displacement) <= bound,
                "rotation \(rotation) bound \(bound)：\(result.candidate.anchor.turnID) 位移 \(result.displacement)")
        }
    }
}

@Test func promotionIsGivenUpRatherThanPushingAPeerOutOfBounds() throws {
    // 契約的方向性：上限衝突時，寧可少升一名，也不產出違反自身契約的排序。
    // c 想上移，但 a 已經因為 b 的提升而用掉下移預算 → c 停在原地。
    let input = candidates(["a", "b", "c", "d"])
    let projection = multiStrengthProjection([
        (testAnchor("b"), 6), (testAnchor("c"), 4), (testAnchor("d"), 2),
    ])

    let output = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: projection)
    let positions = output.map(\.candidate.anchor)

    #expect(positions.firstIndex(of: testAnchor("b")) == 0)  // 升了
    #expect(positions.firstIndex(of: testAnchor("c")) == 2)  // 放棄提升，留在原位
    #expect(positions.firstIndex(of: testAnchor("a")) == 1)  // 只下移一格
}
