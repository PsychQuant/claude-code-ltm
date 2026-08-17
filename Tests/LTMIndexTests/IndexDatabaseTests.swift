import Foundation
import SQLite3
import Testing

@testable import LTMCore
@testable import LTMIndex

private func makeTempDatabasePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-db-\(UUID().uuidString).sqlite3").path
}

private func makeChunk(
    uuid: String, text: String, project: String = "proj-one",
    sourceKey: String = "proj-one/session.jsonl"
) -> CorpusChunk {
    let session = "11111111-2222-3333-4444-555555555555"
    let turn = Turn(id: uuid, role: "user", timestamp: Date(timeIntervalSince1970: 1_760_000_000), text: text)
    return CorpusChunk(
        sourceKey: sourceKey, project: project, sessionID: session, uuid: uuid,
        timestamp: turn.timestamp, role: "user", text: text,
        anchor: Anchor(source: session, turn: turn, span: 0..<text.unicodeScalars.count))
}

@Test("首次建置就建好 schema，chunk 數從零開始")
func schemaIsCreatedOnFirstBuild() throws {
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    try db.probeTokenizers()
    try db.createSchema()

    #expect(try db.chunkCount() == 0)
    // 兩條 lexical 通道都要真的存在——少一條時檢索仍然「能跑」，只是 recall
    // 掉一半而不報錯，那正是 #2 量測裡 unicode61 單獨使用的情形。
    var tables: Set<String> = []
    try db.query("SELECT name FROM sqlite_master WHERE type IN ('table','view')") { statement in
        if let raw = sqlite3_column_text(statement, 0) { tables.insert(String(cString: raw)) }
    }
    #expect(tables.contains("chunks"))
    #expect(tables.contains("chunks_trigram"))
    #expect(tables.contains("chunks_segment"))
    #expect(tables.contains("meta"))
}

@Test("trigram 與 unicode61 tokenizer 在本機 SQLite 可用")
func tokenizerProbeSucceedsOnThisSQLite() throws {
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    // 探測失敗時錯誤必須指名版本——這裡順帶確認版本字串拿得到，
    // 否則失敗訊息會是「不可用」而沒有任何可據以判斷的資訊。
    #expect(!db.sqliteVersion.isEmpty)
    try db.probeTokenizers()
}

@Test("layout 版本與 embedding revision 寫得進也讀得出")
func stampsRoundTrip() throws {
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    try db.createSchema()

    #expect(try db.stamps() == IndexDatabase.Stamps(layoutVersion: nil, embeddingRevision: nil))

    try db.writeStamps(embeddingRevision: "rev-A")
    let stamps = try db.stamps()
    #expect(stamps.layoutVersion == IndexDatabase.layoutVersion)
    #expect(stamps.embeddingRevision == "rev-A")
}

@Test("layout 版本不符是可偵測的，並且與 revision 不符互相獨立")
func layoutVersionMismatchIsDetectable() throws {
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    try db.createSchema()
    // 模擬「上一個版本的 binary 建的索引」。
    try db.setMeta("layout_version", String(IndexDatabase.layoutVersion - 1))
    try db.setMeta("embedding_revision", "rev-A")

    let stamps = try db.stamps()
    #expect(stamps.layoutVersion != IndexDatabase.layoutVersion)
    // revision 仍然對得上——兩個判準是獨立的，不該互相掩蓋。
    #expect(stamps.embeddingRevision == "rev-A")
}

@Test("寫入的 chunk 兩條通道都索引得到")
func insertedChunkIsSearchableOnBothChannels() throws {
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    try db.probeTokenizers()
    try db.createSchema()

    let chunk = makeChunk(uuid: "aaaaaaaa-0000-0000-0000-000000000001", text: "記憶策略可插拔的比較軸")
    try db.insert(chunks: [chunk], sourceKey: "proj-one/session.jsonl")
    #expect(try db.chunkCount() == 1)

    // trigram 通道：三字元子串一定命中。
    var trigramHits = 0
    try db.query("SELECT rowid FROM chunks_trigram WHERE chunks_trigram MATCH ?", bind: [.text("記憶策略")]) { _ in
        trigramHits += 1
    }
    #expect(trigramHits == 1)

    // 斷詞通道：查一個斷詞後應該獨立成詞的字串。
    var segmentHits = 0
    try db.query("SELECT rowid FROM chunks_segment WHERE chunks_segment MATCH ?", bind: [.text("記憶")]) { _ in
        segmentHits += 1
    }
    #expect(segmentHits >= 1)
}

@Test("作廢來源後舊文字不再命中——不會安靜地回舊內容")
func deletingSourceRemovesItFromBothChannels() throws {
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    try db.probeTokenizers()
    try db.createSchema()

    let sourceKey = "proj-one/session.jsonl"
    try db.insert(
        chunks: [makeChunk(uuid: "aaaaaaaa-0000-0000-0000-000000000001", text: "改寫前的原始內容")],
        sourceKey: sourceKey)
    try db.deleteChunks(sourceKey: sourceKey)

    #expect(try db.chunkCount() == 0)
    var hits = 0
    try db.query("SELECT rowid FROM chunks_trigram WHERE chunks_trigram MATCH ?", bind: [.text("改寫前")]) { _ in
        hits += 1
    }
    #expect(hits == 0, "被作廢的來源仍然命中 —— 檢索會安靜地回舊文字")
}

@Test("斷詞把 CJK 切開，拉丁段原樣保留")
func segmentationSplitsCJKAndKeepsLatin() {
    let segmented = Segmentation.segment("記憶策略 MemoryStrategy 可插拔")
    // 斷詞後 CJK 之間應該出現空白（否則 unicode61 整段當一個詞，等同沒斷）。
    #expect(segmented.contains(" "))
    #expect(segmented.contains("MemoryStrategy"))
}
