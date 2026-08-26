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
    Anchor(source: ProjectFingerprint.of("fixture-a"), turn: turn(id, text), span: 0..<8, key: .forTesting)
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

    let first = project(events, at: instant, resolvedBy: c, key: .forTesting)
    let second = project(events, at: instant, resolvedBy: c, key: .forTesting)
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
    _ = project(try store.allEvents(), at: instant, resolvedBy: corpus([turn("t1", 訊息A)]), key: .forTesting)
    #expect(try store.allEvents().count == before)
}

@Test func impressionsAloneProduceNoReinforcement() {
    let seenOnly = anchor("t2", 訊息B)
    let neverSeen = anchor("t1", 訊息A)

    let events = (0..<20).map { event(.shown, seenOnly, minutesAgo: Double($0)) }
    let p = project(events, at: instant, resolvedBy: corpus([turn("t2", 訊息B), turn("t1", 訊息A)]), key: .forTesting)

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

    let opened = project([event(.opened, a, minutesAgo: 1)], at: instant, resolvedBy: c, key: .forTesting)
    let cited = project([event(.cited, a, minutesAgo: 1)], at: instant, resolvedBy: c, key: .forTesting)
    let dismissed = project([event(.dismissed, a, minutesAgo: 1)], at: instant, resolvedBy: c, key: .forTesting)

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
        at: instant, resolvedBy: c, key: .forTesting)
    let cited = project([event(.cited, a, minutesAgo: 1)], at: instant, resolvedBy: c, key: .forTesting)

    #expect(pinned.reinforcement(for: a) > cited.reinforcement(for: a))
}

@Test func olderInteractionsCountLessThanRecentOnes() {
    let a = anchor("t1", 訊息A)
    let c = corpus([turn("t1", 訊息A)])
    let recent = project([event(.cited, a, minutesAgo: 1)], at: instant, resolvedBy: c, key: .forTesting)
    let old = project([event(.cited, a, minutesAgo: 60 * 24 * 90)], at: instant, resolvedBy: c, key: .forTesting)

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

    let p = project(events, at: instant, resolvedBy: c, key: .forTesting)

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
        at: instant, resolvedBy: c, key: .forTesting)

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
    let p = project([future], at: instant, resolvedBy: c, key: .forTesting)

    #expect(p.reinforcement(for: a) == 0)
    #expect(p[a] == nil)

    // 對照：同一筆事件放在過去就正常計入，證明差別確實來自時間方向。
    let past = project([event(.cited, a, minutesAgo: 1)], at: instant, resolvedBy: c, key: .forTesting)
    #expect(past.reinforcement(for: a) > 0)
}

@Test func anchorsWithNoEventsAreNotReportedAsOrphaned() {
    // 邊界：orphan 的語意是「有歷史但解不開」，不是「沒出現過」。
    let live = anchor("t1", 訊息A)
    let neverSeen = anchor("t2", 訊息B)
    let c = corpus([turn("t1", 訊息A), turn("t2", 訊息B)])

    let p = project([event(.opened, live, minutesAgo: 1)], at: instant, resolvedBy: c, key: .forTesting)
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

    let p = project([future], at: instant, resolvedBy: c, key: .forTesting)
    #expect(p.futureDatedEventsIgnored == 1)
    #expect(p[a] == nil, "它仍然不得計入強度")

    // 對照：時間戳合法時計數為 0，否則上面那條可能只是「永遠回 1」。
    let past = Event.interaction(
        .cited, anchor: a, at: instant.addingTimeInterval(-3600),
        generation: GenerationID("g1"), policy: RankingPolicyID("archival"))
    let ok = project([past], at: instant, resolvedBy: c, key: .forTesting)
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

    let now = project([e], at: instant, resolvedBy: c, key: .forTesting)
    let later = project([e], at: instant.addingTimeInterval(86_400 * 30), resolvedBy: c, key: .forTesting)

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

    let intact = project([e], at: instant, resolvedBy: corpus([turn("t1", text)]), key: .forTesting)
    let edited = project([e], at: instant, resolvedBy: corpus([turn("t1", "完全不同的內容")]), key: .forTesting)

    #expect(intact.reinforcement(for: a) > 0)
    #expect(edited.orphanedAnchors.contains(a))
    #expect(edited.reinforcement(for: a) == 0)
}

