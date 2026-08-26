import Foundation
import Testing

@testable import LTMCore
@testable import LTMEval
@testable import LTMIndex
@testable import LTMMemory
@testable import LTMQuery
@testable import LTMService

// 全部走合成語料。真實 `~/.claude/projects/` 一次都沒被碰到。

/// 數 `vector(for:)` 被呼叫幾次的 embedder。
///
/// 存在的理由是任務 1.2 的驗證目標——「一次檢索、兩份排序」這條性質從輸出上
/// 看不出來（兩次檢索在確定性 embedder 下會給出同一份清單），所以斷言必須下在
/// **檢索被執行了幾次**上。用 class 是因為計數要跨 `Sendable` 的值語意留存。
final class CountingEmbedder: EmbeddingProvider, @unchecked Sendable {
    let revision = "test-rev-1"
    let dimension = 8
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func callCount(for text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[text] ?? 0
    }

    func vector(for text: String) throws -> [Float]? {
        lock.lock()
        counts[text, default: 0] += 1
        lock.unlock()
        return try FixedEmbedder().vector(for: text)
    }
}

extension Workspace {
    var recordsURL: URL { eventsURL.deletingLastPathComponent().appendingPathComponent("p.jsonl") }

    /// 帶事件與呈現紀錄兩個存放的 facade——比較模式要的組態。
    func comparisonService(embedder: any EmbeddingProvider = FixedEmbedder()) throws -> LTMService {
        LTMService(
            location: derived, corpusRoot: corpus, embedder: embedder,
            eventStore: try FileEventStore(url: eventsURL),
            anchorKey: .forTesting, recordStore: try FilePresentationRecordStore(url: recordsURL))
    }
}

private let comparisonPair = (a: RankingPolicyID("archival"), b: RankingPolicyID("human-like"))

// MARK: - 任務 1.2：一次檢索，兩份排序

@Test("比較模式只檢索一次，而兩份排序涵蓋的候選完全相同")
func comparisonRetrievesOnceAndRanksTheSameCandidates() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容", "第四段內容"])
    let embedder = CountingEmbedder()
    let service = try workspace.comparisonService(embedder: embedder)
    try service.build()

    let query = "內容"
    let before = embedder.callCount(for: query)
    let outcome = try service.compare(
        text: query, limit: 20, scope: .allProjects, a: comparisonPair.a, b: comparisonPair.b)

    // 查詢向量每檢索一次算一次。兩次檢索會是 2。
    #expect(
        embedder.callCount(for: query) - before == 1,
        "候選只取一次；分兩次檢索會讓兩邊因為與策略無關的理由而不同")

    // 兩份排序各自都是候選的排列（交錯器對每一邊都驗過），而交錯結果的 anchor
    // 集合等於檢索順序的集合——合起來即「兩邊排的是同一份清單」。
    let retrieved = Set(try workspace.retrievalOrder(text: query, limit: 20))
    #expect(Set(outcome.hits.map(\.uuid)) == retrieved)
    #expect(Set(outcome.record.presented.map(\.turnID)) == retrieved)
}

// MARK: - 任務 1.3：不能記錄的比較不執行

@Test("沒有事件存放時，比較模式在呈現任何東西之前就失敗")
func comparisonWithoutStoresFailsBeforePresentingAnything() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["記憶策略可插拔", "檢索基線量測"])
    try workspace.service().build()

    // 只有事件存放、沒有紀錄存放——同樣不足以記錄一次比較。
    let halfEquipped = LTMService(
        location: workspace.derived, corpusRoot: workspace.corpus, embedder: FixedEmbedder(),
        eventStore: try FileEventStore(url: workspace.eventsURL), anchorKey: .forTesting, recordStore: nil)
    #expect(throws: LTMService.ServiceError.comparisonRequiresStores) {
        _ = try halfEquipped.compare(
            text: "內容", limit: 20, scope: .allProjects,
            a: comparisonPair.a, b: comparisonPair.b)
    }
    // 兩個都沒有。
    let unequipped = try workspace.service()
    #expect(throws: LTMService.ServiceError.comparisonRequiresStores) {
        _ = try unequipped.compare(
            text: "內容", limit: 20, scope: .allProjects,
            a: comparisonPair.a, b: comparisonPair.b)
    }
    #expect(
        !FileManager.default.fileExists(atPath: workspace.recordsURL.path),
        "拒絕的路徑不得留下任何紀錄")
}

