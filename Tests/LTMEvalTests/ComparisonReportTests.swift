import Foundation
import Testing

@testable import LTMCore
@testable import LTMEval
@testable import LTMQuery

private let archival = RankingPolicyID("archival")
private let humanLike = RankingPolicyID("human-like")

/// 造一次呈現：兩個位置，一邊各一個。
private func presentation(
    _ queryClass: QueryClass,
    a: Anchor,
    b: Anchor,
    generation: GenerationID = evalGeneration
) throws -> PresentationRecord {
    try PresentationRecord(
        id: .random(),
        queryClass: queryClass,
        strategyA: archival, strategyB: humanLike,
        generation: generation,
        attribution: [
            AnchorAttribution(anchor: a, creditedTo: archival),
            AnchorAttribution(anchor: b, creditedTo: humanLike),
        ],
        startingSide: .a,
        isNullComparison: false)
}

private func event(
    _ kind: NonPinKind, _ anchor: Anchor, _ record: PresentationRecord,
    generation: GenerationID = evalGeneration
) -> Event {
    .interaction(
        kind, anchor: anchor, at: evalInstant, generation: generation,
        policy: record.credit(for: anchor) ?? archival, presentation: record.id)
}

@Test func reportCarriesOneRowPerQueryClassWithObservationCounts() throws {
    let a2 = evalAnchor("a2")
    let b2 = evalAnchor("b2")
    let a4 = evalAnchor("a4")
    let b4 = evalAnchor("b4")
    let aLatin = evalAnchor("aL")
    let bLatin = evalAnchor("bL")

    let r2 = try presentation(.cjk2char, a: a2, b: b2)
    let r4 = try presentation(.cjk4plus, a: a4, b: b4)
    let rLatin = try presentation(.latinAlnum, a: aLatin, b: bLatin)

    let events = [
        event(.shown, a2, r2), event(.shown, b2, r2), event(.opened, b2, r2),
        event(.shown, a4, r4), event(.shown, b4, r4), event(.cited, a4, r4),
        event(.shown, aLatin, rLatin), event(.shown, bLatin, rLatin),
    ]

    let report = try ComparisonScorer.report(records: [r2, r4, rLatin], events: events)

    #expect(report.classRows.map(\.queryClass) == [.cjk2char, .cjk4plus, .latinAlnum])
    #expect(report.classRows.first { $0.queryClass == .cjk2char }?.observations == 1)
    #expect(report.classRows.first { $0.queryClass == .cjk4plus }?.observations == 1)
    // 觀測數為 0 的桶仍然要出現——「這一類沒有資料」本身就是要被看見的事實。
    #expect(report.classRows.first { $0.queryClass == .latinAlnum }?.observations == 0)
}

@Test func aggregateNeverAppearsWithoutPerClassRows() throws {
    let a = evalAnchor("a")
    let b = evalAnchor("b")
    let r = try presentation(.cjk2char, a: a, b: b)
    let report = try ComparisonScorer.report(
        records: [r], events: [event(.shown, a, r), event(.shown, b, r), event(.opened, b, r)])

    #expect(!report.classRows.isEmpty)
    #expect(report.aggregate?[humanLike]?.credits == 1)
}

@Test func aClassLocalEffectIsNotWashedOutByTheAggregate() throws {
    // 一個桶裡 human-like 完勝，其餘桶全平手。整體看幾乎沒差，逐桶看很清楚。
    var records: [PresentationRecord] = []
    var events: [Event] = []

    for i in 0..<10 {
        let a = evalAnchor("t2a\(i)")
        let b = evalAnchor("t2b\(i)")
        let r = try presentation(.cjk2char, a: a, b: b)
        records.append(r)
        events += [event(.shown, a, r), event(.shown, b, r), event(.opened, b, r)]
    }
    for i in 0..<90 {
        let a = evalAnchor("t4a\(i)")
        let b = evalAnchor("t4b\(i)")
        let r = try presentation(.cjk4plus, a: a, b: b)
        records.append(r)
        events += [event(.shown, a, r), event(.shown, b, r)]
    }

    let report = try ComparisonScorer.report(records: records, events: events)

    let 雙字 = report.classRows.first { $0.queryClass == .cjk2char }!
    #expect(雙字.scores[humanLike]?.rate == 1.0)
    #expect(雙字.scores[archival]?.rate == 0.0)

    let 四字 = report.classRows.first { $0.queryClass == .cjk4plus }!
    #expect(四字.scores[humanLike]?.net == 0)

    // 整體被 90 個平手桶稀釋到 0.1——分桶那一列才看得見 1.0。
    #expect(report.aggregate?[humanLike]?.rate == 0.1)
}

