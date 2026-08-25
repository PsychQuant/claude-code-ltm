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
    generation: GenerationID = evalGeneration,
    startingSide: InterleavingHarness.Side = .a
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
        startingSide: startingSide,
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
    // **R5**：先前這裡斷言 `aggregate?.isEmpty == true`，也就是 aggregate 非 nil
    // 而內容為空——正是 doc、design.md 與 spec 三處都寫「不存在」的那個形狀
    // （「只有整體數字、沒有逐類列」）。三份文件寫著不變式而 code 不擋，於是
    // 這條測試通過的同時逐字否證了它們。不變式現在做進 code：classRows 空時
    // aggregate 必為 nil。
    #expect(report.aggregate == nil, "沒有逐類列時不得有整體數字")
    #expect(report.skipped.fromNullComparison == 1, "而那筆互動要看得見是被略過了")
}

@Test func crossGenerationReportPoolsNothingAtAllNotEvenPerClass() throws {
    // **R6 的 CRITICAL：先前只有 `aggregate` 變 nil，`classRows` 照樣跨 generation
    // 加總**——而 `ClassRow` 沒有 generation 欄位，所以那些數字正是 spec 禁止的
    // single figure。舊的這條測試（名字叫「no pooled aggregate at all」）建的
    // 正是這個輸入：兩筆紀錄、不同 generation、**同一個 query class**，而它只
    // 斷言 `aggregate == nil`，對 classRows 一字未提。
    let genA = GenerationID("build-1")
    let genB = GenerationID("build-2")
    let a = evalAnchor("a")
    let c = evalAnchor("c")
    let r1 = try presentation(.cjk2char, a: a, b: evalAnchor("b"), generation: genA)
    let r2 = try presentation(.cjk2char, a: c, b: evalAnchor("d"), generation: genB)

    let report = try ComparisonScorer.report(
        records: [r1, r2],
        events: [event(.opened, a, r1, generation: genA), event(.opened, c, r2, generation: genB)])

    #expect(report.spansGenerations)
    #expect(report.aggregate == nil)
    #expect(report.classRows.isEmpty, "跨 generation 時頂層逐類列必須是空的")
    #expect(report.generationRows.count == 2)
    // 逐類數字改由每個 generation 自己提供，且各自只含自己的資料。
    for row in report.generationRows {
        #expect(row.classRows.count == 1)
        #expect(row.classRows.first?.queryClass == .cjk2char)
        #expect(row.scores.values.reduce(0) { $0 + $1.credits } == 1)
        // **R7**：R6 修了 scores 的 pooling，漏了同一列上的 observations——
        // 每一代都回報兩代的觀測數。這條測試當時只驗 scores。
        #expect(row.classRows.first?.observations == 1, "每一代的觀測數不得含另一代的")
        #expect(row.observations == 1)
    }
}

