import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// #1 verify 2026-08-11（regression lens）：design.md 的 failure mode 寫 orphan
// 「never silently treated as a normal miss」，而 `.orphanedHistoryIgnored`
// 在全 diff 裡是永不產生的死 case——資訊在 projection 階段就被丟掉，策略
// 結構上不可能履行那個承諾。修法是讓 projection 把 orphan 帶出來。

@Test func orphanedHistoryIsReportedNotSilentlyTreatedAsANormalMiss() throws {
    let input = candidates(["a", "b", "c"])
    let orphanedOne = testAnchor("b")

    let p = Projection(statistics: [:], instant: instant, orphanedAnchors: [orphanedOne])
    let output = try HumanLikeStrategy(displacementBound: 3).rerank(input, with: p)

    let result = output.first { $0.candidate.anchor == orphanedOne }!
    #expect(result.reason.history == .orphaned)
    #expect(result.reason.movement == .unmoved)
    #expect(result.displacement == 0)
}

@Test func anOrphanedAnchorWithStatisticsCannotMoveTheRanking() throws {
    // #1 verify R4：`Projection` 的公開建構子先前允許同一個 anchor **同時**出現
    // 在 `statistics` 與 `orphanedAnchors`。策略排序只讀 `netStrength(for:)`
    // （不看 orphan），所以高強度的 orphan **會真的被提升**，等到組 reason 時才
    // 回報「歷史已忽略」——同一筆結果因 orphan 歷史而移動、又聲稱該歷史被忽略。
    //
    // 而 spec 的 scenario 描述的**正是**這個形狀（「GIVEN a projection in which
    // the most heavily reinforced anchor is orphaned」），但所有測試都用
    // `statistics: [:]` 建 Projection——所以那條 scenario 從來沒被覆蓋。
    let input = candidates(["a", "b", "c"])
    let orphaned = testAnchor("c")

    var stats: [Anchor: AnchorStatistics] = [:]
    stats[orphaned] = AnchorStatistics(
        reinforcement: 999, suppression: 0, impressions: 0,
        lastDeliberateInteraction: instant, deliberateCounts: [.cited: 99])
    let p = Projection(statistics: stats, instant: instant, orphanedAnchors: [orphaned])

    // 不變式做進型別：orphan 的統計在建構時就被移除，不靠每個讀取端記得跳過。
    #expect(p[orphaned] == nil)
    #expect(p.netStrength(for: orphaned) == 0)

    let output = try HumanLikeStrategy(displacementBound: 3).rerank(input, with: p)
    #expect(output.map(\.candidate.anchor) == input.map(\.anchor), "orphan 不得推動排序")
    #expect(output.first { $0.candidate.anchor == orphaned }?.reason.history == .orphaned)
}

@Test func noHistoryAndOrphanedHistoryAreDistinguishable() throws {
    // 兩者在排序上都是「不計入」，但只有後者代表「這裡曾經有東西、而它壞了」。
    // 混為一談會讓語料漂移在使用端完全不可見。
    let input = candidates(["a", "b"])
    let p = Projection(statistics: [:], instant: instant, orphanedAnchors: [testAnchor("b")])
    let output = try HumanLikeStrategy().rerank(input, with: p)

    #expect(output.first { $0.candidate.anchor == testAnchor("a") }?.reason.history == RankingReason.History.none)
    #expect(output.first { $0.candidate.anchor == testAnchor("b") }?.reason.history == .orphaned)
}


// MARK: - reason 的兩個軸互相獨立（#1 verify R5，同一缺陷的第三輪）

@Test func aCandidateWithItsOwnHistoryThatGetsPushedDownSaysSo() throws {
    // R5(a)：自己有正向歷史、卻被更強的鄰居壓下去的候選，先前收到 `.adjusted`
    // ——而那個 case 的 doc 逐字寫「**被使用歷史上推**」。它下移了。
    var stats: [Anchor: AnchorStatistics] = [:]
    stats[testAnchor("a")] = AnchorStatistics(
        reinforcement: 1, suppression: 0, impressions: 0,
        lastDeliberateInteraction: instant, deliberateCounts: [.cited: 1])
    stats[testAnchor("b")] = AnchorStatistics(
        reinforcement: 9, suppression: 0, impressions: 0,
        lastDeliberateInteraction: instant, deliberateCounts: [.cited: 9])
    let p = Projection(statistics: stats, instant: instant)

    let input = candidates(["a", "b"])
    let output = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: p)
    let a = output.first { $0.candidate.anchor == testAnchor("a") }!

    #expect(a.displacement == -1)
    #expect(a.reason.movement == .receded(positions: 1), "它下移了，reason 不得說它被上推")
    guard case .counted(_, let net) = a.reason.history else {
        Issue.record("a 確實有歷史，history 應為 counted")
        return
    }
    #expect(net > 0)
}

