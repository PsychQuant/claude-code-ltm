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
    Anchor(source: ProjectFingerprint.of("fixture-a"), turn: turn(id, text), span: 0..<8)
}

private func corpus(_ turns: [Turn]) -> FixtureCorpus {
    var map: [String: Turn] = [:]
    for t in turns { map[t.id] = t }
    return FixtureCorpus(turns: [ProjectFingerprint.of("fixture-a"): map])
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

@Test func projectionReportsWhichAnchorsWereOrphaned() {
    // #1 verify R2（regression lens，A/B 實測）：R1 的 orphan 修法**沒有生產端
    // 回歸測試**——拿掉 `project()` 裡填 orphanedAnchors 的那幾行，87 個測試
    // 全部照過，因為 LTMQuery 那側的 orphan 測試都是手工建 Projection。
    //
    // 這條補上缺的那半：斷言**摺疊函式本身**會把 orphan 帶出來。
    let orphaned = anchor("t3", 訊息C)
    let live = anchor("t1", 訊息A)
    let c = corpus([turn("t1", 訊息A), turn("t3", "這段文字已經被改掉了，雜湊不會相符。")])

    let p = project(
        [event(.cited, orphaned, minutesAgo: 1), event(.opened, live, minutesAgo: 1)],
        at: instant, resolvedBy: c)

    #expect(p.orphanedAnchors == [orphaned])
    #expect(p.isOrphaned(orphaned))
    #expect(!p.isOrphaned(live))
}

@Test func futureDatedEventsAreIgnoredRatherThanGivenMaximumWeight() {
    // #1 verify R3：先前 `max(0, instant - event.timestamp)` 把未來時間戳夾成
    // age 0，也就是 decay = 1.0 的**最大權重、而且永遠維持**。竄改備份（或時鐘
    // 倒退）只要把 timestamp 寫到未來，就能把某筆結果永久釘在帶首。
    // 夾成最大值是最糟的一種夾法。
    let a = anchor("t1", 訊息A)
    let c = corpus([turn("t1", 訊息A)])

    let future = Event.interaction(
        .cited, anchor: a, at: instant.addingTimeInterval(86_400 * 365),
        generation: gen, policy: policy)
    let p = project([future], at: instant, resolvedBy: c)

    #expect(p.reinforcement(for: a) == 0)
    #expect(p[a] == nil)

    // 對照：同一筆事件放在過去就正常計入，證明差別確實來自時間方向。
    let past = project([event(.cited, a, minutesAgo: 1)], at: instant, resolvedBy: c)
    #expect(past.reinforcement(for: a) > 0)
}

@Test func anchorsWithNoEventsAreNotReportedAsOrphaned() {
    // 邊界：orphan 的語意是「有歷史但解不開」，不是「沒出現過」。
    let live = anchor("t1", 訊息A)
    let neverSeen = anchor("t2", 訊息B)
    let c = corpus([turn("t1", 訊息A), turn("t2", 訊息B)])

    let p = project([event(.opened, live, minutesAgo: 1)], at: instant, resolvedBy: c)
    #expect(p.orphanedAnchors.isEmpty)
    #expect(!p.isOrphaned(neverSeen))
}


// MARK: - 參數驗證（#1 verify R5）

@Test func aNegativeDecayExponentIsRejected() async {
    // 負指數讓「衰減」反向：越舊的事件權重越大。這不是邊角，是把整個
    // power-law 的方向倒過來，而先前完全不驗。
    await #expect(processExitsWith: .failure) {
        _ = ProjectionParameters(decayExponent: -1)
    }
}

@Test func aNonFiniteWeightIsRejected() async {
    await #expect(processExitsWith: .failure) {
        _ = ProjectionParameters(citedWeight: .nan)
    }
}

@Test func ordinaryParametersStillConstruct() {
    // 反向對照：exit test 只證明「會死」，不證明它死得有道理。
    let p = ProjectionParameters()
    #expect(p.decayExponent > 0)
    #expect(ProjectionParameters(decayExponent: 0.25).decayExponent == 0.25)
}

@Test func aZeroDecayExponentIsRejected() async {
    // R7：`pow(1 + ageDays, -0) == 1`，完全沒有衰減——而 spec 的 SHALL 是
    // 「同一事件於較晚時點必須嚴格較小」。先前這個值被明確斷言為合法，
    // 也就是一個合法的 `human-like` 設定可以移除它命名的核心機制。
    await #expect(processExitsWith: .failure) {
        _ = ProjectionParameters(decayExponent: 0)
    }
}


@Test func futureDatedEventsAreCountedNotSilentlyDropped() throws {
    // R5：裸 `continue` 讓一個整段歷史都在未來的 anchor 與一個從沒被碰過的
    // anchor 完全無法區分，而觸發情境（竄改備份、時鐘回捲）正是最不該看不見
    // 的那種。同一輪 `ComparisonScorer` 為了同樣的理由把它的 continue 拆開計數。
    let text = "合成語料內容夠長"
    let c = corpus([turn("t1", text)])
    let a = anchor("t1", text)
    let future = Event.interaction(
        .cited, anchor: a, at: instant.addingTimeInterval(3600),
        generation: GenerationID("g1"), policy: RankingPolicyID("archival"))

    let p = project([future], at: instant, resolvedBy: c)
    #expect(p.futureDatedEventsIgnored == 1)
    #expect(p[a] == nil, "它仍然不得計入強度")

    // 對照：時間戳合法時計數為 0，否則上面那條可能只是「永遠回 1」。
    let past = Event.interaction(
        .cited, anchor: a, at: instant.addingTimeInterval(-3600),
        generation: GenerationID("g1"), policy: RankingPolicyID("archival"))
    let ok = project([past], at: instant, resolvedBy: c)
    #expect(ok.futureDatedEventsIgnored == 0)
    #expect(ok[a] != nil)
}


@Test func theSameEventContributesLessAtALaterInstant() {
    // R6：spec 只寫了「哪些 kind 增強、哪些壓抑」，沒有任何 scenario 要求
    // **衰減**——一個線性計數、完全不讀 timestamp 的實作能通過全部既有 scenario，
    // 而 decay 正是這一檔命名的由來。
    let text = "合成語料內容夠長"
    let c = corpus([turn("t1", text)])
    let a = anchor("t1", text)
    let e = Event.interaction(
        .cited, anchor: a, at: instant.addingTimeInterval(-86_400),
        generation: gen, policy: policy)

    let now = project([e], at: instant, resolvedBy: c)
    let later = project([e], at: instant.addingTimeInterval(86_400 * 30), resolvedBy: c)

    #expect(now.reinforcement(for: a) > 0)
    #expect(later.reinforcement(for: a) < now.reinforcement(for: a), "同一筆事件必須隨時間衰減")
}

@Test func aChangedCorpusChangesTheProjection() {
    // spec 的純函式 scenario 先前只列了兩個輸入（事件、時點），而實作需要三個。
    // 這條把第三個輸入真的有影響釘住。
    let text = "合成語料內容夠長"
    let a = anchor("t1", text)
    let e = Event.interaction(.cited, anchor: a, at: instant.addingTimeInterval(-60),
                              generation: gen, policy: policy)

    let intact = project([e], at: instant, resolvedBy: corpus([turn("t1", text)]))
    let edited = project([e], at: instant, resolvedBy: corpus([turn("t1", "完全不同的內容")]))

    #expect(intact.reinforcement(for: a) > 0)
    #expect(edited.orphanedAnchors.contains(a))
    #expect(edited.reinforcement(for: a) == 0)
}
