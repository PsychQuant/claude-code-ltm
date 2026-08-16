import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// 這一檔記錄一段來回。**結論是對稱上限**——中間那個「改成單向」的裁決後來被
// 反例推翻，整段留著是因為推翻它的方式值得記住。
//
// - **R1**（2026-08-11）：verify 抓到 `HumanLikeStrategy` 對一般輸入拋
//   `displacementBoundExceeded`——契約是**對稱**上限，演算法卻只約束提升。
// - **R1 的修法**：swap 前檢查被越過方的累計下移，超限就放棄提升。
// - **R2**（2026-08-14）：量化到「32 個候選、31 個有歷史，bound 1 時實際上移
//   總數是 1」，我讀成「對稱上限讓一條帶的提升總數 ≤ bound」。
// - **裁決**（#17，2026-08-15）：據此改契約——上限只約束提升。
// - **R3 推翻**：那句算術是錯的。bound=1、`[A,B,C,D] → [B,A,D,C]`，兩次提升、
//   每筆位移都 ≤1。R2 量到的是 R1 那個「放棄提升」演算法的性質，不是對稱契約
//   的性質。**被量測推翻的是實作，我卻改了契約。** 契約改回對稱，演算法換成
//   `boundedReorderByStrength`（每輪每個元素最多參與一次交換，跑 bound 輪，
//   雙向上限由構造保證）。R2 那個輸入的正解確實是 1 次提升，見
//   `onePromotionIsTheOptimumWhenOnlyTheHeadIsMisplaced`。
//
// 所以本檔的斷言一律是 `abs(displacement) <= bound`。**沒有「下移可以超過上限」
// 這回事**——先前這裡的檔頭這樣寫，而 30 行之下的 `demotionIsBoundedToo` 正好
// 斷言相反（#1 verify R4）。
//
// 誠實邊界：`rerank` 內部已經過 `RankingGuard.check`，所以本檔的上限斷言不會
// 在守衛還在的情況下失敗。它們擋的是「有人把守衛呼叫拿掉」，不是獨立的第二
// 道驗算。真正對守衛本身下手的測試在 `RankingGuardTests`。

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
            abs(result.displacement) <= 1,
            "\(result.candidate.anchor.turnID) 位移 \(result.displacement) 名，超過上限")
    }
}

@Test func demotionActuallyHappensAndIsBounded() throws {
    // **這條先前與上一條逐字相同**——同一組候選、同一個 projection、同一個
    // bound、同一句斷言，只有函式名與註解不同（#1 verify R5）。它的名字承諾
    // 「下移也受限」，但沒有斷言任何一筆**確實下移**：演算法退化成完全不動
    // 它照樣綠。測試數字再一次不是證據。
    //
    // 改成斷言具體的下移量。對稱上限真正的釘子在
    // `RankingGuardTests.anOverBoundDemotionIsRejectedJustLikeAnOverBoundPromotion`
    // ——那一條直接對守衛下手，這一條只確認經由策略確實會發生下移。
    let input = candidates(["a", "b", "c", "d"])
    let projection = multiStrengthProjection([
        (testAnchor("b"), 6), (testAnchor("c"), 4), (testAnchor("d"), 2),
    ])

    let output = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: projection)
    let a = output.first { $0.candidate.anchor == testAnchor("a") }!
    #expect(a.displacement == -1, "a 沒有歷史、被 b 超車，必須確實下移一名")
    #expect(a.reason.movement == .receded(positions: 1))
    #expect(output.contains { $0.displacement > 0 }, "必須真的有人上移")
    #expect(output.allSatisfy { abs($0.displacement) <= 1 })
}

@Test func aDemotedCandidateSaysWhyItMoved() throws {
    // 位移非零就必須說明原因。先前沒有歷史的候選被超車時回報 `.noAdjustment`，
    // 於是同時聲稱「移動了」與「沒有調整」（#1 verify R3）。
    let input = candidates(["a", "b"])
    let output = try HumanLikeStrategy(displacementBound: 1)
        .rerank(input, with: multiStrengthProjection([(testAnchor("b"), 5)]))

    let a = output.first { $0.candidate.anchor == testAnchor("a") }!
    #expect(a.displacement == -1)
    // 兩個軸分開讀：a 自己沒有計入的歷史，而它下移了一名。
    #expect(a.reason.history == RankingReason.History.none)
    #expect(a.reason.movement == .receded(positions: 1))
}

@Test func aCandidatePromotedBecauseAPeerSankAlsoSaysWhyItMoved() throws {
    // #1 verify R4：`displacedByPeers` 原本寫 `positions: -displacement`，
    // **假設沒有歷史的候選只會往下移**。錯了——`dismissed` 讓鄰居的 netStrength
    // 變負，於是沒有歷史的候選會相對**上移**，而 reason 回報負數。
    //
    // 修法在它所修的那個缺陷的**鏡像**上重演了同一件事：reason 描述的與實際
    // 發生的相反。這條測的就是那個鏡像。
    let input = candidates(["a", "b"])
    var stats: [Anchor: AnchorStatistics] = [:]
    stats[testAnchor("a")] = AnchorStatistics(
        reinforcement: 0, suppression: 5, impressions: 0,
        lastDeliberateInteraction: instant, deliberateCounts: [.dismissed: 5])
    let p = Projection(statistics: stats, instant: instant)

    let output = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: p)
    let b = output.first { $0.candidate.anchor == testAnchor("b") }!

    #expect(b.displacement == 1, "b 沒有歷史，但 a 被壓低所以 b 相對上移")
    #expect(b.reason.history == RankingReason.History.none)
    #expect(b.reason.movement == .advanced(positions: 1))
}