@Test func singleGenerationReportStillHasPerClassRows() throws {
    // 反向對照：沒有這條，上面可以被「classRows 永遠空」滿足。
    let a = evalAnchor("a")
    let r = try presentation(.cjk2char, a: a, b: evalAnchor("b"))
    let report = try ComparisonScorer.report(records: [r], events: [event(.opened, a, r)])
    #expect(!report.spansGenerations)
    #expect(report.classRows.count == 1)
    #expect(report.aggregate != nil)
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

@Test func anEventPointingAtAPresentationAbsentFromTheSuppliedRecordsIsLegitimatelySkipped() throws {
    // 先前（#1 verify R4 修法）這與「事件本來就不屬於任何呈現」共用同一個
    // `continue`，被拆開成獨立的拒絕原因：缺一筆紀錄的後果是分母悄悄變小，
    // 而報告照常產出、看不出少算了什麼。
    //
    // 這條測試的斷言方向在 add-spreading-activation-fixes 反過來了：擴散機制
    // （#15）讓每次記錄查詢都配發 `PresentationID`，不限於正式比較實驗，所以
    // 「presentation 非 nil 但查無對應 record」現在幾乎必然是「這筆本來就不
    // 屬於任何比較」，而不是資料損壞。改成合法略過，不再拋錯（Decision 3）。
    let r = try presentation(.cjk2char, a: evalAnchor("a"), b: evalAnchor("b"))
    let strayID = PresentationID.random()
    let stray = Event.interaction(
        .opened, anchor: evalAnchor("a"), at: evalInstant,
        generation: evalGeneration, policy: archival, presentation: strayID)

    let report = try ComparisonScorer.report(records: [r], events: [stray])
    #expect(report.skipped.presentationNotTracked == 1)
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
    // 合法略過現在有三種（add-spreading-activation-fixes Decision 3 新增第三種）。
    // 數出來，是為了讓「這份報告用掉了多少事件」在報告本身讀得到，而不是只
    // 存在於讀 code 的人腦中。
    let a = evalAnchor("a")
    let real = try presentation(.cjk2char, a: a, b: evalAnchor("b"))
    let null = try PresentationRecord(
        id: .random(), queryClass: .cjk2char,
        strategyA: archival, strategyB: humanLike, generation: evalGeneration,
        attribution: [AnchorAttribution(anchor: a, creditedTo: nil)],
        startingSide: .b, isNullComparison: true)
    let untrackedID = PresentationID.random()

    let events: [Event] = [
        event(.opened, a, real),
        // 不屬於任何呈現。
        .interaction(.cited, anchor: a, at: evalInstant, generation: evalGeneration,
                     policy: archival, presentation: nil),
        // 屬於 null comparison。
        .interaction(.opened, anchor: a, at: evalInstant, generation: evalGeneration,
                     policy: archival, presentation: null.id),
        // presentation 非 nil，但不在本次供給的 records 裡。
        .interaction(.opened, anchor: a, at: evalInstant, generation: evalGeneration,
                     policy: archival, presentation: untrackedID),
    ]

    let report = try ComparisonScorer.report(records: [real, null], events: events)
    #expect(report.skipped.notFromAPresentation == 1)
    #expect(report.skipped.fromNullComparison == 1)
    #expect(report.skipped.presentationNotTracked == 1)
}


@Test func recordsComparingDifferentStrategyPairsAreRejected() throws {
    // R5：先前不檢查，於是 A/B 與 B/C 的紀錄會被靜默併成一張表，把從未互相
    // 比較過的兩個策略並列——與同一函式為 generation 建的防護是同一個缺陷類別。
    let ab = try presentation(.cjk2char, a: evalAnchor("a"), b: evalAnchor("b"))
    let third = RankingPolicyID("conservative")
    let bc = try PresentationRecord(
        id: .random(), queryClass: .cjk2char,
        strategyA: humanLike, strategyB: third, generation: evalGeneration,
        attribution: [AnchorAttribution(anchor: evalAnchor("c"), creditedTo: humanLike)],
        startingSide: .a, isNullComparison: false)

    #expect(throws: (any Error).self) {
        _ = try ComparisonScorer.report(records: [ab, bc], events: [])
    }
    // 對照：同一對策略的兩筆紀錄照常合併。
    let ab2 = try presentation(.cjk4plus, a: evalAnchor("d"), b: evalAnchor("e"))
    #expect(throws: Never.self) {
        _ = try ComparisonScorer.report(records: [ab, ab2], events: [])
    }
}


// MARK: - 分母、起手方、與「型別要能表達沒有數字」（#1 verify R5）

@Test func aStrategyWithNoImpressionsHasNoRateRatherThanZero() throws {
    // R5 實測：一個沒有任何 shown 事件、卻贏下每一筆被觀測互動的策略，rate
    // 讀作 0.0——與從沒得過分的策略在同一欄位上無法區分。而這不是邊角：
    // `presented` 只由 `.shown` 累加。
    let a = evalAnchor("a")
    let r = try presentation(.cjk2char, a: a, b: evalAnchor("b"))
    let report = try ComparisonScorer.report(records: [r], events: [event(.opened, a, r)])

    let row = report.classRows.first { $0.queryClass == .cjk2char }!
    let score = row.scores[archival]!
    #expect(score.net == 1, "它贏下了唯一一筆互動")
    #expect(score.presented == 0, "而它沒有任何曝光事件")
    #expect(score.rate == nil, "所以 rate 不該是一個看起來很有信心的 0.0")
}