@Test("對擴散激發要求不同的一對策略被拒絕，而不是挑一邊的 projection")
func incompatibleStrategyPairIsRefused() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["記憶策略可插拔", "檢索基線量測"])
    let service = try workspace.comparisonService()
    try service.build()

    // conservative 與 human-like 都消費歷史，但只有後者套用擴散。共用一份
    // projection 必然讓其中一邊看到 spec 沒授權它看的統計（#15 verify）。
    #expect(
        throws: LTMService.ServiceError.incompatibleComparisonPair(
            a: "conservative", b: "human-like")
    ) {
        _ = try service.compare(
            text: "內容", limit: 20, scope: .allProjects,
            a: RankingPolicyID("conservative"), b: RankingPolicyID("human-like"))
    }
    #expect(
        !FileManager.default.fileExists(atPath: workspace.recordsURL.path),
        "被拒絕的一對不得留下紀錄")
}

@Test("不存在的策略識別碼具名拒絕，不退回預設值")
func unknownStrategyIdentifierIsNamed() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["記憶策略可插拔"])
    let service = try workspace.comparisonService()
    try service.build()

    #expect(throws: LTMService.ServiceError.unknownStrategy(name: "no-such-strategy")) {
        _ = try service.compare(
            text: "內容", limit: 20, scope: .allProjects,
            a: RankingPolicyID("no-such-strategy"), b: comparisonPair.b)
    }
}

// MARK: - 任務 3.1：端到端——記錄下來的比較真的到得了計分端

@Test("比較模式寫下的紀錄與事件餵給計分端時，事件被歸屬而不是當成無主呈現略過")
func aRecordedComparisonReachesTheScorer() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容", "第四段內容"])
    let service = try workspace.comparisonService()
    try service.build()

    let outcome = try service.compare(
        text: "內容", limit: 20, scope: .allProjects, a: comparisonPair.a, b: comparisonPair.b)
    #expect(!outcome.hits.isEmpty)
    #expect(outcome.eventsRecorded == outcome.hits.count)

    // 從**檔案**讀回來，不是拿記憶體裡那份——本次改動要修的正是「落地的東西
    // 到不了計分端」，用記憶體物件驗等於跳過被修的那一段。
    let records = try FilePresentationRecordStore(url: workspace.recordsURL).allRecords()
    let events = try FileEventStore(url: workspace.eventsURL).allEvents()
    #expect(records.count == 1)
    #expect(events.count == outcome.hits.count)

    let report = try ComparisonScorer.report(records: records, events: events)

    // **斷言下在略過計數上，不是「有沒有產出報告」。** 全部事件被略過時報告
    // 照樣產得出來——那正是這次改動之前的狀態，而它不報錯。
    #expect(
        report.skipped.presentationNotTracked == 0,
        "事件必須經由紀錄被歸屬；這個計數非零就代表落地的紀錄沒到計分端")
    #expect(report.skipped.notFromAPresentation == 0)
}

// MARK: - 任務 3.3：bootstrap 期的相同順序是被記錄，不是被拒絕

@Test("沒有任何使用歷史時兩邊順序相同，寫下的是 null comparison 而不是錯誤")
func identicalOrderingsDuringBootstrapAreRecordedNotRejected() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    let service = try workspace.comparisonService()
    try service.build()

    // 事件檔此時是空的 → 每個 anchor 的淨強度都是 0 → 沒有策略會重排。
    let outcome = try service.compare(
        text: "內容", limit: 20, scope: .allProjects, a: comparisonPair.a, b: comparisonPair.b)

    #expect(outcome.record.isNullComparison, "兩邊順序相同時必須標成 null comparison")
    #expect(
        outcome.record.attribution.allSatisfy { $0.creditedTo == nil },
        "null comparison 不得把任何位置記給任何一邊")

    // 紀錄照樣落地，而計分端把它整批略過——這是既有的、被表達出來的狀態。
    let records = try FilePresentationRecordStore(url: workspace.recordsURL).allRecords()
    let events = try FileEventStore(url: workspace.eventsURL).allEvents()
    #expect(records.count == 1)
    let report = try ComparisonScorer.report(records: records, events: events)
    #expect(report.skipped.fromNullComparison == events.count)
    #expect(report.skipped.presentationNotTracked == 0)
}