@Test func impressionsFormTheDenominatorNotTheNumerator() throws {
    let a = evalAnchor("a")
    let b = evalAnchor("b")
    let r = try PresentationRecord(
        id: .random(), queryClass: .cjk2char,
        strategyA: archival, strategyB: humanLike, generation: evalGeneration,
        attribution: [
            AnchorAttribution(anchor: a, creditedTo: archival),
            AnchorAttribution(anchor: b, creditedTo: humanLike),
            AnchorAttribution(anchor: evalAnchor("c"), creditedTo: archival),
        ],
        startingSide: .a,
        isNullComparison: false)

    // archival 貢獻兩個位置、human-like 一個；各自只有一次 credit。
    let events = [
        event(.shown, a, r), event(.shown, evalAnchor("c"), r), event(.shown, b, r),
        event(.opened, a, r), event(.opened, b, r),
    ]
    let report = try ComparisonScorer.report(records: [r], events: events)

    #expect(report.aggregate?[archival]?.presented == 2)
    #expect(report.aggregate?[humanLike]?.presented == 1)
    #expect(report.aggregate?[archival]?.rate == 0.5)  // 用自己的分母，不是互動總數
    #expect(report.aggregate?[humanLike]?.rate == 1.0)
}

@Test func dismissalCountsAgainstTheCreditingStrategy() throws {
    let a = evalAnchor("a")
    let b = evalAnchor("b")
    let r = try presentation(.cjk2char, a: a, b: b)
    let report = try ComparisonScorer.report(
        records: [r],
        events: [event(.shown, a, r), event(.shown, b, r), event(.dismissed, b, r)])

    #expect(report.aggregate?[humanLike]?.penalties == 1)
    #expect(report.aggregate?[humanLike]?.net == -1)
    #expect(report.aggregate?[archival]?.net == 0)
}

@Test func nullComparisonsAreExcludedFromScoring() throws {
    let a = evalAnchor("a")
    let b = evalAnchor("b")
    let null = try PresentationRecord(
        id: .random(), queryClass: .cjk2char,
        strategyA: archival, strategyB: humanLike, generation: evalGeneration,
        attribution: [
            AnchorAttribution(anchor: a, creditedTo: nil),
            AnchorAttribution(anchor: b, creditedTo: nil),
        ],
        startingSide: .b,
        isNullComparison: true)

    let report = try ComparisonScorer.report(
        records: [null],
        events: [
            .interaction(.opened, anchor: a, at: evalInstant, generation: evalGeneration,
                policy: archival, presentation: null.id)
        ])

    #expect(report.classRows.isEmpty)
    #expect(report.aggregate?.isEmpty == true)
}

@Test func crossGenerationReportHasNoPooledAggregateAtAll() throws {
    // spec: "Results from different generations SHALL NOT be silently pooled into
    // a single figure"。先前 aggregate 是非 optional，型別上無法表達「這裡不該有
    // 整體數字」，只讀 aggregate 的消費端會拿到被明文禁止的混合結論。
    let genA = GenerationID("build-1")
    let genB = GenerationID("build-2")
    let r1 = try presentation(.cjk2char, a: evalAnchor("a1"), b: evalAnchor("b1"), generation: genA)
    let r2 = try presentation(.cjk2char, a: evalAnchor("a2"), b: evalAnchor("b2"), generation: genB)

    let report = try ComparisonScorer.report(
        records: [r1, r2],
        events: [
            event(.shown, evalAnchor("a1"), r1, generation: genA),
            event(.opened, evalAnchor("b1"), r1, generation: genA),
            event(.shown, evalAnchor("a2"), r2, generation: genB),
            event(.opened, evalAnchor("a2"), r2, generation: genB),
        ])

    #expect(report.spansGenerations)
    #expect(report.aggregate == nil)
    #expect(report.generationRows.count == 2)
}