// MARK: - 擴散激發（spreading activation，#15）

@Test func aNonFiniteSpreadingFactorIsRejected() async {
    await #expect(processExitsWith: .failure) {
        _ = ProjectionParameters(spreadingActivationFactor: .nan)
    }
}

@Test func aNegativeSpreadingFactorIsRejected() async {
    await #expect(processExitsWith: .failure) {
        _ = ProjectionParameters(spreadingActivationFactor: -0.1)
    }
}

@Test func aSpreadingFactorOfOneOrMoreIsRejected() async {
    // #15 fix-round-2 verify finding：memory-events spec 的 SHALL 是「每筆擴散
    // 貢獻嚴格小於它衍生自的那筆直接互動貢獻」，這件事只有 factor < 1 時才成立
    // （factor == 1 讓擴散貢獻等於直接貢獻，不是嚴格小於）。先前完全沒有上界
    // 驗證，design.md 卻宣稱「透過 spreadingActivationFactor < 1 保證，見既有
    // precondition」——那個 precondition 當時不存在。
    await #expect(processExitsWith: .failure) {
        _ = ProjectionParameters(spreadingActivationFactor: 1.0)
    }
}

@Test func coPresentedAnchorWithNoDirectInteractionGainsReinforcement() {
    // 呈現群組 G：A 被點開，B、C 只是同框出現、從未被互動過。
    let group = PresentationID.random()
    let a = anchor("a", "同框呈現的第一則")
    let b = anchor("b", "同框呈現的第二則")
    let c = anchor("c", "同框呈現的第三則")
    let corpusReader = corpus([turn("a", "同框呈現的第一則"), turn("b", "同框呈現的第二則"), turn("c", "同框呈現的第三則")])

    let events: [Event] = [
        .interaction(.shown, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.shown, anchor: b, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.shown, anchor: c, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.opened, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
    ]
    let params = ProjectionParameters(spreadingActivationFactor: 0.3)
    let result = project(events, at: instant, resolvedBy: corpusReader, key: .forTesting, parameters: params)

    let aReinforcement = result.reinforcement(for: a)
    #expect(aReinforcement > 0, "A 自己被開，應該有直接增強")
    #expect(result.reinforcement(for: b) > 0, "B 同框出現，應該獲得擴散增強")
    #expect(result.reinforcement(for: c) > 0, "C 同框出現，應該獲得擴散增強")
    #expect(
        abs(result.reinforcement(for: b) - aReinforcement * 0.3) < 1e-9,
        "B 的擴散增強應恰為 A 直接增強的 spreadingActivationFactor 倍")
    #expect(result.reinforcement(for: b) < aReinforcement, "擴散增強必須小於直接增強")
}

@Test func anAnchorFromADifferentPresentationGroupGetsNoSpread() {
    let group = PresentationID.random()
    let otherGroup = PresentationID.random()
    let a = anchor("a", "群組一的第一則文字")
    let d = anchor("d", "群組二的獨立內容")
    let corpusReader = corpus([turn("a", "群組一的第一則文字"), turn("d", "群組二的獨立內容")])

    let events: [Event] = [
        .interaction(.shown, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.opened, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.shown, anchor: d, at: instant, generation: gen, policy: policy, presentation: otherGroup),
    ]
    let params = ProjectionParameters(spreadingActivationFactor: 0.3)
    let result = project(events, at: instant, resolvedBy: corpusReader, key: .forTesting, parameters: params)

    #expect(result.reinforcement(for: d) == 0, "不同呈現群組的 anchor 不應獲得擴散")
}