// MARK: - 隱私：落地的 bytes 不含 query 原文

@Test("呈現紀錄落地的 bytes 不含 query 原文，也不含語料原文")
func nothingVerbatimReachesThePresentationRecord() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    let corpusText = "記憶策略可插拔"
    try workspace.writeSession(texts: [corpusText, "檢索基線量測", "第三段內容"])
    let service = try workspace.comparisonService()
    try service.build()

    let query = "可插拔的內容"
    _ = try service.compare(
        text: query, limit: 20, scope: .allProjects, a: comparisonPair.a, b: comparisonPair.b)

    let bytes = try FilePresentationRecordStore(url: workspace.recordsURL).serializedBytes()
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains(query), "query 原文在 harness 算完 class label 之後就該被丟掉")
    #expect(!text.contains(corpusText), "紀錄只存指標，不存語料原文")
    // 存進去的是封閉五值標籤——原文的資訊量沒有留下。
    #expect(QueryClass.allCases.contains { text.contains($0.rawValue) })
}

// MARK: - 呈現紀錄存放走的是與事件檔同一道守衛

@Test("呈現紀錄的路徑落在唯讀語料內時，建構就失敗")
func recordStoreRefusesAPathInsideTheCorpus() throws {
    // 這條路徑不會被建立——建構子在任何 I/O 之前就拒絕。守衛的實作與
    // `FileEventStore` 共用（`CanonicalStore.validatedPath`），這條測試存在的
    // 理由是**確認新的呼叫端真的走了它**：共用一份實作不等於兩個呼叫端都用上。
    let inside = CorpusLocation.readOnlyRoot
        .appendingPathComponent("must-not-exist-\(UUID().uuidString)")
        .appendingPathComponent("presentations.jsonl")
    #expect(throws: EventStoreError.self) {
        _ = try FilePresentationRecordStore(url: inside)
    }
    #expect(!FileManager.default.fileExists(atPath: inside.path))
}

// MARK: - #33 verify HIGH：非 null 的比較，以及「compare 真的讀了歷史」

/// 種一段真的使用歷史，讓 `human-like` 與 `archival` 產出**不同**的順序。
///
/// ## 這條測試補的是什麼洞
///
/// #33 的 verify（devil's advocate lens）實測：把 `compare` 裡讀歷史的那一行
/// 改成「永遠不讀、永遠不擴散」，**367 條測試全綠**。原因是先前所有 compare
/// 測試都跑在空事件檔上——零歷史時三個策略逐字相同，走不走讀歷史的分支輸出
/// 一樣。於是這個 change 的功能核心（讓使用歷史影響其中一邊的順序）零覆蓋。
///
/// 同時它也是 design 驗收準則 1 的正面半邊：「a persisted presentation record
/// **whose attribution names both strategies**」。null comparison 的
/// `creditedTo` 全是 nil，所以那句話只有在非 null 的呈現上才驗得到。
///
/// 種歷史的作法沿用 `LTMServiceTests` 既有的那條（deliberate `.cited` 事件，
/// 不是 `shown`——shown 只計 impressions、不進 netStrength）。
@Test("有使用歷史時比較是非 null 的：逐位置歸屬具名兩個策略，且兩邊都貢獻了位置")
func aComparisonWithRealHistoryIsAttributedToBothStrategies() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: [
        "記憶策略可插拔", "檢索基線量測", "第三段內容", "第四段內容", "第五段內容",
    ])
    let service = try workspace.comparisonService()
    try service.build()

    // 先取候選，給**最後一名**寫強歷史——它應該被 human-like 往上帶。
    let baseline = try service.query(text: "內容", limit: 10, scope: .allProjects)
    #expect(baseline.hits.count >= 3, "前提：同帶內要有多個候選才有得重排")
    let promoted = baseline.hits[baseline.hits.count - 1].anchor
    let store = try FileEventStore(url: workspace.eventsURL)
    for _ in 0..<3 {
        try store.append(
            Event(
                kind: .cited, anchor: promoted,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                generation: GenerationID("g-test"), policy: RankingPolicyID("human-like"),
                noteRef: nil, presentation: nil))
    }

    let outcome = try service.compare(
        text: "內容", limit: 10, scope: .allProjects, a: comparisonPair.a, b: comparisonPair.b)

    // 1. 兩邊順序不同 → 非 null comparison。
    #expect(
        !outcome.record.isNullComparison,
        "種了歷史之後 human-like 應該重排；若這裡是 null，代表 compare 沒把歷史接進 projection")

    // 2. 驗收準則 1 的正面半邊：每一個位置都具名記在某一邊。
    #expect(outcome.record.attribution.allSatisfy { $0.creditedTo != nil })
    let credited = Set(outcome.record.attribution.compactMap(\.creditedTo))
    #expect(
        credited == [comparisonPair.a, comparisonPair.b],
        "team-draft 應該讓兩邊都貢獻位置；只有一邊代表輪替沒發生")

    // 3. 落地之後餵給計分端，事件被歸屬而不是被當成 null 整批略過。
    let records = try FilePresentationRecordStore(url: workspace.recordsURL).allRecords()
    let events = try FileEventStore(url: workspace.eventsURL).allEvents()
    let report = try ComparisonScorer.report(records: records, events: events)
    #expect(report.skipped.presentationNotTracked == 0)
    #expect(report.skipped.fromNullComparison == 0, "非 null 的呈現不得被當成 null 略過")
}