@Test func duplicatePresentationIdentifiersAreReportedNotTrapped() {
    // 先前用 Dictionary(uniqueKeysWithValues:)，重複 ID 直接 fatalError。
    // 呈現紀錄來自檔案，重複是資料問題不是程式錯誤。
    let shared = PresentationID.random()
    func record(_ anchor: Anchor) throws -> PresentationRecord {
        try PresentationRecord(
            id: shared, queryClass: .cjk2char,
            strategyA: archival, strategyB: humanLike, generation: evalGeneration,
            attribution: [AnchorAttribution(anchor: anchor, creditedTo: archival)],
            startingSide: .a,
        isNullComparison: false)
    }

    #expect(throws: ComparisonDataError.duplicatePresentationID(shared)) {
        _ = try ComparisonScorer.report(
            records: [try record(evalAnchor("a")), try record(evalAnchor("b"))], events: [])
    }
}

@Test func attributionNamingAStrategyOutsideTheComparisonIsRejected() throws {
    // #1 verify R3：scorer 先前直接信任 `credit(for:)` 回來的任何 policy id，
    // 於是損壞或偽造的紀錄可以把分數記到根本沒參與這次比較的策略頭上，
    // 而報告照常產出。
    let third = RankingPolicyID("some-other-strategy")
    let r = try PresentationRecord(
        id: .random(), queryClass: .cjk2char,
        strategyA: archival, strategyB: humanLike, generation: evalGeneration,
        attribution: [AnchorAttribution(anchor: evalAnchor("a"), creditedTo: third)],
        startingSide: .a,
        isNullComparison: false)

    #expect(throws: ComparisonDataError.attributionNamesAThirdStrategy(
        presentation: r.id, policy: third)
    ) {
        _ = try ComparisonScorer.report(records: [r], events: [])
    }
}

@Test func anAnchorAppearingTwiceInOnePresentationIsRejected() throws {
    // 一次呈現裡同一個 anchor 出現兩次 → 分母會被灌水，而報告看不出來。
    let a = evalAnchor("a")
    let r = try PresentationRecord(
        id: .random(), queryClass: .cjk2char,
        strategyA: archival, strategyB: humanLike, generation: evalGeneration,
        attribution: [
            AnchorAttribution(anchor: a, creditedTo: archival),
            AnchorAttribution(anchor: a, creditedTo: humanLike),
        ],
        startingSide: .a,
        isNullComparison: false)

    #expect(throws: ComparisonDataError.duplicateAnchorInPresentation(
        presentation: r.id, anchor: a)
    ) {
        _ = try ComparisonScorer.report(records: [r], events: [])
    }
}

@Test func anEventMislabelledWithAnotherGenerationIsReported() throws {
    let r = try presentation(.cjk2char, a: evalAnchor("a"), b: evalAnchor("b"), generation: GenerationID("build-1"))
    // 事件自報 build-2，但它所屬的呈現是 build-1。靜默採信會讓一次呈現被切成
    // 兩半、rate 悄悄歸零。
    let mislabelled = Event.interaction(
        .opened, anchor: evalAnchor("a"), at: evalInstant,
        generation: GenerationID("build-2"), policy: archival, presentation: r.id)

    #expect(throws: ComparisonDataError.generationMismatch(presentation: r.id)) {
        _ = try ComparisonScorer.report(records: [r], events: [mislabelled])
    }
}

