import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// #17 裁決（2026-08-15）：`conservative` 以 tie-breaker-only 復活。
// 初版把它移除的論證只對了一半——±5% 封頂確實無法表達，但「僅作 tie-breaker」
// 完全可以。部分為真的論證被用來支撐全稱結論。

/// 造一組候選，讓指定的幾個位置 base score 完全相等（模擬 RRF 平手）。
private func tiedCandidates(_ ids: [String], tiedScore: Double = 0.5) -> [Candidate] {
    ids.map { Candidate(anchor: testAnchor($0), baseScore: tiedScore, band: RelevanceBand(rank: 0)) }
}

private func strengths(_ entries: [(String, Double)]) -> Projection {
    var stats: [Anchor: AnchorStatistics] = [:]
    for (id, strength) in entries {
        stats[testAnchor(id)] = AnchorStatistics(
            reinforcement: strength, suppression: 0, impressions: 0,
            lastDeliberateInteraction: instant, deliberateCounts: [.cited: Int(strength)])
    }
    return Projection(statistics: stats, instant: instant)
}

@Test func conservativeBreaksTiesByStrength() throws {
    let input = tiedCandidates(["a", "b", "c"])  // base score 全部相同
    // 有界重排**不會**完全排序：每個元素每輪最多移一格，所以 n 筆要完全倒序
    // 需要約 n 輪。這不是缺陷，是上限的定義。
    let output = try ConservativeStrategy(displacementBound: 3)
        .rerank(input, with: strengths([("c", 5), ("b", 2)]))

    #expect(output.map(\.candidate.anchor) == [testAnchor("c"), testAnchor("b"), testAnchor("a")])

    // 預設上限下仍然有 tie-breaking，只是幅度受限——強者往前一格。
    let bounded = try ConservativeStrategy().rerank(input, with: strengths([("c", 5), ("b", 2)]))
    #expect(bounded.allSatisfy { abs($0.displacement) <= 1 })
    #expect(bounded.map(\.candidate.anchor) != input.map(\.anchor), "預設上限下仍應有動作")
}

@Test func conservativeNeverReordersCandidatesWithDifferentBaseScores() throws {
    // 這是它與 human-like 的分界：檢索有意見的地方，記憶不插手。
    let input = candidates(["a", "b", "c"])  // baseScore 遞減、互不相等
    let output = try ConservativeStrategy()
        .rerank(input, with: strengths([("c", 100), ("b", 50)]))

    #expect(output.map(\.candidate.anchor) == input.map(\.anchor))
    #expect(output.allSatisfy { $0.displacement == 0 })
}

@Test func conservativeAndHumanLikeDivergeExactlyOnNonTiedInput() throws {
    // 同一份輸入，兩檔策略給出不同結果——這證明它們是不同的策略，
    // 而不是同一個策略配不同參數。
    let input = candidates(["a", "b", "c"])
    let projection = strengths([("c", 5)])

    let conservative = try ConservativeStrategy().rerank(input, with: projection)
    let humanLike = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: projection)

    #expect(conservative.map(\.candidate.anchor) != humanLike.map(\.candidate.anchor))
    #expect(conservative.allSatisfy { $0.displacement == 0 })
    #expect(humanLike.contains { $0.displacement > 0 })
}

@Test func noBoundMakesHumanLikeBehaveLikeConservativeOnNonTiedInput() throws {
    // **這才是「機制不是幅度」的證明。**
    //
    // #1 verify R4（devils-advocate 實測）：我先前的論證架在 bound=0 這一個值上
    // ——「把 human-like 調到 0 得不到 tie-breaking」。那個點的性質由
    // `guard bound > 0 ... else { return }` 這句 early return 直接保證，
    // 證不了整個值域。DA 掃過 bound 0…6 後指出：**在全平手輸入上，bound 夠大時
    // human-like 與 conservative 逐字相同**。所以在 conservative 唯一會作用的
    // 那類輸入上，兩者的差別確實只是幅度。
    //
    // 可辯護的證據一直在旁邊：**base score 相異時，沒有任何 bound 能讓
    // human-like 變成 conservative**——因為 conservative 在那裡完全不動，而
    // human-like 只要 bound > 0 就會動。這是條件差異，不是幅度差異。
    let nonTied = candidates(["a", "b", "c"])  // base score 互異
    let projection = strengths([("c", 5)])

    let conservative = try ConservativeStrategy().rerank(nonTied, with: projection)
    #expect(conservative.allSatisfy { $0.displacement == 0 })

    for bound in 0...6 {
        let humanLike = try HumanLikeStrategy(displacementBound: bound).rerank(nonTied, with: projection)
        let same = humanLike.map(\.candidate.anchor) == conservative.map(\.candidate.anchor)
        // bound=0 時 human-like 也完全不動，那是 early return 而不是機制；
        // 只要 bound > 0，兩者必然分歧。
        #expect(same == (bound == 0), "bound \(bound)：非平手輸入上兩檔應分歧")
    }
}

