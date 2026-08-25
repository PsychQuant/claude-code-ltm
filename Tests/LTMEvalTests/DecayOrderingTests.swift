import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory
@testable import LTMQuery

// #22 item 16：`memory-strategy` 的衰減需求有兩個 scenario，而第二個
// 「A recent citation outranks an older one」**沒有測試**。
//
// 為什麼它落在 `LTMEvalTests` 而不是 `LTMQueryTests`：衰減的實作**不在
// `human-like` 裡**，在共用的 `project(_:at:resolvedBy:)`。`LTMQueryTests` 的
// `projection(_:)` helper 直接造 `AnchorStatistics`，所以它繞過了衰減——用它寫
// 這條測試會得到一條**驗不到衰減**的測試。而 `LTMQueryTests` 看不到 `LTMMemory`。
//
// 這正是 issue 那句「實作不在 human-like」的實際後果：要測這個 scenario，就得
// 走真正算衰減的那條路徑。

/// 合成語料。測試一律不讀真實的 `~/.claude/projects/`。
private struct DecayFixtureCorpus: CorpusReader {
    var turns: [String: [String: Turn]] = [:]
    func turn(id: String, inSource source: String) -> Turn? { turns[source]?[id] }
}

private let decayText = "節點甲與節點乙各自被引用過一次，時間相隔很遠。這句讓 span 有東西可切。"

@Test("較近的引用排在較舊的之前——衰減在共用 projection，不在策略裡")
func aRecentCitationOutranksAnOlderOne() throws {
    let turn = Turn(
        id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 0), text: decayText)
    let corpus = DecayFixtureCorpus(turns: ["fixture-a": [turn.id: turn]])

    let recentAnchor = Anchor(source: "fixture-a", turn: turn, span: 0..<3)
    let oldAnchor = Anchor(source: "fixture-a", turn: turn, span: 5..<8)

    let now = Date(timeIntervalSince1970: 100 * 86_400)
    let events = [
        // 同樣是一次 cited，差別只有時間。
        Event.interaction(
            .cited, anchor: recentAnchor, at: now.addingTimeInterval(-86_400),
            generation: GenerationID("g1"), policy: RankingPolicyID("human-like"),
            presentation: nil),
        Event.interaction(
            .cited, anchor: oldAnchor, at: Date(timeIntervalSince1970: 0),
            generation: GenerationID("g1"), policy: RankingPolicyID("human-like"),
            presentation: nil),
    ]
    let projection = project(events, at: now, resolvedBy: corpus)

    // 前提：兩者的淨強度確實因為時間而不同。不先驗這個，下面的順序斷言可能
    // 因為別的原因成立。
    let recentStrength = try #require(projection[recentAnchor]).netStrength
    let oldStrength = try #require(projection[oldAnchor]).netStrength
    #expect(recentStrength > oldStrength, "前提：衰減讓較舊的那次引用更弱")

    // 兩個候選同帶、base score 相同——順序的唯一來源是使用歷史。
    let input = [
        Candidate(anchor: oldAnchor, baseScore: 1, band: RelevanceBand(rank: 0)),
        Candidate(anchor: recentAnchor, baseScore: 1, band: RelevanceBand(rank: 0)),
    ]
    let output = try HumanLikeStrategy(displacementBound: 3).rerank(input, with: projection)
    let order = output.map(\.candidate.anchor)

    let recentIndex = try #require(order.firstIndex(of: recentAnchor))
    let oldIndex = try #require(order.firstIndex(of: oldAnchor))
    #expect(recentIndex < oldIndex, "較近的引用必須排在較舊的之前")
}
