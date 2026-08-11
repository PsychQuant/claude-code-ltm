import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

private let 訊息A = "第一段合成文字，用來當作被引用的那一則。"
private let 訊息B = "第二段合成文字，用來當作只被看見的那一則。"
private let 訊息C = "第三段合成文字，之後會被改掉以模擬 orphan。"

private let instant = Date(timeIntervalSince1970: 2_000_000)
private let gen = GenerationID("build-1")
private let policy = RankingPolicyID("human-like")

private func turn(_ id: String, _ text: String) -> Turn {
    Turn(id: id, role: "user", timestamp: Date(timeIntervalSince1970: 0), text: text)
}

private func anchor(_ id: String, _ text: String) -> Anchor {
    Anchor(source: "fixture-a", turn: turn(id, text), span: 0..<8)
}

private func corpus(_ turns: [Turn]) -> FixtureCorpus {
    var map: [String: Turn] = [:]
    for t in turns { map[t.id] = t }
    return FixtureCorpus(turns: ["fixture-a": map])
}

private func event(_ kind: NonPinKind, _ a: Anchor, minutesAgo: Double) -> Event {
    .interaction(
        kind, anchor: a, at: instant.addingTimeInterval(-minutesAgo * 60),
        generation: gen, policy: policy)
}

@Test func projectionIsAPureFunctionOfItsInputs() {
    let a = anchor("t1", 訊息A)
    let events = [
        event(.opened, a, minutesAgo: 30),
        event(.cited, a, minutesAgo: 10),
    ]
    let c = corpus([turn("t1", 訊息A)])

    let first = project(events, at: instant, resolvedBy: c)
    let second = project(events, at: instant, resolvedBy: c)
    #expect(first == second)
}

@Test func projectingDoesNotWriteBackToTheStore() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-proj-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try FileEventStore(url: dir.appendingPathComponent("events.jsonl"))

    let a = anchor("t1", 訊息A)
    try store.append(event(.opened, a, minutesAgo: 5))
    try store.append(event(.cited, a, minutesAgo: 1))

    let before = try store.allEvents().count
    _ = project(try store.allEvents(), at: instant, resolvedBy: corpus([turn("t1", 訊息A)]))
    #expect(try store.allEvents().count == before)
}

@Test func impressionsAloneProduceNoReinforcement() {
    let seenOnly = anchor("t2", 訊息B)
    let neverSeen = anchor("t1", 訊息A)

    let events = (0..<20).map { event(.shown, seenOnly, minutesAgo: Double($0)) }
    let p = project(events, at: instant, resolvedBy: corpus([turn("t2", 訊息B), turn("t1", 訊息A)]))

    // 「被看見二十次」與「從未出現」在增強量上必須完全相同。否則就形成
    // 「出現過就更容易再出現」的迴圈，與是否有用無關。
    #expect(p.reinforcement(for: seenOnly) == p.reinforcement(for: neverSeen))
    #expect(p.reinforcement(for: seenOnly) == 0)
    #expect(p.netStrength(for: seenOnly) == p.netStrength(for: neverSeen))

    // impressions 仍然被記錄——它是比較報告的分母，不是排序訊號。
    #expect(p[seenOnly]?.impressions == 20)
}

@Test func deliberateInteractionsReinforceAndDismissalSuppresses() {
    let a = anchor("t1", 訊息A)
    let c = corpus([turn("t1", 訊息A)])

    let opened = project([event(.opened, a, minutesAgo: 1)], at: instant, resolvedBy: c)
    let cited = project([event(.cited, a, minutesAgo: 1)], at: instant, resolvedBy: c)
    let dismissed = project([event(.dismissed, a, minutesAgo: 1)], at: instant, resolvedBy: c)

    #expect(opened.reinforcement(for: a) > 0)
    #expect(cited.reinforcement(for: a) > opened.reinforcement(for: a))
    #expect(dismissed.reinforcement(for: a) == 0)
    #expect(dismissed.netStrength(for: a) < 0)
}

@Test func pinnedReinforcesMoreStronglyThanCited() {
    let a = anchor("t1", 訊息A)
    let c = corpus([turn("t1", 訊息A)])
    let pinned = project(
        [.pin(anchor: a, at: instant.addingTimeInterval(-60), generation: gen, policy: policy)],
        at: instant, resolvedBy: c)
    let cited = project([event(.cited, a, minutesAgo: 1)], at: instant, resolvedBy: c)

    #expect(pinned.reinforcement(for: a) > cited.reinforcement(for: a))
}

@Test func olderInteractionsCountLessThanRecentOnes() {
    let a = anchor("t1", 訊息A)
    let c = corpus([turn("t1", 訊息A)])
    let recent = project([event(.cited, a, minutesAgo: 1)], at: instant, resolvedBy: c)
    let old = project([event(.cited, a, minutesAgo: 60 * 24 * 90)], at: instant, resolvedBy: c)

    #expect(recent.reinforcement(for: a) > old.reinforcement(for: a))
    #expect(old.reinforcement(for: a) > 0)  // 衰減，不是歸零
}

@Test func orphanedAnchorsAreInertAndDoNotRaise() {
    let orphaned = anchor("t3", 訊息C)
    let live = anchor("t1", 訊息A)

    // 語料裡 t3 的文字被改過 → 雜湊不符 → orphan。
    let c = corpus([turn("t1", 訊息A), turn("t3", "這段文字已經被改掉了，雜湊不會相符。")])

    let events =
        (0..<10).map { event(.cited, orphaned, minutesAgo: Double($0)) }
        + [event(.opened, live, minutesAgo: 1)]

    let p = project(events, at: instant, resolvedBy: c)

    #expect(p[orphaned] == nil)
    #expect(p.reinforcement(for: orphaned) == 0)
    #expect(p.reinforcement(for: live) > 0)
}