@Test func onAllTiedInputASufficientBoundDoesReproduceConservative() throws {
    // 誠實記錄 DA 量到的事：在全平手輸入上，bound 夠大時 human-like 與
    // conservative **逐字相同**。這條寫成斷言而不是註解，是為了讓下一個人
    // 不會拿「機制不是幅度」去推導它推不出來的東西。
    let tied = tiedCandidates(["a", "b", "c"])
    let projection = strengths([("c", 5), ("b", 2)])

    let humanLike = try HumanLikeStrategy(displacementBound: 3).rerank(tied, with: projection)
    let conservative = try ConservativeStrategy(displacementBound: 3).rerank(tied, with: projection)
    #expect(humanLike.map(\.candidate.anchor) == conservative.map(\.candidate.anchor))
}

@Test func conservativeStaysWithinItsRelevanceBand() throws {
    // 平手判準含 band：跨帶就算 base score 碰巧相同也不合併成一個平手區段。
    var input = tiedCandidates(["a", "b"], tiedScore: 0.5)
    input += [Candidate(anchor: testAnchor("z"), baseScore: 0.5, band: RelevanceBand(rank: 1))]

    let output = try ConservativeStrategy()
        .rerank(input, with: strengths([("z", 100)]))

    #expect(output.map(\.candidate.band.rank) == [0, 0, 1])
}

@Test func conservativeReportsOrphanedHistoryLikeHumanLike() throws {
    let input = tiedCandidates(["a", "b"])
    let p = Projection(statistics: [:], instant: instant, orphanedAnchors: [testAnchor("b")])
    let output = try ConservativeStrategy().rerank(input, with: p)

    #expect(output.first { $0.candidate.anchor == testAnchor("b") }?.reason == .orphanedHistoryIgnored)
}

@Test func conservativeCannotMoveACandidateOutOfItsTieRun() throws {
    // #1 verify R3 的 CRITICAL：先前 conservative 把 `widestTiedRun` 算出來當成
    // **自己的**位移上限傳給守衛，於是守衛對它恆真——8 個平手候選整個反轉、
    // 提升 7 名而不拋錯。那正是 design.md 說要防的「不合規策略偽裝成合規」。
    //
    // 現在改用 `checkTieRunsOnly`：不設位移上限，改為要求每一筆只能在自己
    // 原本的等分區段內移動——這比位移上限**更嚴格**，不是它的豁免。
    var input = tiedCandidates(["a", "b"], tiedScore: 0.9)  // 區段 1
    input += tiedCandidates(["c", "d"], tiedScore: 0.5)  // 區段 2

    // 惡意重排：把區段 2 的 c 移到區段 1 裡面。每一筆的位移都很小，
    // 舊的「自己授權的上限」會放行。
    let crossing = [input[0], input[2], input[1], input[3]]

    #expect(throws: StrategyViolation.movedAcrossTieRuns) {
        _ = try RankingGuard.checkTieRunsOnly(original: input, reordered: crossing, bound: 9)
    }
}

@Test func conservativeFullySortsALongTieRunAndTheGuardAcceptsIt() throws {
    // 區段內完全排序是**刻意允許**的：base score 完全相等時檢索對先後沒有表達
    // 任何偏好，所以區段內任意順序都不牴觸相關性判斷。這條把「允許」釘成
    // 明示的斷言，而不是讓它看起來像上一條的漏洞。
    let input = tiedCandidates(["a", "b", "c", "d", "e", "f", "g", "h"])
    let ascending = (0..<8).map { (["a", "b", "c", "d", "e", "f", "g", "h"][$0], Double($0)) }

    // R4：先前這條斷言 `displacement == 7`，也就是**整段反轉**——那正是 R3 判
    // CRITICAL 的行為，只是換成由 `max(count,1)` 這個不會觸發的門檻放行。
    // conservative 現在與 human-like 受同一個上限約束，所以整段反轉需要
    // bound 夠大才做得到，而預設 bound 下只會做相鄰的 tie-breaking。
    let wide = try ConservativeStrategy(displacementBound: 8)
        .rerank(input, with: strengths(ascending))
    #expect(wide.allSatisfy { abs($0.displacement) <= 8 })
    #expect(wide.first?.candidate.anchor == testAnchor("h"), "最強者應排到區段首")

    let defaultBound = try ConservativeStrategy().rerank(input, with: strengths(ascending))
    #expect(defaultBound.allSatisfy { abs($0.displacement) <= 1 }, "預設上限也必須被遵守")
    #expect(defaultBound.map(\.candidate.anchor) != input.map(\.anchor).reversed())
}