@Test func aRateIsReportedWhenThereAreImpressions() throws {
    let a = evalAnchor("a")
    let r = try presentation(.cjk2char, a: a, b: evalAnchor("b"))
    let report = try ComparisonScorer.report(
        records: [r], events: [event(.shown, a, r), event(.opened, a, r)])
    #expect(report.classRows.first?.scores[archival]?.rate == 1.0)
}

@Test func theReportMakesTheStartingSideAssignmentVisible() throws {
    // R4 把起手方寫進紀錄，理由是「記下來才能事後檢查分派是否平衡」——而那個
    // 檢查沒有任何程式碼實作它（R5）。這條把「可見」釘成事實。
    let balanced = [
        try presentation(.cjk2char, a: evalAnchor("a"), b: evalAnchor("b"), startingSide: .a),
        try presentation(.cjk2char, a: evalAnchor("c"), b: evalAnchor("d"), startingSide: .b),
    ]
    let report = try ComparisonScorer.report(records: balanced, events: [])
    #expect(report.startingSides.a == 1)
    #expect(report.startingSides.b == 1)
    #expect(!report.startingSides.isSeverelyImbalanced)

    let lopsided = (0..<8).map { i in
        try! presentation(.cjk2char, a: evalAnchor("x\(i)"), b: evalAnchor("y\(i)"), startingSide: .a)
    }
    let bad = try ComparisonScorer.report(records: lopsided, events: [])
    #expect(bad.startingSides.isSeverelyImbalanced, "全部同側必須是讀得出來的事實")
}


@Test func aGenerationMismatchIsNotLaunderedByANullComparison() throws {
    // R6：null 的分支先 `continue`，於是一筆 generation 對不上的事件只要指向
    // null 紀錄就被洗成「合法略過」——資料不一致偽裝成正常情形。
    let a = evalAnchor("a")
    let null = try PresentationRecord(
        id: .random(), queryClass: .cjk2char,
        strategyA: archival, strategyB: humanLike, generation: GenerationID("build-1"),
        attribution: [AnchorAttribution(anchor: a, creditedTo: nil)],
        startingSide: .a, isNullComparison: true)

    let mislabelled = Event.interaction(
        .opened, anchor: a, at: evalInstant, generation: GenerationID("build-2"),
        policy: archival, presentation: null.id)

    #expect(throws: ComparisonDataError.generationMismatch(presentation: null.id)) {
        _ = try ComparisonScorer.report(records: [null], events: [mislabelled])
    }
}

@Test func aRecordCannotCompareAStrategyWithItself() {
    // 交錯器已經擋這件事，但 `PresentationRecord` 是公開可建構、也會被解碼的。
    #expect(throws: PresentationRecord.ShapeViolation.strategiesShareAnIdentifier(archival)) {
        _ = try PresentationRecord(
            id: .random(), queryClass: .cjk2char,
            strategyA: archival, strategyB: archival, generation: evalGeneration,
            attribution: [AnchorAttribution(anchor: evalAnchor("a"), creditedTo: archival)],
            startingSide: .a, isNullComparison: false)
    }
}