@Test func spreadingDoesNotRecursePastOneHop() {
    // A 在群組 G1 被開，B 與 A 同框（因此獲得擴散）；B 又跟 C 同框在**不同**群組 G2
    // （A 從未跟 C 同框）。擴散不應該從 B 再傳到 C。
    let g1 = PresentationID.random()
    let g2 = PresentationID.random()
    let a = anchor("a", "第一群組的來源文字")
    let b = anchor("b", "跨兩個群組的橋接")
    let c = anchor("c", "第二群組的獨立內容")
    let corpusReader = corpus([
        turn("a", "第一群組的來源文字"), turn("b", "跨兩個群組的橋接"), turn("c", "第二群組的獨立內容"),
    ])

    let events: [Event] = [
        .interaction(.shown, anchor: a, at: instant, generation: gen, policy: policy, presentation: g1),
        .interaction(.shown, anchor: b, at: instant, generation: gen, policy: policy, presentation: g1),
        .interaction(.opened, anchor: a, at: instant, generation: gen, policy: policy, presentation: g1),
        .interaction(.shown, anchor: b, at: instant, generation: gen, policy: policy, presentation: g2),
        .interaction(.shown, anchor: c, at: instant, generation: gen, policy: policy, presentation: g2),
    ]
    let params = ProjectionParameters(spreadingActivationFactor: 0.3)
    let result = project(events, at: instant, resolvedBy: corpusReader, key: .forTesting, parameters: params)

    #expect(result.reinforcement(for: b) > 0, "前提：B 因為跟 A 同框而獲得擴散")
    #expect(result.reinforcement(for: c) == 0, "C 不該因為 B 收到的擴散再借到任何增強——只做一跳")
}

@Test func dismissalDoesNotSpreadSuppression() {
    let group = PresentationID.random()
    let a = anchor("a", "被使用者不採用的那一則")
    let b = anchor("b", "同框但沒有被互動過的那一則")
    let corpusReader = corpus([turn("a", "被使用者不採用的那一則"), turn("b", "同框但沒有被互動過的那一則")])

    let events: [Event] = [
        .interaction(.shown, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.shown, anchor: b, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.dismissed, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
    ]
    let params = ProjectionParameters(spreadingActivationFactor: 0.3)
    let result = project(events, at: instant, resolvedBy: corpusReader, key: .forTesting, parameters: params)

    #expect((result[b]?.suppression ?? 0) == 0, "dismissed 不得把抑制擴散給同框但未互動的 anchor")
}

// MARK: - 擴散的邊界收斂（add-spreading-activation-fixes，#15 verify 後續）

@Test func dismissedAnchorDoesNotReceiveSpreadingReinforcementFromCoPresentedOpenedAnchor() {
    // 與 dismissalDoesNotSpreadSuppression 方向相反：那條測的是「dismissed 自己
    // 不把抑制擴散給別人」，這條測的是「dismissed 自己也不該從別人的擴散裡拿到
    // 正向增強」——使用者的明確負面訊號不該被同框的正面訊號部分抵銷。
    let group = PresentationID.random()
    let a = anchor("a", "被明確開啟的那一則內容")
    let b = anchor("b", "同框但被使用者明確不採用的那一則")
    let corpusReader = corpus([turn("a", "被明確開啟的那一則內容"), turn("b", "同框但被使用者明確不採用的那一則")])

    let events: [Event] = [
        .interaction(.shown, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.shown, anchor: b, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.opened, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.dismissed, anchor: b, at: instant, generation: gen, policy: policy, presentation: group),
    ]
    let params = ProjectionParameters(spreadingActivationFactor: 0.3)
    let result = project(events, at: instant, resolvedBy: corpusReader, key: .forTesting, parameters: params)

    #expect(result.reinforcement(for: a) > 0, "前提：A 自己被開，應該有直接增強")
    #expect(
        result.reinforcement(for: b) == 0,
        "B 有自己的 dismissed 事件，不該從同框的 A 收到擴散增強")
}

