import Foundation
import Testing

@testable import LTMCore
@testable import LTMIndex
@testable import LTMMemory
@testable import LTMQuery
@testable import LTMService

// 全部走合成語料。真實 `~/.claude/projects/` 在這些測試裡一次都沒被碰到——
// 隱私邊界之外，那樣的測試也不可重現（語料每天都在長）。

struct FixedEmbedder: EmbeddingProvider {
    var revision: String = "test-rev-1"
    var dimension: Int = 8

    func vector(for text: String) throws -> [Float]? {
        // 依內容決定的確定性向量：同文字同向量，方便斷言可重現性。
        var value = Float(abs(text.hashValue % 997)) / 997
        var out: [Float] = []
        for _ in 0..<dimension {
            value = (value * 2.3).truncatingRemainder(dividingBy: 1)
            out.append(value)
        }
        let norm = sqrt(out.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? out.map { $0 / norm } : nil
    }
}

private struct AllowAll: CorpusContainmentPolicy {
    func isInsideReadOnlyCorpus(_ url: URL) -> Bool { false }
}

private let testSession = "11111111-2222-3333-4444-555555555555"

private func turnRecord(index: Int, text: String, session: String = testSession) -> String {
    let object: [String: Any] = [
        "type": index.isMultiple(of: 2) ? "user" : "assistant",
        "uuid": String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", index),
        "sessionId": session,
        "timestamp": "2026-08-17T06:00:00.000Z",
        "message": ["role": index.isMultiple(of: 2) ? "user" : "assistant", "content": text],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

/// 一組工作區：合成語料 + 衍生根 + 事件檔。
struct Workspace {
    let corpus: URL
    let derived: DerivedLocation
    let eventsURL: URL

    static func make() throws -> Workspace {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltm-svc-\(UUID().uuidString)")
        let corpus = base.appendingPathComponent("corpus")
        let derivedRoot = base.appendingPathComponent("derived")
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        return Workspace(
            corpus: corpus,
            derived: try DerivedLocation(root: derivedRoot, policy: AllowAll()),
            eventsURL: base.appendingPathComponent("events.jsonl"))
    }

    func writeSession(project: String = "proj-one", file: String = "s.jsonl", texts: [String])
        throws
    {
        let dir = corpus.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = texts.enumerated().map { turnRecord(index: $0.offset, text: $0.element) }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    func service(embedder: FixedEmbedder = FixedEmbedder(), withEvents: Bool = false) throws
        -> LTMService
    {
        LTMService(
            location: derived, corpusRoot: corpus, embedder: embedder,
            eventStore: withEvents ? try FileEventStore(url: eventsURL) : nil)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: corpus.deletingLastPathComponent())
    }
}

// MARK: - Task 3.2：facade 的 staleness 與策略契約

@Test("預設策略是 archival：順序等於純檢索順序，每一筆位移都是零")
func defaultStrategyLeavesRetrievalOrderIntact() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["記憶策略的比較軸", "檢索基線量測", "另一段內容"])
    let service = try workspace.service()
    try service.build()

    let outcome = try service.query(text: "記憶策略", limit: 10, scope: .allProjects)

    #expect(!outcome.hits.isEmpty)
    #expect(outcome.strategyID == "archival")
    #expect(outcome.hits.allSatisfy { $0.displacement == 0 })
    // band 是融合名次，archival 不動它 → 依序遞增。
    #expect(outcome.hits.map(\.band) == Array(0..<outcome.hits.count))
}

@Test("embedding revision 不符時拒答，且錯誤指名 ltm build")
func revisionMismatchRefusesTheQuery() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["內容一", "內容二"])
    try workspace.service(embedder: FixedEmbedder(revision: "rev-old")).build()

    // 換一個 revision 的 runtime 來查：不得回傳任何結果。
    let newService = try workspace.service(embedder: FixedEmbedder(revision: "rev-new"))
    var thrown: Error?
    do {
        _ = try newService.query(text: "內容", limit: 10, scope: .allProjects)
    } catch {
        thrown = error
    }
    guard case .some(LTMService.ServiceError.embeddingRevisionMismatch(let indexed, let runtime)) =
        thrown as? LTMService.ServiceError
    else {
        Issue.record("跨 revision 查詢必須拒答，實際拋出：\(String(describing: thrown))")
        return
    }
    #expect(indexed == "rev-old")
    #expect(runtime == "rev-new")
}