@Test func anOrphanThatActuallyMovedReportsBothItsHistoryAndItsMovement() throws {
    // R5(b)：orphan 分支先前在最上面無條件 return，於是一筆實際被鄰居擠動的
    // orphan 只回報「歷史不計入」——沒有方向，也沒說明它為何在新位置。
    // spec 的「a reason describing why it moved」對它不成立。
    var stats: [Anchor: AnchorStatistics] = [:]
    stats[testAnchor("b")] = AnchorStatistics(
        reinforcement: 5, suppression: 0, impressions: 0,
        lastDeliberateInteraction: instant, deliberateCounts: [.cited: 5])
    let p = Projection(statistics: stats, instant: instant, orphanedAnchors: [testAnchor("a")])

    let input = candidates(["a", "b"])
    let output = try HumanLikeStrategy(displacementBound: 1).rerank(input, with: p)
    let a = output.first { $0.candidate.anchor == testAnchor("a") }!

    #expect(a.displacement == -1)
    #expect(a.reason.history == .orphaned, "它的歷史確實被忽略了")
    #expect(a.reason.movement == .receded(positions: 1), "而它確實移動了——兩件事都要說")
}

@Test func offsettingReinforcementAndSuppressionIsNotTheSameAsNoHistoryButIsLabelledHonestly() throws {
    // R5(c)：reinforcement 2 與 suppression 2 相抵的候選被歸進「自己沒有歷史」。
    // 這裡不改行為（淨強度為零，排序上確實不動），改的是**標籤的意思**：
    // `History.none` 現在的 doc 明寫「歷史沒有讓它動」而不是「從沒被用過」。
    // 那個區分要真的表達，需要把 impressions 與抵銷情形帶進 reason，屬於 #16。
    var stats: [Anchor: AnchorStatistics] = [:]
    stats[testAnchor("a")] = AnchorStatistics(
        reinforcement: 2, suppression: 2, impressions: 0,
        lastDeliberateInteraction: instant, deliberateCounts: [.cited: 2, .dismissed: 2])
    let p = Projection(statistics: stats, instant: instant)

    let output = try HumanLikeStrategy().rerank(candidates(["a", "b"]), with: p)
    let a = output.first { $0.candidate.anchor == testAnchor("a") }!
    #expect(a.reason.history == RankingReason.History.none)
    #expect(a.reason.movement == .unmoved)
}

@Test func allThreeStrategiesDeriveReasonsFromTheSameFunction() throws {
    // 三檔各寫一份 switch 正是 R3／R4／R5 三輪變體長出來的地方：修好其中一份、
    // 另一份原封不動。這條釘住「同一輸入下 human-like 與 conservative 的 reason
    // 由同一個函式導出」——archival 刻意不參與（它不得讀 projection）。
    let tied = [
        Candidate(anchor: testAnchor("a"), baseScore: 0.5, band: RelevanceBand(rank: 0)),
        Candidate(anchor: testAnchor("b"), baseScore: 0.5, band: RelevanceBand(rank: 0)),
    ]
    var stats: [Anchor: AnchorStatistics] = [:]
    stats[testAnchor("b")] = AnchorStatistics(
        reinforcement: 5, suppression: 0, impressions: 0,
        lastDeliberateInteraction: instant, deliberateCounts: [.cited: 5])
    let p = Projection(statistics: stats, instant: instant)

    let human = try HumanLikeStrategy().rerank(tied, with: p)
    let conservative = try ConservativeStrategy().rerank(tied, with: p)
    #expect(human.map(\.reason) == conservative.map(\.reason))
}
