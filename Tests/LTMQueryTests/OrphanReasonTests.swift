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
    #expect(result.reason == .orphanedHistoryIgnored)
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
    #expect(output.first { $0.candidate.anchor == orphaned }?.reason == .orphanedHistoryIgnored)
}

@Test func noHistoryAndOrphanedHistoryAreDistinguishable() throws {
    // 兩者在排序上都是「不計入」，但只有後者代表「這裡曾經有東西、而它壞了」。
    // 混為一談會讓語料漂移在使用端完全不可見。
    let input = candidates(["a", "b"])
    let p = Projection(statistics: [:], instant: instant, orphanedAnchors: [testAnchor("b")])
    let output = try HumanLikeStrategy().rerank(input, with: p)

    #expect(output.first { $0.candidate.anchor == testAnchor("a") }?.reason == .noAdjustment)
    #expect(output.first { $0.candidate.anchor == testAnchor("b") }?.reason == .orphanedHistoryIgnored)
}