@Test func dataSpanningGenerationsIsFlaggedAndBrokenDown() throws {
    let genA = GenerationID("build-1")
    let genB = GenerationID("build-2")

    let a1 = evalAnchor("a1")
    let b1 = evalAnchor("b1")
    let a2 = evalAnchor("a2")
    let b2 = evalAnchor("b2")

    let r1 = try presentation(.cjk2char, a: a1, b: b1, generation: genA)
    let r2 = try presentation(.cjk2char, a: a2, b: b2, generation: genB)

    let events = [
        event(.shown, a1, r1, generation: genA), event(.shown, b1, r1, generation: genA),
        event(.opened, b1, r1, generation: genA),
        event(.shown, a2, r2, generation: genB), event(.shown, b2, r2, generation: genB),
        event(.opened, a2, r2, generation: genB),
    ]

    let report = try ComparisonScorer.report(records: [r1, r2], events: events)

    #expect(report.spansGenerations)
    #expect(report.generationRows.map(\.generation) == [genA, genB])
    #expect(report.generationRows.first { $0.generation == genA }?.scores[humanLike]?.credits == 1)
    #expect(report.generationRows.first { $0.generation == genB }?.scores[archival]?.credits == 1)
}

@Test func singleGenerationDataIsNotFlagged() throws {
    let a = evalAnchor("a")
    let b = evalAnchor("b")
    let r = try presentation(.cjk2char, a: a, b: b)
    let report = try ComparisonScorer.report(
        records: [r], events: [event(.shown, a, r), event(.opened, b, r)])

    #expect(!report.spansGenerations)
    #expect(report.generationRows.isEmpty)
}

// MARK: - 略過的四種情形是封閉列舉（#1 verify R4）

@Test func anEventPointingAtAnUnknownPresentationIsRejected() throws {
    // 先前這與「事件本來就不屬於任何呈現」共用同一個 `continue`：缺一筆紀錄
    // 的後果是分母悄悄變小，而報告照常產出、看不出少算了什麼。
    let r = try presentation(.cjk2char, a: evalAnchor("a"), b: evalAnchor("b"))
    let orphanID = PresentationID.random()
    let stray = Event.interaction(
        .opened, anchor: evalAnchor("a"), at: evalInstant,
        generation: evalGeneration, policy: archival, presentation: orphanID)

    #expect(throws: ComparisonDataError.unknownPresentationReference(orphanID)) {
        _ = try ComparisonScorer.report(records: [r], events: [stray])
    }
}

@Test func anEventWhoseAnchorWasNeverPresentedIsRejected() throws {
    // 非 null 的紀錄保證每個 anchor 都有歸屬，所以查不到只有一個意思：
    // 這次呈現根本沒出示過這個 anchor。
    let r = try presentation(.cjk2char, a: evalAnchor("a"), b: evalAnchor("b"))
    let unseen = evalAnchor("never-shown")
    let stray = Event.interaction(
        .opened, anchor: unseen, at: evalInstant,
        generation: evalGeneration, policy: archival, presentation: r.id)

    #expect(throws: ComparisonDataError.anchorNotInPresentation(
        presentation: r.id, anchor: unseen)
    ) {
        _ = try ComparisonScorer.report(records: [r], events: [stray])
    }
}

@Test func legitimateSkipsAreCountedInTheReport() throws {
    // 合法略過只有兩種。數出來，是為了讓「這份報告用掉了多少事件」在報告
    // 本身讀得到，而不是只存在於讀 code 的人腦中。
    let a = evalAnchor("a")
    let real = try presentation(.cjk2char, a: a, b: evalAnchor("b"))
    let null = try PresentationRecord(
        id: .random(), queryClass: .cjk2char,
        strategyA: archival, strategyB: humanLike, generation: evalGeneration,
        attribution: [AnchorAttribution(anchor: a, creditedTo: nil)],
        startingSide: .b, isNullComparison: true)

    let events: [Event] = [
        event(.opened, a, real),
        // 不屬於任何呈現。
        .interaction(.cited, anchor: a, at: evalInstant, generation: evalGeneration,
                     policy: archival, presentation: nil),
        // 屬於 null comparison。
        .interaction(.opened, anchor: a, at: evalInstant, generation: evalGeneration,
                     policy: archival, presentation: null.id),
    ]

    let report = try ComparisonScorer.report(records: [real, null], events: events)
    #expect(report.skipped.notFromAPresentation == 1)
    #expect(report.skipped.fromNullComparison == 1)
}