@Test func dismissedExclusionHoldsEvenWhenDismissedWeightIsZero() {
    // #15 fix-round-2 verify finding：排除條件先前綁在 `suppression[other] != 0`
    // ——用「抑制量的大小」代理「有沒有 dismissed 事件」。`dismissedWeight: 0`
    // 是合法參數值（precondition 只驗 >= 0），這種設定下 `suppression` 恆為 0，
    // 排除條件因此靜默失效。排除必須綁在「事件是否存在」，不是「權重算出來的
    // 數值」——跟 `MemoryStrategy.swift` 的 `RankingReason.History.none` 已經
    // 記過的同一個混淆。
    let group = PresentationID.random()
    let a = anchor("a", "被明確開啟的那一則內容")
    let b = anchor("b", "同框但被使用者明確不採用的那一則")
    let corpusReader = corpus([turn("a", "被明確開啟的那一則內容"), turn("b", "同框但被使用者明確不採用的那一則")])

    let events: [Event] = [
        .interaction(.shown, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.shown, anchor: b, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.opened, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.dismissed, anchor: b, at: instant, generation: gen, policy: policy, presentation: group),
    ]
    let params = ProjectionParameters(dismissedWeight: 0, spreadingActivationFactor: 0.3)
    let result = project(events, at: instant, resolvedBy: corpusReader, key: .forTesting, parameters: params)

    #expect(result.reinforcement(for: a) > 0, "前提：A 自己被開，應該有直接增強")
    #expect(
        result.reinforcement(for: b) == 0,
        "B 有自己的 dismissed 事件（即使 dismissedWeight 是 0），仍不該從同框的 A 收到擴散增強")
}

/// 建一個含 `memberCount` 個純曝光成員 + 1 個被開啟成員的同框群組，回傳
/// （corpus reader、events、純曝光成員的 anchor 清單）。共用給上限的邊界測試用，
/// 避免兩條測試各寫一份幾乎相同的建構邏輯。
private func makeOversizedGroupFixture(memberCount: Int, groupTag: String) -> (
    corpus: FixtureCorpus, events: [Event], shownOnlyAnchors: [Anchor]
) {
    let group = PresentationID.random()
    let openedID = "\(groupTag)-opened"
    let openedText = "在\(groupTag)群組裡被開啟的那一則"
    var turns = [turn(openedID, openedText)]
    var events: [Event] = [
        .interaction(
            .shown, anchor: anchor(openedID, openedText), at: instant, generation: gen,
            policy: policy, presentation: group),
        .interaction(
            .opened, anchor: anchor(openedID, openedText), at: instant, generation: gen,
            policy: policy, presentation: group),
    ]
    var shownOnlyAnchors: [Anchor] = []
    for i in 0..<memberCount {
        let id = "\(groupTag)-member-\(i)"
        let text = "\(groupTag)群組裡的第 \(i) 個純曝光成員"
        turns.append(turn(id, text))
        let a = anchor(id, text)
        shownOnlyAnchors.append(a)
        events.append(
            .interaction(
                .shown, anchor: a, at: instant, generation: gen, policy: policy,
                presentation: group))
    }
    return (corpus(turns), events, shownOnlyAnchors)
}

// `makeOversizedGroupFixture(memberCount:)` 建的群組是 memberCount 個純曝光
// 成員 **加上** 1 個被開啟成員，所以 `members.count`（`maxSpreadingGroupSize`
// 比較的量）等於 `memberCount + 1`。以下三條邊界測試都直接依這個關係換算，
// 註解裡不重複寫「等於多少」以免像 fix-round-2 那版一樣，換算數字寫錯又沒清乾淨
// （#15 fix-round-3 verify finding）。

@Test func presentationGroupExactlyAtCapSizeStillSpreads() {
    // `members.count == maxSpreadingGroupSize`（2000）：guard 用 `<=`，上限本身
    // 要放行。
    let fixture = makeOversizedGroupFixture(memberCount: 1999, groupTag: "atcap")
    let params = ProjectionParameters(spreadingActivationFactor: 0.3)
    let result = project(
        fixture.events, at: instant, resolvedBy: fixture.corpus, key: .forTesting, parameters: params)

    for a in fixture.shownOnlyAnchors {
        #expect(
            result.reinforcement(for: a) > 0,
            "群組大小恰好等於上限時仍應正常擴散——guard 用 <=，上限本身要放行")
    }
}