@Test func conservativeDoesNotHangOnNonFiniteBaseScores() throws {
    // #1 verify R3 的第二個 CRITICAL：`x.baseScore == x.baseScore` 對 NaN 為 false，
    // 於是區段掃描的游標不前進、rerank **無限迴圈**（不拋錯，直接掛住燒 CPU）
    // ——與 R1 修掉的交錯迴圈是同一個 failure class。
    //
    // 這條測試若回歸，會是**掛住**而不是失敗，所以它同時是一個 canary：
    // 測試套件跑不完本身就是訊號。
    let bad = [
        Candidate(anchor: testAnchor("x"), baseScore: .nan, band: RelevanceBand(rank: 0)),
        Candidate(anchor: testAnchor("y"), baseScore: .nan, band: RelevanceBand(rank: 0)),
    ]

    #expect(throws: StrategyViolation.nonFiniteBaseScore(testAnchor("x"))) {
        _ = try ConservativeStrategy().rerank(bad, with: .empty(at: instant))
    }
}

@Test func negativeZeroAndPositiveZeroCountAsTied() throws {
    // -0.0 == 0.0 在 IEEE 754 為真，所以它們屬於同一個等分區段。這是對的
    // 行為，但值得釘住——它是「精確相等」這個判準的邊界之一。
    let input = [
        Candidate(anchor: testAnchor("a"), baseScore: -0.0, band: RelevanceBand(rank: 0)),
        Candidate(anchor: testAnchor("b"), baseScore: 0.0, band: RelevanceBand(rank: 0)),
    ]
    let output = try ConservativeStrategy().rerank(input, with: strengths([("b", 5)]))
    #expect(output.map(\.candidate.anchor) == [testAnchor("b"), testAnchor("a")])
}

@Test func offTiesConservativeIsByteForByteArchival() throws {
    // spec 說「off ties 兩者可證相同」，而先前被拿來當證據的那條測試**從頭到尾
    // 沒有呼叫 archival**（#1 verify R4，devils-advocate）。這條真的把兩邊都跑
    // 一次再比——包含 reason 與 displacement，不只順序。
    //
    // 這件事也是 conservative 這一檔有沒有用的全部關鍵：它的價值完全等於
    // 「精確平手多常發生」，而那個比率在本語料上**還沒量過**（#18）。
    let nonTied = candidates(["a", "b", "c", "d"])
    let projection = strengths([("d", 100), ("c", 50), ("b", 10)])

    let conservative = try ConservativeStrategy(displacementBound: 3)
        .rerank(nonTied, with: projection)
    let archival = try ArchivalStrategy().rerank(nonTied, with: projection)

    #expect(conservative == archival)
}

@Test func onTiesConservativeIsNotArchival() throws {
    // 上一條的對照：平手時兩者必須分歧，否則這一檔連存在的理由都沒有。
    let tied = tiedCandidates(["a", "b", "c"])
    let projection = strengths([("c", 5)])

    let conservative = try ConservativeStrategy().rerank(tied, with: projection)
    let archival = try ArchivalStrategy().rerank(tied, with: projection)

    #expect(conservative != archival)
}

@Test func threeStrategiesNowCoexistAndAreDistinguishable() throws {
    // issue #1 的 Expected 要三檔並存。這條把「並存」釘成一個可執行的事實。
    let all: [any MemoryStrategy] = [ArchivalStrategy(), ConservativeStrategy(), HumanLikeStrategy()]
    #expect(Set(all.map(\.id)) .count == 3)
    #expect(ArchivalStrategy().consumedSignals.isEmpty)
    #expect(!ConservativeStrategy().consumedSignals.isEmpty)
    #expect(ConservativeStrategy().consumedSignals == HumanLikeStrategy().consumedSignals)
}
