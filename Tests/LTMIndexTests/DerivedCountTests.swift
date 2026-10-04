import Foundation
import SQLite3
import Testing

@testable import LTMCore
@testable import LTMIndex

// #61（gate-structural-counts）：`chunks.source_count` 與 `source_chunk_counts` 由 `chunk_sources` 上的
// trigger 維護，閘改讀它們。這個檔釘三件事：
//
// 1. 每一條出貨的寫入路徑之後，兩份計數都等於從 `chunk_sources` 重算的結果（不變式 2 的衍生資料版）；
// 2. 只有 trigger 寫它們、沒有 SQL 用 REPLACE 寫 `chunk_sources`——REPLACE 刪掉的列在預設
//    `recursive_triggers = OFF` 下不觸發 DELETE trigger（`/usr/bin/sqlite3` 3.54 實測：計數 2、實際 1）；
// 3. 閘的 Q1 走 partial index，不掃 `chunks`。
//
// 第 2 件是比對文字的檢查，**只認得 `derivedCountGuardsRecogniseTheirShapes` 列出的那些形狀**（含 schema
// 限定、加引號、別名、upsert 的 `DO UPDATE SET`、對 `chunks` 的 REPLACE）。認不得的：把 SQL 拆成多段字串
// 拼接或插值。raw string 不是漏洞——切詞器遇到它就拋錯，掃描變紅。真正界定計數正確的是第 1 件的等價測試；
// 這兩個掃描只是讓最常見的寫錯在掃描這一層就被指名（R1-7，#61 verify：上一版寫「擋得住一般的編輯」，
// 而最自然的一種——在 chunks 的 upsert 裡加 `source_count`——它認不得）。

// MARK: - 共用

private func makeTempDatabase() throws -> (IndexDatabase, cleanup: () -> Void) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-db-\(UUID().uuidString).sqlite3").path
    let db = try IndexDatabase(path: path)
    try db.probeTokenizers()
    try db.createSchema()
    // 連 -wal／-shm 一起刪（#72：只刪主檔會在 TMPDIR 留孤兒檔）。
    return (db, {
        db.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    })
}

private func turn(
    _ uuid: String, in sourceKey: String, text: String? = nil, project: String = "proj-one"
) -> CorpusChunk {
    let body = text ?? "內容 \(uuid)"
    let when = Date(timeIntervalSince1970: 1_760_000_000)
    let turn = Turn(id: uuid, role: "user", timestamp: when, text: body)
    return CorpusChunk(
        sourceKey: sourceKey, project: project, sessionID: "11111111-2222-3333-4444-555555555555",
        uuid: uuid, timestamp: when, role: "user", text: body,
        anchor: Anchor(source: ProjectFingerprint.of(project), turn: turn,
                       span: 0..<body.unicodeScalars.count, key: .forTesting))
}

/// 存著的計數與從 `chunk_sources` 重算的結果，逐列比對；回傳不一致的描述（空 = 一致）。
///
/// 也檢查「沒有任何列的來源在 `source_chunk_counts` 裡沒有一列」——重算的 GROUP BY 本來就不會產出它，
/// 所以兩張字典相等就涵蓋了這一條。
private func divergences(in db: IndexDatabase) throws -> [String] {
    var found: [String] = []
    try db.query(
        """
        SELECT c.uuid, c.source_count,
               (SELECT COUNT(*) FROM chunk_sources s WHERE s.chunk_id = c.id)
        FROM chunks c
        """
    ) { statement in
        let stored = sqlite3_column_int64(statement, 1)
        let actual = sqlite3_column_int64(statement, 2)
        if stored != actual {
            found.append("chunk \(text(statement, 0)): 存 \(stored)、重算 \(actual)")
        }
    }
    var stored: [String: Int64] = [:]
    try db.query("SELECT source_key, n FROM source_chunk_counts") { statement in
        stored[text(statement, 0)] = sqlite3_column_int64(statement, 1)
    }
    var actual: [String: Int64] = [:]
    try db.query("SELECT source_key, COUNT(*) FROM chunk_sources GROUP BY source_key") { statement in
        actual[text(statement, 0)] = sqlite3_column_int64(statement, 1)
    }
    if stored != actual { found.append("source_chunk_counts \(stored) ≠ 重算 \(actual)") }
    return found
}

private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
    sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
}

private func sourceCount(of uuid: String, in db: IndexDatabase) throws -> Int64? {
    var value: Int64?
    try db.query("SELECT source_count FROM chunks WHERE uuid = ?", bind: [.text(uuid)]) { statement in
        value = sqlite3_column_int64(statement, 0)
    }
    return value
}

