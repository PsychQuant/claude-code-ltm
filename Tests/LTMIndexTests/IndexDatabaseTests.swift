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
    sourceKey: String = "proj-one/session.jsonl",
    session: String = "11111111-2222-3333-4444-555555555555",
    timestamp: TimeInterval = 1_760_000_000
) -> CorpusChunk {
    let when = Date(timeIntervalSince1970: timestamp)
    let turn = Turn(id: uuid, role: "user", timestamp: when, text: text)
    return CorpusChunk(
        sourceKey: sourceKey, project: project, sessionID: session, uuid: uuid,
        timestamp: when, role: "user", text: text,
        // source 是 project 指紋，不是 session——與 CorpusScanner 的實際行為一致。
        anchor: Anchor(source: ProjectFingerprint.of(project), turn: turn,
                       span: 0..<text.unicodeScalars.count))
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

@Test("同一則 turn 經由兩個 session 檔寫入時只留一個 chunk")
func resumeDuplicateYieldsSingleChunk() throws {
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    try db.probeTokenizers()
    try db.createSchema()

    let uuid = "aaaaaaaa-0000-0000-0000-000000000001"
    let text = "跨越 resume 的同一段內容"
    // 先寫 session-A 觀察到的版本，再寫 session-B（resume）觀察到的同一則 turn。
    try db.insert(
        chunks: [makeChunk(uuid: uuid, text: text, session: "11111111-1111-1111-1111-111111111111",
                           timestamp: 1_760_000_000)],
        sourceKey: "proj-one/session-A.jsonl")
    try db.insert(
        chunks: [makeChunk(uuid: uuid, text: text, session: "22222222-2222-2222-2222-222222222222",
                           timestamp: 1_760_000_100)],
        sourceKey: "proj-one/session-B.jsonl")

    #expect(try db.chunkCount() == 1, "resume 複製的同一則 turn 是一段記憶，不是兩段")

    // 先前這裡還斷言 `chunks.session_id == "2222…"`（「pointer 應報最近觀察到的
    // session」）。那個欄位與那條規則都在 #25／layout 5 移除了——「最近觀察到」
    // 在真實語料裡永遠平手，實際由檔名字典序決定。兩個來源都保留的性質由
    // `identicalTimestampsYieldBothSources` 鎖住（且用的是**相同**時間戳，
    // 也就是真實語料裡真正會發生的那個分支）。
}

@Test("時間戳完全相同的兩份 resume 複製，來源集合含兩個 session——不是字典序挑一個")
func identicalTimestampsYieldBothSources() throws {
    // #25 的核心：resume 複製**不改訊息時間戳**，所以真實語料裡時間戳永遠平手，
    // 勝負實際由 source_key 字典序決定。上面那條 `resumeDuplicateYieldsSingleChunk`
    // 刻意給了不同時間戳（...000 / ...100），驗的是真實語料中不會發生的分支——
    // 這條補上真正會發生的那個。
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    try db.probeTokenizers()
    try db.createSchema()

    let uuid = "aaaaaaaa-0000-0000-0000-000000000002"
    let text = "時間戳相同的 resume 複製內容"
    let sameTimestamp: TimeInterval = 1_760_000_000
    let sessionA = "11111111-1111-1111-1111-111111111111"
    let sessionB = "22222222-2222-2222-2222-222222222222"

    try db.insert(
        chunks: [makeChunk(uuid: uuid, text: text, session: sessionA, timestamp: sameTimestamp)],
        sourceKey: "proj-one/session-A.jsonl")
    try db.insert(
        chunks: [makeChunk(uuid: uuid, text: text, session: sessionB, timestamp: sameTimestamp)],
        sourceKey: "proj-one/session-B.jsonl")

    #expect(try db.chunkCount() == 1, "同一則 turn 仍是一段記憶")

    var chunkID: Int64 = 0
    try db.query("SELECT id FROM chunks") { statement in
        chunkID = sqlite3_column_int64(statement, 0)
    }

    let sources = try db.sessionSources(chunkIDs: [chunkID])
    let sessions = sources[chunkID] ?? []
    #expect(
        sessions == [sessionA, sessionB],
        "兩個來源都要回傳（依 source_key 字典序），而不是挑一個；實得 \(sessions)")
}

