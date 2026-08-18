import Foundation
import SQLite3
import Testing

@testable import LTMCore
@testable import LTMIndex

/// 合成 embedding provider。
///
/// 用它而不是真的 `NLContextualEmbedding`：模型 assets 不一定在（CI、剛裝好的
/// 機器），而「向量從哪來」不是這些測試要驗的東西——要驗的是 revision 變動如何
/// 作廢索引、向量筆數與 chunk 是否對得上。真實 provider 的行為由它自己的
/// 型別負責。
struct StubEmbedder: EmbeddingProvider {
    var revision: String
    var dimension: Int = 4
    /// 產不出向量的文字（測 `vector_row` 為 NULL 的路徑）。
    var refusing: Set<String> = []

    func vector(for text: String) throws -> [Float]? {
        guard !refusing.contains(text) else { return nil }
        // 內容**與 revision** 共同決定向量。
        //
        // 先前只看內容，於是「換 revision → 索引重建」的測試證明不了任何事：
        // 重建前後的向量位元相同，測試就算沒重建也會通過。revision 進 seed 之後，
        // 舊向量若沒被替換，值就會對不上。
        var seed = Float(abs((text + revision).hashValue % 1000)) / 1000
        return (0..<dimension).map { _ in
            seed = (seed * 1.7).truncatingRemainder(dividingBy: 1)
            return seed
        }
    }
}

private struct AllowAllPolicy: CorpusContainmentPolicy {
    func isInsideReadOnlyCorpus(_ url: URL) -> Bool { false }
}

/// 一組臨時的語料根 + 衍生根。
private func makeWorkspace() throws -> (corpus: URL, derived: DerivedLocation) {
    let corpus = try makeFixtureCorpus()
    let derivedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-derived-\(UUID().uuidString)")
    return (corpus, try DerivedLocation(root: derivedRoot, policy: AllowAllPolicy()))
}

private let session = "11111111-2222-3333-4444-555555555555"

private func writeTurns(in corpus: URL, project: String = "proj-one", texts: [String]) throws {
    var lines: [String] = []
    for (index, text) in texts.enumerated() {
        lines.append(
            turnLine(
                uuid: String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", index),
                session: session, role: index.isMultiple(of: 2) ? "user" : "assistant", text: text))
    }
    _ = try writeSession(in: corpus, project: project, file: "session.jsonl", lines: lines)
}

@Test("建置後向量筆數等於有向量的 chunk 數")
func vectorCountMatchesChunkCount() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容", "第二段內容", "第三段內容"])

    let builder = IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus),
        embedder: StubEmbedder(revision: "rev-A"))
    let report = try builder.build()

    #expect(report.totalChunks == 3)
    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    #expect(try database.meta("vector_count") == "3")

    // 側車檔的長度要與宣稱的筆數一致——不一致代表某一次中止留下了殘骸。
    let sidecar = try VectorSidecar.open(url: derived.vectorsURL, dimension: 4)
    #expect(sidecar.count == 3)
    #expect(sidecar.vector(at: 0)?.count == 4)
    #expect(sidecar.vector(at: 3) == nil)
}

@Test("產不出向量的 chunk 仍然進索引，只是沒有 vector_row")
func chunkWithoutVectorStaysIndexed() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["有向量的內容", "沒有向量的內容"])

    let builder = IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus),
        embedder: StubEmbedder(revision: "rev-A", refusing: ["沒有向量的內容"]))
    let report = try builder.build()

    #expect(report.totalChunks == 2)
    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    #expect(try database.meta("vector_count") == "1")
    var withoutVector = 0
    try database.query("SELECT COUNT(*) FROM chunks WHERE vector_row IS NULL") { statement in
        withoutVector = Int(sqlite3_column_int64(statement, 0))
    }
    #expect(withoutVector == 1, "沒有向量的 chunk 應該仍在 lexical 通道裡")
}

@Test("embedding revision 變動使整份索引重建，不混用兩代向量")
func revisionChangeForcesFullRebuild() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容", "第二段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus)

    let first = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()
    #expect(first.wasFullRebuild)  // 第一次本來就是從零

    // 同一個 revision 再建一次：增量，沒有新內容 → 沒有新 chunk。
    let second = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()
    #expect(!second.wasFullRebuild)
    #expect(second.chunksIndexed == 0)
    #expect(second.totalChunks == 2)

    // 換 revision：必須整份重建，且向量筆數不能疊加成 4。
    let third = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-B")
    ).build()
    #expect(third.wasFullRebuild)
    #expect(third.totalChunks == 2)
    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    #expect(try database.meta("vector_count") == "2", "跨 revision 的向量疊加會讓距離失去意義")
    #expect(try database.stamps().embeddingRevision == "rev-B")
    // 舊向量必須真的被**替換**，不只是筆數對。revision 進了 seed，所以值會不同。
    let sidecar = try VectorSidecar.open(url: derived.vectorsURL, dimension: 4)
    let rebuilt = sidecar.vector(at: 0)
    let underOldRevision = try StubEmbedder(revision: "rev-A").vector(for: "第一段內容")
    #expect(rebuilt != underOldRevision, "側車裡仍是舊 revision 算出的向量 —— 重建沒有真的發生")
}