@Test("索引不存在時明確失敗，不回空結果")
func missingIndexIsAnErrorNotAnEmptyResult() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["內容"])
    let service = try workspace.service()

    #expect(throws: LTMService.ServiceError.self) {
        _ = try service.query(text: "內容", limit: 10, scope: .allProjects)
    }
}

@Test("查詢時語料前進 → 先併進索引再回答")
func queryPicksUpAppendedCorpusContent() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["最初的內容"])
    let service = try workspace.service()
    try service.build()

    // 語料多了一則，但沒有重新 build。
    try workspace.writeSession(texts: ["最初的內容", "後來補上的關鍵內容"])

    let outcome = try service.query(text: "後來補上", limit: 10, scope: .allProjects)

    #expect(outcome.refreshedSources > 0, "查詢應該先把新內容併進索引")
    #expect(outcome.hits.contains { $0.snippet.contains("後來補上") })
}

@Test("每一筆命中都帶齊四欄指標")
func everyHitCarriesPointer() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["指標完整性的驗證內容"])
    let service = try workspace.service()
    try service.build()

    let outcome = try service.query(text: "指標完整性", limit: 10, scope: .allProjects)
    #expect(!outcome.hits.isEmpty)
    for hit in outcome.hits {
        #expect(!hit.project.isEmpty)
        #expect(!hit.sessionID.isEmpty)
        #expect(!hit.uuid.isEmpty)
        #expect(hit.timestamp.timeIntervalSince1970 > 0)
    }
}

// MARK: - Task 3.3：不變式 2 的等價性

@Test("不變式 2：刪掉衍生目錄重建後，同樣的查詢回同樣的結果")
func rebuildFromScratchIsResultEquivalent() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(
        texts: ["記憶策略可插拔", "檢索基線的量測", "第三段無關內容", "第四段其他內容"])
    let service = try workspace.service()
    try service.build()

    let queries = ["記憶策略", "量測", "內容"]
    let before = try queries.map { query in
        try service.query(text: query, limit: 10, scope: .allProjects).hits.map(\.uuid)
    }

    // 整個衍生目錄刪掉，從零重建。
    try FileManager.default.removeItem(at: workspace.derived.root)
    try service.build()

    let after = try queries.map { query in
        try service.query(text: query, limit: 10, scope: .allProjects).hits.map(\.uuid)
    }

    #expect(before == after, "索引是純衍生物：重建後結果必須完全一致")
    #expect(before.contains { !$0.isEmpty }, "測試本身要有命中才有意義")
}

@Test("不變式 2：增量建置與全量重建結果等價")
func incrementalBuildEqualsFullRebuild() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["第一段內容", "第二段內容"])
    let service = try workspace.service()
    try service.build()

    // 追加內容後走增量。
    try workspace.writeSession(texts: ["第一段內容", "第二段內容", "第三段新內容"])
    try service.build()
    let incremental = try service.query(text: "內容", limit: 10, scope: .allProjects).hits.map(\.uuid)

    // 同一份語料從零重建。
    try service.build(full: true)
    let full = try service.query(text: "內容", limit: 10, scope: .allProjects).hits.map(\.uuid)

    #expect(incremental == full)
    #expect(incremental.count == 3)
}

@Test("建置與查詢都不寫語料")
func buildAndQueryLeaveCorpusUntouched() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["語料唯讀的驗證內容"])
    let sessionFile = workspace.corpus.appendingPathComponent("proj-one/s.jsonl")
    let before = try Data(contentsOf: sessionFile)
    let beforeEntries = try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path)

    let service = try workspace.service()
    try service.build()
    _ = try service.query(text: "語料唯讀", limit: 10, scope: .allProjects)

    #expect(try Data(contentsOf: sessionFile) == before)
    #expect(
        try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path).sorted()
            == beforeEntries.sorted(), "語料樹不得多出或少掉任何項目")
}