private func sourceTable(_ db: IndexDatabase) throws -> [String: Int64] {
    var table: [String: Int64] = [:]
    try db.query("SELECT source_key, n FROM source_chunk_counts") { statement in
        table[text(statement, 0)] = sqlite3_column_int64(statement, 1)
    }
    return table
}

// MARK: - 1. 計數跟著每一條寫入路徑

@Test("新增 turn、同一來源重看、第二個來源、刪掉其中一個來源：四步的計數與 spec 的表逐格相同")
func countsFollowTheSpecTable() throws {
    let (db, cleanup) = try makeTempDatabase()
    defer { cleanup() }
    let s1 = "proj-one/s1.jsonl"
    let s2 = "proj-one/s2.jsonl"

    _ = try db.insert(chunks: [turn("T", in: s1)], sourceKey: s1)
    #expect(try sourceCount(of: "T", in: db) == 1)
    #expect(try sourceTable(db) == [s1: 1])

    // 同一來源再看一次：upsert 走 DO UPDATE，不觸發 INSERT trigger。
    _ = try db.insert(chunks: [turn("T", in: s1)], sourceKey: s1)
    #expect(try sourceCount(of: "T", in: db) == 1)
    #expect(try sourceTable(db) == [s1: 1])

    _ = try db.insert(chunks: [turn("T", in: s2)], sourceKey: s2)
    #expect(try sourceCount(of: "T", in: db) == 2)
    #expect(try sourceTable(db) == [s1: 1, s2: 1])

    try db.deleteChunks(sourceKey: s1)
    #expect(try sourceCount(of: "T", in: db) == 1)
    #expect(try sourceTable(db) == [s2: 1], "被刪的來源在 source_chunk_counts 不得留下一列")
    #expect(try divergences(in: db).isEmpty)
}

@Test("刪掉持有某則 turn 最後一個連結的來源：turn 消失，兩份計數仍等於重算")
func deletingTheLastHolderKeepsCountsExact() throws {
    let (db, cleanup) = try makeTempDatabase()
    defer { cleanup() }
    let s1 = "proj-one/s1.jsonl"
    let s2 = "proj-one/s2.jsonl"
    _ = try db.insert(chunks: [turn("A", in: s1), turn("B", in: s1), turn("C", in: s1)], sourceKey: s1)
    _ = try db.insert(chunks: [turn("B", in: s2)], sourceKey: s2)
    #expect(try divergences(in: db).isEmpty)
    #expect(try sourceTable(db) == [s1: 3, s2: 1])

    try db.deleteChunks(sourceKey: s2)
    #expect(try sourceCount(of: "B", in: db) == 1)
    try db.deleteChunks(sourceKey: s1)
    #expect(try db.chunkCount() == 0)
    #expect(try sourceTable(db).isEmpty)
    #expect(try divergences(in: db).isEmpty)
}

// MARK: 建置路徑：重解被作廢的來源、從零重建

private struct AllowAllPolicy: CorpusContainmentPolicy {
    func isInsideReadOnlyCorpus(_ url: URL) -> Bool { false }
}

private func lines(_ texts: [(uuid: String, text: String)]) -> [String] {
    texts.map {
        turnLine(uuid: $0.uuid, session: "11111111-2222-3333-4444-555555555555", role: "user", text: $0.text)
    }
}

@Test("重解被作廢的來源（前綴改了）與 --full 從零重建之後，兩份計數都等於重算")
func rebuildPathsKeepCountsExact() throws {
    let corpus = try makeFixtureCorpus()
    let derivedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-derived-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derivedRoot)
    }
    let derived = try DerivedLocation(root: derivedRoot, policy: AllowAllPolicy())
    let shared = (uuid: "00000000-aaaa-bbbb-cccc-000000000001", text: "兩個檔都有的一則")
    _ = try writeSession(in: corpus, project: "proj-one", file: "a.jsonl",
                         lines: lines([shared, (uuid: "00000000-aaaa-bbbb-cccc-000000000002", text: "只在 a")]))
    _ = try writeSession(in: corpus, project: "proj-one", file: "b.jsonl",
                         lines: lines([shared, (uuid: "00000000-aaaa-bbbb-cccc-000000000003", text: "只在 b")]))
    let builder = IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
        embedder: StubEmbedder(revision: "rev-A"))
    _ = try builder.build()
    try withDatabase(derived) { (db: IndexDatabase) throws in
        #expect(try divergences(in: db).isEmpty)
        #expect(try sourceCount(of: shared.uuid, in: db) == 2)
    }

    // 改寫 a 的第一行：前綴雜湊對不上 → 整份重解（先解除它的持有、再重新插入）。
    _ = try writeSession(in: corpus, project: "proj-one", file: "a.jsonl",
                         lines: lines([(uuid: "00000000-aaaa-bbbb-cccc-000000000004", text: "a 被改寫了"), shared]))
    _ = try builder.build()
    try withDatabase(derived) { (db: IndexDatabase) throws in
        #expect(try divergences(in: db).isEmpty)
        #expect(try sourceCount(of: shared.uuid, in: db) == 2)
        #expect(try sourceCount(of: "00000000-aaaa-bbbb-cccc-000000000002", in: db) == nil, "a 原本獨有的那則要消失")
    }

    _ = try builder.build(full: true)
    try withDatabase(derived) { (db: IndexDatabase) throws in
        #expect(try divergences(in: db).isEmpty)
        #expect(try sourceTable(db).count == 2)
    }
}