@Test func presentationGroupOneOverCapSizeDoesNotSpread() {
    // `members.count == maxSpreadingGroupSize + 1`（2001）：真正的邊界測試——
    // 跟上一條只差 1，能抓到 off-by-one 或比較方向寫反（`<` vs `<=`，`>` vs `>=`）。
    let fixture = makeOversizedGroupFixture(memberCount: 2000, groupTag: "onecap")
    let params = ProjectionParameters(spreadingActivationFactor: 0.3)
    let result = project(
        fixture.events, at: instant, resolvedBy: fixture.corpus, key: .forTesting, parameters: params)

    for a in fixture.shownOnlyAnchors {
        #expect(
            result.reinforcement(for: a) == 0,
            "群組大小比上限多 1 時應整體跳過擴散")
    }
}

@Test func oversizedPresentationGroupDoesNotSpread() {
    // 群組大小遠超過防禦性上限（`members.count == maxSpreadingGroupSize + 2`）
    // 時，整個群組跳過擴散——不是無界放大，是視為異常。上一條
    // `presentationGroupOneOverCapSizeDoesNotSpread` 已經釘住緊貼邊界的情形，
    // 這條確認「遠超過」同樣成立，不只是剛好跨過那一格。
    let fixture = makeOversizedGroupFixture(memberCount: 2001, groupTag: "over")
    let params = ProjectionParameters(spreadingActivationFactor: 0.3)
    let result = project(
        fixture.events, at: instant, resolvedBy: fixture.corpus, key: .forTesting, parameters: params)

    for a in fixture.shownOnlyAnchors {
        #expect(
            result.reinforcement(for: a) == 0,
            "群組大小超過上限時應整體跳過擴散，純曝光成員 reinforcement 應為 0")
    }
}

@Test func coPresentedShownOnlyAnchorsProduceNoReinforcementWithoutADeliberateEventInTheGroup() {
    // 「Only deliberate interactions reinforce」的新 scenario：同框群組內若沒有
    // 任何一個成員被 opened/cited/pinned，即使有 presentation 分組，全部成員的
    // reinforcement 仍應為 0——擴散只轉移既有的直接互動貢獻，不會憑空生出貢獻。
    let group = PresentationID.random()
    let a = anchor("a", "同框但誰都沒被開啟的第一則")
    let b = anchor("b", "同框但誰都沒被開啟的第二則")
    let corpusReader = corpus([turn("a", "同框但誰都沒被開啟的第一則"), turn("b", "同框但誰都沒被開啟的第二則")])

    let events: [Event] = [
        .interaction(.shown, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.shown, anchor: b, at: instant, generation: gen, policy: policy, presentation: group),
    ]
    let params = ProjectionParameters(spreadingActivationFactor: 0.3)
    let result = project(events, at: instant, resolvedBy: corpusReader, key: .forTesting, parameters: params)

    #expect(result.reinforcement(for: a) == 0)
    #expect(result.reinforcement(for: b) == 0)
}

@Test func theShippedDefaultActuallyEnablesSpreading() {
    // #15：擴散的所有測試都**顯式**傳 `spreadingActivationFactor`，所以出貨的
    // 預設值沒有任何鎖。實測：把預設改成 0，422 條全綠。
    //
    // 這比 issue 記的更糟一層。issue 記的是「擴散在生產路徑上零觸發」（沒有任何
    // 地方寫 deliberate 事件），而這條說的是：**即使有了觸發，出貨的預設也可能
    // 是關的，而沒有東西會發現。** 兩者疊起來，這個機制是雙重無守衛的。
    let group = PresentationID.random()
    let a = anchor("a", "同框呈現的第一則")
    let b = anchor("b", "同框呈現的第二則")
    let corpusReader = corpus([turn("a", "同框呈現的第一則"), turn("b", "同框呈現的第二則")])

    let events: [Event] = [
        .interaction(.shown, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.shown, anchor: b, at: instant, generation: gen, policy: policy, presentation: group),
        .interaction(.opened, anchor: a, at: instant, generation: gen, policy: policy, presentation: group),
    ]
    // **刻意用預設值**——這條測的就是那個值。
    let result = project(events, at: instant, resolvedBy: corpusReader, key: .forTesting)

    #expect(result.reinforcement(for: a) > 0, "前提：A 被開了")
    #expect(
        result.reinforcement(for: b) > 0,
        "出貨的預設必須讓擴散真的發生——否則這個機制在預設組態下不存在")
    #expect(result.reinforcement(for: b) < result.reinforcement(for: a))
}
