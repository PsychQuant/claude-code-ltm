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

@Test func noHistoryAndOrphanedHistoryAreDistinguishable() throws {
    // 兩者在排序上都是「不計入」，但只有後者代表「這裡曾經有東西、而它壞了」。
    // 混為一談會讓語料漂移在使用端完全不可見。
    let input = candidates(["a", "b"])
    let p = Projection(statistics: [:], instant: instant, orphanedAnchors: [testAnchor("b")])
    let output = try HumanLikeStrategy().rerank(input, with: p)

    #expect(output.first { $0.candidate.anchor == testAnchor("a") }?.reason == .noAdjustment)
    #expect(output.first { $0.candidate.anchor == testAnchor("b") }?.reason == .orphanedHistoryIgnored)
}