private func withDatabase(_ derived: DerivedLocation, _ body: (IndexDatabase) throws -> Void) throws {
    let db = try IndexDatabase(path: derived.databaseURL.path)
    defer { db.close() }
    try body(db)
}

// MARK: - 2. 只有 trigger 寫計數；沒有 SQL 用 REPLACE 寫 chunk_sources；連結的鍵不可改

@Test("改 chunk_sources 的 chunk_id 或 source_key 會被引擎中止，計數不變")
func changingALinkKeyAborts() throws {
    let (db, cleanup) = try makeTempDatabase()
    defer { cleanup() }
    let s1 = "proj-one/s1.jsonl"
    _ = try db.insert(chunks: [turn("A", in: s1), turn("B", in: s1)], sourceKey: s1)
    #expect(throws: (any Error).self) {
        try db.execute("UPDATE chunk_sources SET source_key = 'proj-one/other.jsonl'")
    }
    #expect(throws: (any Error).self) {
        try db.execute("UPDATE chunk_sources SET chunk_id = chunk_id + 1000")
    }
    #expect(try sourceTable(db) == [s1: 2])
    #expect(try divergences(in: db).isEmpty)
    // 中止訊息是 trigger 自己的，不是任何錯誤都算（R1-10）。
    let error = #expect(throws: IndexDatabase.DatabaseError.self) {
        try db.execute("UPDATE chunk_sources SET source_key = 'proj-one/again.jsonl'")
    }
    guard case .statementFailed(_, let message) = error else {
        Issue.record("應該是 statementFailed，實際是 \(String(describing: error))")
        return
    }
    #expect(message.contains("chunk_sources keys are immutable"))
}

/// R1-6：DELETE trigger 的遞減分支。出貨路徑一次刪掉一個來源的全部連結，最後總是「那一列消失」，
/// 看不出 `AND n = 1` 與遞減；直接刪掉其中一列連結才看得到。
@Test("來源持有三列、刪掉其中一列：那個來源的計數變成 2，兩份計數仍等於重算")
func deletingOneOfSeveralLinksDecrements() throws {
    let (db, cleanup) = try makeTempDatabase()
    defer { cleanup() }
    let s1 = "proj-one/s1.jsonl"
    _ = try db.insert(chunks: [turn("A", in: s1), turn("B", in: s1), turn("C", in: s1)], sourceKey: s1)
    try db.execute("DELETE FROM chunk_sources WHERE chunk_id = (SELECT MIN(chunk_id) FROM chunk_sources)")
    #expect(try sourceTable(db) == [s1: 2])
    #expect(try divergences(in: db).isEmpty)
}

/// 一個 SQL 字面裡，用 REPLACE 衝突處理寫 `chunk_sources` 的形狀。
private func replacesChunkSources(_ literal: String) -> Bool {
    let mentions = literal.range(of: #"\bchunk_sources\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    let replace = literal.range(
        of: #"\bOR\s+REPLACE\b|\bREPLACE\s+INTO\b|\bON\s+CONFLICT\s+REPLACE\b"#,
        options: [.regularExpression, .caseInsensitive]) != nil
    return mentions && replace
}

