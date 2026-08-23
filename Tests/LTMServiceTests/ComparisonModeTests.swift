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
            recordStore: try FilePresentationRecordStore(url: recordsURL))
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
        eventStore: try FileEventStore(url: workspace.eventsURL), recordStore: nil)
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