@Test func onePromotionIsTheOptimumWhenOnlyTheHeadIsMisplaced() throws {
    // **R2 警訊的誠實反駁，留成測試。**
    //
    // R2 量到「帶大小 32、31 個有歷史，bound 1 → 只有 1 次提升」，並據此判定
    // human-like 幾乎被關掉。我當時接受了那個詮釋並改掉契約——那是錯的。
    //
    // 該輸入的第 0 名沒有歷史、其餘**本來就已按強度遞減排好**。也就是說
    // 目標順序與輸入只差「把第 0 名移到最後」，其餘 31 筆的相對順序完全正確、
    // 不需要移動。在對稱 bound 1 之下，第 0 名最多下沉一格，所以最多一人能
    // 超過它——**1 次提升是最佳解，不是飢餓**。
    //
    // 量測為真、詮釋有誤。這條測試把「為什麼 1 是對的」釘住。
    let ids = (0..<32).map { "c\($0)" }
    let input = candidates(ids)
    let entries = ids.dropFirst().enumerated().map { (testAnchor($1), Double(32 - $0)) }

    let output = try HumanLikeStrategy(displacementBound: 1)
        .rerank(input, with: multiStrengthProjection(entries))

    #expect(output.filter { $0.displacement > 0 }.count == 1)
    // 而且那一次提升確實發生了——不是完全沒動。
    #expect(output.first?.candidate.anchor == testAnchor("c1"))
}

@Test func promotionsHappenWhereverTheyAreNeededNotOnlyAtTheHead() throws {
    // 真正該擔心的「楔住」是：帶首的擋路者用完預算之後，**帶內其他地方**
    // 需要的提升也一併停擺。這條輸入在兩個不相鄰的位置各需要一次提升。
    let input = candidates(["a", "b", "c", "d"])
    let projection = multiStrengthProjection([(testAnchor("b"), 6), (testAnchor("d"), 5)])

    let output = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: projection)

    #expect(output.filter { $0.displacement > 0 }.count == 2)
    #expect(output.map(\.candidate.anchor) == [testAnchor("b"), testAnchor("a"), testAnchor("d"), testAnchor("c")])
    #expect(output.allSatisfy { abs($0.displacement) <= 1 })
}

@Test func nonFiniteBaseScoreIsRejectedAtTheSeamEntry() {
    // NaN 讓 `x == x` 為 false，而等分區段切分與守衛的排列比對都建立在等值
    // 比較上。#1 verify R3 實測 `ConservativeStrategy` 因此無限迴圈。
    let bad = [Candidate(anchor: testAnchor("nan"), baseScore: .nan, band: RelevanceBand(rank: 0))]

    #expect(throws: StrategyViolation.nonFiniteBaseScore(testAnchor("nan"))) {
        _ = try HumanLikeStrategy().rerank(bad, with: .empty(at: instant))
    }
    #expect(throws: StrategyViolation.nonFiniteBaseScore(testAnchor("nan"))) {
        _ = try ConservativeStrategy().rerank(bad, with: .empty(at: instant))
    }
    #expect(throws: StrategyViolation.nonFiniteBaseScore(testAnchor("nan"))) {
        _ = try ArchivalStrategy().rerank(bad, with: .empty(at: instant))
    }
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
                abs(result.displacement) <= bound,
                "rotation \(rotation) bound \(bound)：\(result.candidate.anchor.turnID) 位移 \(result.displacement)")
        }
        // 這裡**刻意不斷言排列性質**：`rerank` 內部已呼叫 `RankingGuard.check`，
        // 非排列會在到達斷言之前就拋出，所以那個 `#expect` 不可能失敗。
        // 先前這裡有一條，是三輪裡第三個同義反覆測試（#1 verify R3）。
        // 排列性質由 `RankingGuardTests` 直接對守衛下手來驗，那裡才驗得到。
    }
}

@Test func aLargerBoundActuallyProducesALargerPromotionThroughARealStrategy() throws {
    // 先前這個位置是一條直接對 `RankingGuard.check` 下手的測試，而它與
    // `StrategyTests.exceedingTheDisplacementBoundIsReportedNotClamped` **逐字重複**
    // （同 bound 1、同 attempted 4、同期望）——而且它取代掉的是本檔唯一一條
    // 透過真實策略驗證上限行為的測試（#1 verify R3）。
    //
    // 換成真的只有透過策略才驗得到的東西：上限是**有效的預算**，不是裝飾。
    // 新的 pass-based 演算法跑 `bound` 輪，所以 bound 越大、實際提升越多。
    let input = candidates(["a", "b", "c", "d", "e", "f"])
    let projection = multiStrengthProjection([(testAnchor("f"), 9)])

    let bound1 = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: projection)
    let bound3 = try HumanLikeStrategy(displacementBound: 3).rerank(input, with: projection)

    let at1 = bound1.firstIndex { $0.candidate.anchor == testAnchor("f") }!
    let at3 = bound3.firstIndex { $0.candidate.anchor == testAnchor("f") }!
    #expect(at1 == 4)  // 原本第 5，升一名
    #expect(at3 == 2)  // 升三名
    #expect(at3 < at1, "更大的上限必須換到更大的提升，否則上限不是有效預算")
}