/// 一個 SQL 字面（trigger 的 DDL 以外）直接寫兩份衍生計數的形狀。
private func writesDerivedCounts(_ literal: String) -> Bool {
    // 只豁免那三個出貨的 trigger（名字＋掛在 chunk_sources 上）。先前是「含 CREATE TRIGGER 就豁免」，
    // 於是一個掛在 chunks 上、寫 source_count 的新 trigger 也被放過（R1-7）。
    let shipped = #"\bCREATE\s+TRIGGER\s+(IF\s+NOT\s+EXISTS\s+)?(chunk_sources_count_insert|chunk_sources_count_delete|chunk_sources_keys_immutable)\b[\s\S]*?\bON\s+chunk_sources\b"#
    if literal.range(of: shipped, options: [.regularExpression, .caseInsensitive]) != nil { return false }
    // 表名前可帶 schema 限定（`main.`）與引號（`"`、`` ` ``、`[`）。
    let table = #"(\w+\.)?["`\[]?"#
    let patterns = [
        #"\b(INSERT(\s+OR\s+\w+)?\s+INTO|REPLACE\s+INTO|UPDATE(\s+OR\s+\w+)?|DELETE\s+FROM)\s+"# + table + #"source_chunk_counts\b"#,
        #"\bUPDATE(\s+OR\s+\w+)?\s+"# + table + #"chunks["`\]]?(\s+(AS\s+)?\w+)?\s+SET\b[\s\S]*\bsource_count\s*="#,
        #"\bINSERT(\s+OR\s+\w+)?\s+INTO\s+"# + table + #"chunks["`\]]?\s*\([^)]*\bsource_count\b"#,
        // chunks 的 upsert 是最自然會碰到這一欄的地方。
        #"\bDO\s+UPDATE\s+SET\b[\s\S]*\bsource_count\s*="#,
        // 對 chunks 的 REPLACE 會把 source_count 重設成預設的 0，還會換 rowid。
        #"\b(OR\s+REPLACE\s+INTO|REPLACE\s+INTO)\s+"# + table + #"chunks\b"#,
        #"\bCREATE\s+TRIGGER\b[\s\S]*\b(source_count|source_chunk_counts)\b"#,
    ]
    return patterns.contains {
        literal.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

@Test("兩個偵測器本身認得出違規的形狀，也不會誤報 trigger 與閘的 SQL")
func derivedCountGuardsRecogniseTheirShapes() {
    #expect(replacesChunkSources("INSERT OR REPLACE INTO chunk_sources(chunk_id, source_key) VALUES(?, ?)"))
    #expect(replacesChunkSources("replace into chunk_sources VALUES(1, 'k', 's', 0)"))
    #expect(replacesChunkSources("CREATE TABLE chunk_sources (chunk_id INTEGER, PRIMARY KEY (chunk_id) ON CONFLICT REPLACE)"))
    #expect(!replacesChunkSources(
        "INSERT INTO chunk_sources(chunk_id, source_key) VALUES(?, ?) ON CONFLICT(chunk_id, source_key) DO UPDATE SET session_id=excluded.session_id"))
    #expect(!replacesChunkSources("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)"))

    #expect(writesDerivedCounts("UPDATE chunks SET text = ?, source_count = 3 WHERE id = ?"))
    #expect(writesDerivedCounts("INSERT INTO chunks(uuid, source_count) VALUES(?, 1)"))
    #expect(writesDerivedCounts("DELETE FROM source_chunk_counts WHERE source_key = ?"))
    #expect(writesDerivedCounts("INSERT INTO source_chunk_counts(source_key, n) VALUES(?, 1)"))
    #expect(!writesDerivedCounts("SELECT COUNT(*) FROM chunks WHERE source_count = 0"))
    // R1-7 補上的形狀
    #expect(writesDerivedCounts(
        "INSERT INTO chunks(uuid, text) VALUES(?, ?) ON CONFLICT(project_fingerprint, uuid) DO UPDATE SET text=excluded.text, source_count=excluded.source_count"))
    #expect(writesDerivedCounts("DELETE FROM main.source_chunk_counts WHERE source_key = ?"))
    #expect(writesDerivedCounts(#"INSERT INTO "source_chunk_counts"(source_key, n) VALUES(?, 1)"#))
    #expect(writesDerivedCounts("UPDATE chunks AS c SET source_count = 2 WHERE c.id = ?"))
    #expect(writesDerivedCounts("INSERT OR REPLACE INTO chunks(uuid, text) VALUES(?, ?)"))
    #expect(writesDerivedCounts(
        "CREATE TRIGGER IF NOT EXISTS chunks_reset AFTER INSERT ON chunks BEGIN UPDATE chunks SET source_count = 0 WHERE id = NEW.id; END"))
    #expect(!writesDerivedCounts(
        "INSERT INTO chunks(project, uuid) VALUES(?, ?) ON CONFLICT(project_fingerprint, uuid) DO UPDATE SET text=excluded.text"))
    #expect(!writesDerivedCounts(
        "CREATE TRIGGER IF NOT EXISTS chunk_sources_count_delete AFTER DELETE ON chunk_sources BEGIN DELETE FROM source_chunk_counts WHERE source_key = OLD.source_key AND n = 1; END"))
    #expect(!writesDerivedCounts(
        "CREATE TRIGGER IF NOT EXISTS chunk_sources_count_insert AFTER INSERT ON chunk_sources BEGIN UPDATE chunks SET source_count = source_count + 1 WHERE id = NEW.chunk_id; END"))
}