@Test("鎖被持有時第二個建置立刻失敗，不無限等待")
func concurrentBuildIsRefused() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["內容"])
    try derived.createRootIfNeeded()

    // 手動持鎖，模擬另一個正在跑的建置。
    let held = try FileLock.acquire(at: derived.lockURL)
    defer { held.release() }

    let builder = IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus),
        embedder: StubEmbedder(revision: "rev-A"))
    #expect(throws: IndexBuilder.BuildError.self) {
        _ = try builder.build()
    }
}

@Test("建置完成後鎖被釋放，下一次建置拿得到")
func lockIsReleasedAfterBuild() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["內容"])
    let scanner = CorpusScanner(corpusRoot: corpus)

    _ = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()
    #expect(!FileManager.default.fileExists(atPath: derived.lockURL.path))
    // 再跑一次不該因為殘留的鎖而失敗。
    _ = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()
}

@Test("側車檔殘骸在下一次建置被截掉，row 編號不會錯開")
func staleSidecarBytesAreTruncated() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus)
    _ = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()

    // 模擬「上一輪寫到一半被中止」：檔案比 vector_count 記錄的長。
    let handle = try FileHandle(forWritingTo: derived.vectorsURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0xFF, count: 4 * MemoryLayout<Float>.size))
    try handle.close()

    // 加一則新內容後再建置：殘骸該被截掉，新向量接在正確的位置。
    try writeTurns(in: corpus, texts: ["第一段內容", "第二段內容"])
    _ = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()

    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    let declared = try database.meta("vector_count").flatMap(Int.init) ?? -1
    let sidecar = try VectorSidecar.open(url: derived.vectorsURL, dimension: 4)
    #expect(sidecar.count == declared, "側車檔筆數與索引宣稱的筆數必須一致")
}

@Test("state 遺失而索引存在時丟出 stateUnreadable，不在舊索引上疊加")
func missingStateWithExistingIndexIsRefused() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus)
    _ = try IndexBuilder(location: derived, scanner: scanner,
                         embedder: StubEmbedder(revision: "rev-A")).build()

    // state 不見了，但 DB 還在——先前這會被當成空 state、重掃全語料 upsert。
    try FileManager.default.removeItem(at: derived.stateURL)

    #expect(throws: IndexBuilder.BuildError.self) {
        _ = try IndexBuilder(location: derived, scanner: scanner,
                             embedder: StubEmbedder(revision: "rev-A")).build()
    }
    // --full 仍然可用（那正是錯誤訊息指引的路）。
    let recovered = try IndexBuilder(location: derived, scanner: scanner,
                                     embedder: StubEmbedder(revision: "rev-A")).build(full: true)
    #expect(recovered.wasFullRebuild)
}

// MARK: - 刪檔作廢 × 去重的交互作用（round-2 verify HIGH）
//
// 去重把「同一則 turn 出現在多個檔」收斂成一列，而作廢的粒度是 `source_key`
// ——一列只記得住一個。兩個機制各自正確，交互作用不正確。

@Test("刪掉重複來源之一，不得刪掉另一個來源仍然持有的 turn")
func deletingOneResumeCopyKeepsTheTurn() throws {
    let workspace = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: workspace.corpus)
        try? FileManager.default.removeItem(at: workspace.derived.root)
    }
    // 同一則 turn（同 uuid、同內容）出現在兩個檔——這正是 session resume
    // 在真實語料裡的樣子（實測 300 檔 5,722 筆）。
    let uuid = "0000ffff-aaaa-bbbb-cccc-dddddddddddd"
    let text = "這一則會出現在兩個 session 檔裡"
    _ = try writeSession(
        in: workspace.corpus, project: "proj-one", file: "a.jsonl",
        lines: [turnLine(uuid: uuid, session: "aaaaaaaa-1111-1111-1111-111111111111",
                         role: "user", text: text)])
    let laterFile = try writeSession(
        in: workspace.corpus, project: "proj-one", file: "b.jsonl",
        lines: [turnLine(uuid: uuid, session: "bbbbbbbb-2222-2222-2222-222222222222",
                         role: "user", text: text)])

    let embedder = StubEmbedder(revision: "r1")
    func builder() -> IndexBuilder {
        IndexBuilder(
            location: workspace.derived,
            scanner: CorpusScanner(corpusRoot: workspace.corpus), embedder: embedder)
    }
    #expect(try builder().build().totalChunks == 1, "去重之後只該有一列")

    // 刪掉勝出的那個來源檔。另一個檔**沒有變動**，所以增量掃描不會重新產出它。
    try FileManager.default.removeItem(at: laterFile)
    let report = try builder().build()

    #expect(
        report.totalChunks == 1,
        "turn 仍然存在於 a.jsonl；把它從索引刪掉會讓增量結果與全量重建不同（不變式 2）")
}