/// 呈現之後才發生的互動，必須能被計分——而不是讓 scorer 以 generation 不符拋錯。
///
/// #33 verify：generation 先前是 `g-<當下秒數>`，於是任何**事後**寫入的事件必然
/// 帶不同的值，而 `ComparisonScorer` 對此是 `throw`（且那道 guard 排在
/// null-comparison 檢查之前）。也就是說：交錯比較存在的全部理由——事後的互動
/// ——會讓整份報告一個數字都產不出來。當時測不到，是因為所有測試的事件與紀錄
/// 都在同一次 `compare` 呼叫裡用同一個 `now` 寫成。
@Test("呈現之後才寫入的互動事件仍能計分——generation 綁索引而不是綁當下時間")
func aLaterInteractionOnAPresentationStillScores() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: [
        "記憶策略可插拔", "檢索基線量測", "第三段內容", "第四段內容", "第五段內容",
    ])
    let service = try workspace.comparisonService()
    try service.build()

    let store = try FileEventStore(url: workspace.eventsURL)
    let baseline = try service.query(text: "內容", limit: 10, scope: .allProjects)
    let promoted = baseline.hits[baseline.hits.count - 1].anchor
    for _ in 0..<3 {
        try store.append(
            Event(
                kind: .cited, anchor: promoted,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                generation: GenerationID("g-test"), policy: RankingPolicyID("human-like"),
                noteRef: nil, presentation: nil))
    }

    let presentedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let outcome = try service.compare(
        text: "內容", limit: 10, scope: .allProjects,
        a: comparisonPair.a, b: comparisonPair.b, now: presentedAt)
    #expect(!outcome.record.isNullComparison, "前提：要有非 null 的呈現才有得計分")

    // 使用者在**一小時後**點開其中一筆。generation 必須仍然對得上。
    let opened = outcome.hits[0].anchor
    try store.append(
        Event(
            kind: .opened, anchor: opened, timestamp: presentedAt.addingTimeInterval(3600),
            generation: outcome.record.generation, policy: RankingPolicyID("interleaved"),
            noteRef: nil, presentation: outcome.record.id))

    let records = try FilePresentationRecordStore(url: workspace.recordsURL).allRecords()
    let events = try FileEventStore(url: workspace.eventsURL).allEvents()
    // 先前這一行會 throw generationMismatch。
    let report = try ComparisonScorer.report(records: records, events: events)
    #expect(report.skipped.presentationNotTracked == 0)
    let creditTotal = report.classRows.flatMap(\.scores.values).reduce(0) { $0 + $1.credits }
    #expect(creditTotal == 1, "事後的那一次 opened 必須被記到某一邊頭上")
}