/// `Sources/` 底下每個 Swift 檔的 SQL 字面（相對路徑 → 字面）。走訪失敗要拋錯，不能安靜地變成「沒有檔」。
private func sourceLiterals() throws -> [(file: String, literal: String)] {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
        root = root.deletingLastPathComponent()
        try #require(root.path != "/")
    }
    var failures: [String] = []
    let walker = FileManager.default.enumerator(
        at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil,
        options: [.producesRelativePathURLs], errorHandler: { url, error in
            failures.append("\(url.lastPathComponent): \(error)")
            return true
        })
    var found: [(file: String, literal: String)] = []
    var walked: Set<String> = []
    while let url = walker?.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        walked.insert(url.relativePath)
        for token in try lexSwift(String(contentsOf: url, encoding: .utf8)) {
            if case .literal(let text) = token { found.append((url.relativePath, text)) }
        }
    }
    try #require(failures.isEmpty, "走訪 Sources/ 失敗：\(failures)")
    try #require(walked.contains("LTMIndex/IndexDatabase.swift"), "走訪 Sources/ 沒走到 IndexDatabase.swift")
    return found
}

@Test("Sources/ 沒有 SQL 用 REPLACE 寫 chunk_sources，也沒有 trigger 以外的 SQL 寫兩份衍生計數")
func onlyTriggersWriteTheDerivedCounts() throws {
    let literals = try sourceLiterals()
    let replacing = literals.filter { replacesChunkSources($0.literal) }.map(\.file)
    #expect(replacing.isEmpty, "這些檔用 REPLACE 寫 chunk_sources（刪掉的列不觸發 DELETE trigger）：\(replacing)")
    let writing = literals.filter { writesDerivedCounts($0.literal) }.map(\.file)
    #expect(writing.isEmpty, "這些檔在 trigger 以外寫 source_count／source_chunk_counts：\(writing)")
}

// MARK: - 3. 閘的 Q1 走 partial index

/// 閘的第一條查詢，**從 `sourcesWithoutCursor()` 的原始碼抽出來**，不是測試裡的一份複本（R1-9：先前查的
/// 是複本，閘改了而複本沒改時，這條測試會繼續綠著守一句已經不存在的 SQL）。抽法與 `GateProbeSQLSyncTests` 相同。
private func gateOrphanCountSQL() throws -> String {
    let tokens = try lexSwift(readRepoFile("Sources/LTMIndex/IndexDatabase.swift"))
    var skeleton = ""
    for token in try functionBody(of: "public func sourcesWithoutCursor()", in: tokens) {
        switch token {
        case .code(let text): skeleton += text
        case .literal(let text):
            if squash(skeleton).hasSuffix("query(") { return squash(text) }
            skeleton += "\"" + text + "\""
        }
    }
    throw LexError.unbalanced("sourcesWithoutCursor() 裡找不到 query( 之後的 SQL 字面")
}

@Test("閘的孤兒計數查詢（從原始碼抽出）走 chunks_unsourced，不掃 chunks")
func orphanCountUsesThePartialIndex() throws {
    let (db, cleanup) = try makeTempDatabase()
    defer { cleanup() }
    let sql = try gateOrphanCountSQL()
    #expect(sql.contains("source_count"), "前提：抽到的是孤兒計數那一條：\(sql)")
    var plan: [String] = []
    try db.query("EXPLAIN QUERY PLAN " + sql) { statement in
        plan.append(text(statement, 3))
    }
    let touchingChunks = plan.filter { $0.range(of: #"\bchunks\b"#, options: .regularExpression) != nil }
    #expect(!touchingChunks.isEmpty, "查詢計畫沒有任何一步讀 chunks：\(plan)")
    #expect(touchingChunks.allSatisfy { $0.contains("chunks_unsourced") },
            "讀 chunks 的每一步都要走 chunks_unsourced：\(plan)")
}