@Test func theReportCarriesAStartingSideCorrectedEstimateAlongsideTheRawCounts() throws {
    // `strategy-comparison` spec 的 scenario「A report corrects for a starting-side
    // imbalance」。**它先前沒有測試，而且不可能通過**——校正函式寫好了，但沒有任何
    // 呼叫端，報告連欄位都沒有（#16 verify，CRITICAL）。那是同一個「只完成一半」
    // 的第四次：R3 拿掉預設值 → R4 補機制未記錄 → R5 補計數沒人讀 → #16 補函式
    // 沒人呼叫。
    //
    // 分派刻意失衡（A 起手 3 次、B 起手 1 次），且兩層的偏好方向相反，讓校正後的
    // 數字與 pooled rate **不相等**——否則這條測試分不出有沒有校正。
    let aSide = (0..<3).map { i in
        try! presentation(
            .cjk2char, a: evalAnchor("pa\(i)"), b: evalAnchor("pb\(i)"), startingSide: .a)
    }
    let bSide = [
        try presentation(.cjk2char, a: evalAnchor("qa"), b: evalAnchor("qb"), startingSide: .b)
    ]
    // A 起手的三次全部偏好 archival；B 起手的一次偏好 human-like。
    var events: [Event] = aSide.map { event(.opened, $0.attribution[0].anchor, $0) }
    events.append(event(.opened, bSide[0].attribution[1].anchor, bSide[0]))

    let report = try ComparisonScorer.report(records: aSide + bSide, events: events)

    // 原始計數仍在（scenario 要求「both」）
    #expect(report.startingSides.a == 3)
    #expect(report.startingSides.b == 1)

    let corrected = try #require(report.startingSideCorrected)
    // 兩層各自的 archival 偏好率：A 起手層 3/3 = 1.0、B 起手層 0/1 = 0.0，
    // 等權重平均 = 0.5。pooled rate 會是 3/4 = 0.75——**兩者不同，這才證明校正生效**。
    let archivalCorrected = try #require(corrected[archival])
    #expect(abs(archivalCorrected - 0.5) < 1e-9, "等權重兩層平均，不是 pooled 的 0.75")
    let humanLikeCorrected = try #require(corrected[humanLike])
    #expect(abs(humanLikeCorrected - 0.5) < 1e-9)
}

@Test func aDegenerateStartingSideDistributionYieldsNoCorrection() throws {
    // spec 的 degenerate scenario：某一層完全沒有觀測時，報告要說「算不出來」，
    // 而不是回一個由單層推出的假校正。這條同樣先前沒有測試。
    let allOneSide = (0..<4).map { i in
        try! presentation(
            .cjk2char, a: evalAnchor("za\(i)"), b: evalAnchor("zb\(i)"), startingSide: .a)
    }
    let events = allOneSide.map { event(.opened, $0.attribution[0].anchor, $0) }
    let report = try ComparisonScorer.report(records: allOneSide, events: events)

    #expect(report.startingSides.b == 0)
    #expect(report.startingSideCorrected == nil, "只有一層有觀測時，校正不可計算")
}

// MARK: - 事件自報的 policy（#21 item 2）

@Test func anEventNamingADifferentStrategyThanTheAttributionIsReported() throws {
    // 事件有 `policy`，紀錄有 `attribution`。兩者矛盾時 scorer 先前**靜默採信
    // 紀錄**——而同一個迴圈往上十二行就有 `generationMismatch`，防的是同一個
    // 缺陷類別。靜默採信其中一份，等於讓讀者看不到資料已經不一致。
    let r = try presentation(.cjk2char, a: evalAnchor("a"), b: evalAnchor("b"))
    // 位置 a 歸給 archival（`startingSide: .a`），而事件宣稱它來自 human-like。
    let mislabelled = Event.interaction(
        .opened, anchor: evalAnchor("a"), at: evalInstant,
        generation: evalGeneration, policy: humanLike, presentation: r.id)

    #expect(
        throws: ComparisonDataError.policyMismatch(
            presentation: r.id, reported: humanLike, attributed: archival)
    ) {
        _ = try ComparisonScorer.report(records: [r], events: [mislabelled])
    }
}

@Test func theInterleavedReservedPolicyIsCompatibleWithAnyAttribution() throws {
    // 不對稱是刻意的：保留值宣告的正是「這次呈現沒有單一策略」，所以它與任何
    // 逐位置歸屬都相容。這是比較模式下**每一筆**事件的實際形狀——嚴格相等會
    // 把它們全部判成資料不一致。
    let r = try presentation(.cjk2char, a: evalAnchor("a"), b: evalAnchor("b"))
    let normal = Event.interaction(
        .opened, anchor: evalAnchor("a"), at: evalInstant,
        generation: evalGeneration, policy: .interleaved, presentation: r.id)

    let report = try ComparisonScorer.report(records: [r], events: [normal])
    #expect(report.skipped.notFromAPresentation == 0)
    #expect(report.skipped.fromNullComparison == 0)
    #expect(report.skipped.presentationNotTracked == 0, "保留值不該被判成不一致")
}