/// generation 綁的是**索引這一代**，不是呼叫的時刻。
///
/// ## 這條測試存在，是因為上面那條鎖不住它
///
/// `aLaterInteractionOnAPresentation` 拿 `outcome.record.generation` 去寫事後的
/// 事件——不論 generation 怎麼導出，兩邊都必然相等，所以它**永遠不會紅**。實測：
/// 把導出方式改回 `g-<當下秒數>`，369 條測試全綠。那正是 CLAUDE.md 記著的
/// 「不可能失敗的測試比沒有測試更糟」。
///
/// 真正的性質要下在**兩次不同時刻的呈現**上：同一份索引 → 同一代。這一條在
/// 秒數版本下必紅（兩次呼叫相隔一秒就換代），也順帶鎖住 spec 那條
/// 「跨 generation 要分開報」不會退化成每格 n=1。
@Test("同一份索引上、不同時刻的兩次比較，帶的是同一個 generation")
func generationIsBoundToTheIndexNotTheClock() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    let service = try workspace.comparisonService()
    try service.build()

    // 相隔一整天的兩次呈現。
    let first = try service.compare(
        text: "內容", limit: 10, scope: .allProjects,
        a: comparisonPair.a, b: comparisonPair.b,
        now: Date(timeIntervalSince1970: 1_800_000_000))
    let second = try service.compare(
        text: "內容", limit: 10, scope: .allProjects,
        a: comparisonPair.a, b: comparisonPair.b,
        now: Date(timeIntervalSince1970: 1_800_086_400))

    #expect(
        first.record.generation == second.record.generation,
        "同一份索引上的呈現必須同代；逐次換代會讓報告永遠宣稱 spans generations、每格 n=1")

    // 兩筆紀錄一起餵給計分端時不得被判成跨 generation。
    let records = try FilePresentationRecordStore(url: workspace.recordsURL).allRecords()
    #expect(records.count == 2)
    let report = try ComparisonScorer.report(
        records: records, events: try FileEventStore(url: workspace.eventsURL).allEvents())
    #expect(!report.spansGenerations)
}

// MARK: - #36 階段 1：(E) 契約補登

@Test("interleaved 是保留值，不是策略——它不得出現在 StrategyRegistry.known")
func theInterleavedPolicyIsReservedAndNotAStrategy() {
    // `memory-events` spec 把 `policy` 描述成「naming the strategy in force」，而
    // 交錯比較裡**沒有**單一 in-force strategy。寫 `"interleaved"` 這個選擇本身是
    // 誠實的（它沒謊稱來自 archival），但它必須是**保留值**而不是策略識別碼。
    //
    // 這條測試釘住那個區分：值域一旦被寫進 spec，下一個人可能拿它去 `make()`，
    // 而那會靜默回 `nil`。
    #expect(
        !StrategyRegistry.known.contains(LTMService.interleavedPolicy.value),
        "interleaved 進了 known 會讓它看起來像一檔可選的策略")
    #expect(
        StrategyRegistry.make(LTMService.interleavedPolicy) == nil,
        "它組不出實例——因為它不是策略")
    #expect(
        StrategyRegistry.authorizedConstraints(for: LTMService.interleavedPolicy) == nil,
        "它也沒有授權條目——seam 會具名拒絕任何自稱是它的 conformer")
}

@Test("零命中的比較不留呈現紀錄——沒有位置 0 就沒有 starting side")
func aComparisonWithNoCandidatesRecordsNothing() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    // **空索引**，不是「查一個不相干的字串」。寫這條測試時先試了後者，它失敗了
    // ——而失敗本身有資訊：向量通道對**任何**查詢都回 top-k（餘弦沒有門檻），
    // 所以只要索引裡有東西，候選就不會是空的。零命中實際只在索引為空、或 scope
    // 把所有東西濾掉時可達。斷言要下在真的能發生的情境上。
    let service = try workspace.comparisonService()
    try service.build()

    let outcome = try service.compare(
        text: "記憶策略", limit: 20, scope: .allProjects,
        a: comparisonPair.a, b: comparisonPair.b)

    #expect(outcome.hits.isEmpty)
    #expect(outcome.eventsRecorded == 0)
    #expect(
        !FileManager.default.fileExists(atPath: workspace.recordsURL.path),
        "沒有東西被呈現，就不該有呈現紀錄——那種列會用『沒有起始邊』稀釋 startingSides 的分母")
}