@Test("只被一份檔持有的 turn，來源集合恰好一個元素")
func singleSourceYieldsSingleEntry() throws {
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    try db.probeTokenizers()
    try db.createSchema()

    let session = "33333333-3333-3333-3333-333333333333"
    try db.insert(
        chunks: [makeChunk(uuid: "aaaaaaaa-0000-0000-0000-000000000003",
                           text: "只出現在一份檔案裡的內容", session: session)],
        sourceKey: "proj-one/only.jsonl")

    var chunkID: Int64 = 0
    try db.query("SELECT id FROM chunks") { statement in
        chunkID = sqlite3_column_int64(statement, 0)
    }

    let sources = try db.sessionSources(chunkIDs: [chunkID])
    #expect(sources[chunkID] == [session])
}

@Test("不同 project 的相同 turn 識別碼各自成立，不互相覆蓋")
func sameUUIDInDifferentProjectsStaysSeparate() throws {
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    try db.probeTokenizers()
    try db.createSchema()

    let uuid = "aaaaaaaa-0000-0000-0000-000000000001"
    try db.insert(chunks: [makeChunk(uuid: uuid, text: "甲專案的內容", project: "proj-one")],
                  sourceKey: "proj-one/s.jsonl")
    try db.insert(chunks: [makeChunk(uuid: uuid, text: "乙專案的內容", project: "proj-two")],
                  sourceKey: "proj-two/s.jsonl")

    // 實測顯示跨 project 的 uuid 重複為零，但那是對外來資料的觀察、不是 schema 能保證的事。
    #expect(try db.chunkCount() == 2)
}

@Test("同一則 turn 內容被改寫後，舊文字不再命中（upsert 路徑）")
func upsertRemovesStaleFTSRows() throws {
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    try db.probeTokenizers()
    try db.createSchema()

    let uuid = "aaaaaaaa-0000-0000-0000-000000000001"
    try db.insert(chunks: [makeChunk(uuid: uuid, text: "改寫前的獨特內容")],
                  sourceKey: "proj-one/s.jsonl")
    // 同一則 turn 的內容被修正（例如來源被重寫後重掃）。
    try db.insert(chunks: [makeChunk(uuid: uuid, text: "改寫後的全新內容")],
                  sourceKey: "proj-one/s.jsonl")

    #expect(try db.chunkCount() == 1)
    var stale = 0
    try db.query("SELECT rowid FROM chunks_trigram WHERE chunks_trigram MATCH ?",
                 bind: [.text("改寫前")]) { _ in stale += 1 }
    #expect(stale == 0, "upsert 未清舊 FTS 列 ⇒ 檢索安靜地回舊文字（contentless 表不會報錯）")
    var fresh = 0
    try db.query("SELECT rowid FROM chunks_trigram WHERE chunks_trigram MATCH ?",
                 bind: [.text("改寫後")]) { _ in fresh += 1 }
    #expect(fresh == 1)
}

@Test("含內嵌 NUL 的文字不被截斷，索引內容與 anchor 一致")
func embeddedNulSurvivesRoundTrip() throws {
    let path = makeTempDatabasePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let db = try IndexDatabase(path: path)
    try db.probeTokenizers()
    try db.createSchema()

    // JSON 字串合法地可以含 U+0000（工具輸出、二進位轉義）。
    let text = "前半段" + String(UnicodeScalar(0)!) + "後半段的獨特內容"
    let chunk = makeChunk(uuid: "aaaaaaaa-0000-0000-0000-000000000001", text: text)
    try db.insert(chunks: [chunk], sourceKey: "proj-one/s.jsonl")

    var stored = ""
    try db.query("SELECT text FROM chunks") { statement in stored = columnText(statement, 0) }
    #expect(stored == text,
            "bind_text(-1) 與 String(cString:) 會在 NUL 處截斷，使 DB 內容與 anchor 的 contentHash 不一致")
}
