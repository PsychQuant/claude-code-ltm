import Foundation
import LTMCore
import SQLite3

/// 讀一個 TEXT 欄位，**用明確的 byte 長度**而不是 C-string 語意。
///
/// `String(cString:)` 在第一個 NUL 停下來，與寫入端 `bind_text(-1)` 是同一個截斷的
/// 兩端。兩邊都改才有意義：只改寫入端，讀出來的仍然是半截。
public func columnText(_ statement: OpaquePointer, _ column: Int32) -> String {
    guard let raw = sqlite3_column_text(statement, column) else { return "" }
    let count = Int(sqlite3_column_bytes(statement, column))
    return String(decoding: UnsafeBufferPointer(start: raw, count: count), as: UTF8.self)
}

/// SQLite 的 `SQLITE_TRANSIENT`：告訴 SQLite 這塊記憶體隨時會消失，請自己複製。
///
/// C 巨集在 Swift 看不到，必須自己造。用 `SQLITE_STATIC`（預設）會讓 Swift 的
/// 暫時字串在 `sqlite3_step` 之前就被回收——那是安靜的記憶體錯誤，不是編譯錯誤。
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 衍生索引的 SQLite 檔。
///
/// 三張表各有職責：
/// - `chunks`：指標四元組與原文（檢索回傳的內容來源）
/// - `chunks_trigram` / `chunks_segment`：兩條 lexical 通道，配置依 #2 的量測決定
/// - `meta`：layout 版本與 embedding revision，**索引作廢的判準都在這裡**
public final class IndexDatabase {
    /// 索引檔的結構版本。改 schema 就加一。
    ///
    /// 版本不符時整份重建，而不是嘗試遷移：索引是純衍生物（不變式 2），重建的
    /// 代價是時間，遷移寫錯的代價是安靜的錯誤結果。
    public static let layoutVersion = 2

    public enum DatabaseError: Error, Sendable, Equatable {
        case openFailed(path: String, message: String)
        case statementFailed(sql: String, message: String)
        /// FTS5 或 trigram tokenizer 不可用。**大聲失敗**，附 SQLite 版本。
        case tokenizerUnavailable(sqliteVersion: String, detail: String)
    }

    private var handle: OpaquePointer?
    public let path: String

    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let opened = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 失敗"
            sqlite3_close_v2(db)
            throw DatabaseError.openFailed(path: path, message: message)
        }
        self.handle = opened
        // WAL：讀者看見的是一致的快照，所以查詢不會讀到建置中途的半成品。
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
    }

    deinit { sqlite3_close_v2(handle) }

    public func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    public var sqliteVersion: String { String(cString: sqlite3_libversion()) }

    // MARK: - 能力探測

    /// 建 schema 前先確認 FTS5 與 trigram tokenizer 真的可用。
    ///
    /// **失敗即中止並指名 SQLite 版本**，不退回 `LIKE` 掃描。
    ///
    /// 理由不是效能而是**可觀察性**：少一條 lexical 通道的結果看起來完全正常，
    /// 使用者只會覺得「這東西找不到東西」，不會知道索引配置掉了一路。
    ///
    /// （`docs/measurements/2026-08-10-fts5-tokenizer.md` 量的是**各 tokenizer 配置
    /// 之間的相對 recall**，在該檔自己指名的 known-item 條件下。先前這裡把其中一個
    /// 數字說成「沒有 trigram 的中文 recall」——那是把配置比較的結果講成一個獨立
    /// 命題，超出該紀錄涵蓋的範圍。要引用具體數字請直接讀那份紀錄。）
    public func probeTokenizers() throws {
        for tokenizer in ["trigram", "unicode61"] {
            let sql = """
                CREATE VIRTUAL TABLE temp.probe_\(tokenizer) USING fts5(x, tokenize='\(tokenizer)')
                """
            do {
                try execute(sql)
                try execute("DROP TABLE temp.probe_\(tokenizer)")
            } catch let DatabaseError.statementFailed(_, message) {
                throw DatabaseError.tokenizerUnavailable(
                    sqliteVersion: sqliteVersion,
                    detail: "tokenize='\(tokenizer)' 不可用：\(message)")
            }
        }
    }

    // MARK: - Schema

    public func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chunks (
                id INTEGER PRIMARY KEY,
                source_key TEXT NOT NULL,
                project TEXT NOT NULL,
                project_fingerprint TEXT NOT NULL,
                session_id TEXT NOT NULL,
                uuid TEXT NOT NULL,
                timestamp REAL NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                anchor_hash TEXT NOT NULL,
                anchor_span_lower INTEGER NOT NULL,
                anchor_span_upper INTEGER NOT NULL,
                vector_row INTEGER
            )
            """)
        // 唯一鍵與 anchor 的 (source, turnID) 對齊，所以一個 anchor 恰好對應一個 chunk。
        //
        // 先前是 `uuid` 單獨 UNIQUE。那假設 turn 識別碼在整份語料裡唯一，而實測
        // 300 個真實檔有 5,722 個 uuid 出現在一個以上的檔案。單獨 UNIQUE 的後果是
        // upsert 改寫身分欄位，使既有事件的 anchor 全部 orphan。
        try execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS chunks_identity ON chunks(project_fingerprint, uuid)")
        try execute("CREATE INDEX IF NOT EXISTS chunks_by_source ON chunks(source_key)")
        try execute("CREATE INDEX IF NOT EXISTS chunks_by_project ON chunks(project)")
        // 兩條 lexical 通道。`content=''` 表示外部內容表——FTS5 不自己存一份原文，
        // 由 `chunks.text` 當唯一來源，避免同一段文字在檔案裡出現兩次。
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_trigram
            USING fts5(text, content='', tokenize='trigram')
            """)
        try execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_segment
            USING fts5(text, content='', tokenize='unicode61')
            """)
    }

    // MARK: - meta

    public func setMeta(_ key: String, _ value: String) throws {
        try execute(
            "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            bind: [.text(key), .text(value)])
    }

    public func meta(_ key: String) throws -> String? {
        var result: String?
        try query("SELECT value FROM meta WHERE key = ?", bind: [.text(key)]) { statement in
            result = columnText(statement, 0)
        }
        return result
    }

    /// anchor 的 source 是用哪一條規則算出來的。
    ///
    /// 指紋本身不帶「我是哪個版本算的」這個資訊，所以必須外部記錄。少了它，舊規則
    /// 算出的值會被拿去跟新規則比對——結果要嘛解析到錯的 turn、要嘛報 orphan，
    /// 而兩者都與正確行為分不出來。
    public static let anchorSourceRule = "project-fingerprint-sha256-32"

    /// 索引宣告的 layout 版本、embedding revision 與 anchor 規則。
    public struct Stamps: Sendable, Equatable {
        public let layoutVersion: Int?
        public let embeddingRevision: String?
        public let anchorSourceRule: String?
        public init(layoutVersion: Int?, embeddingRevision: String?, anchorSourceRule: String? = nil) {
            self.layoutVersion = layoutVersion
            self.embeddingRevision = embeddingRevision
            self.anchorSourceRule = anchorSourceRule
        }
    }

    public func stamps() throws -> Stamps {
        Stamps(
            layoutVersion: try meta("layout_version").flatMap(Int.init),
            embeddingRevision: try meta("embedding_revision"),
            anchorSourceRule: try meta("anchor_source_rule"))
    }

    public func writeStamps(embeddingRevision: String) throws {
        try setMeta("layout_version", String(Self.layoutVersion))
        try setMeta("embedding_revision", embeddingRevision)
        try setMeta("anchor_source_rule", Self.anchorSourceRule)
    }

    // MARK: - chunk 寫入

    /// 刪掉某來源檔的全部 chunk（prefix 不符 → 整份重解時用）。
    public func deleteChunks(sourceKey: String) throws {
        // FTS5 是 external-content 表，刪 chunk 前要先把它的 FTS 列刪掉，
        // 否則被作廢的舊文字仍然命中得到——那正是「安靜地回舊文字」的來源。
        try query("SELECT id, text FROM chunks WHERE source_key = ?", bind: [.text(sourceKey)]) {
            statement in
            let rowID = sqlite3_column_int64(statement, 0)
            let text = columnText(statement, 1)
            // **不吞錯**：FTS 刪除失敗卻照樣刪掉 chunks 並提交，會讓殘留 token
            // 在 rowid 被重用時錯配到新 chunk。唯一防「安靜地回舊文字」的那一步
            // 本身不可以是靜默的。
            try self.deleteFTSRows(rowID: rowID, text: text)
        }
        try execute("DELETE FROM chunks WHERE source_key = ?", bind: [.text(sourceKey)])
    }

    private func deleteFTSRows(rowID: Int64, text: String) throws {
        try execute(
            "INSERT INTO chunks_trigram(chunks_trigram, rowid, text) VALUES('delete', ?, ?)",
            bind: [.integer(rowID), .text(text)])
        try execute(
            "INSERT INTO chunks_segment(chunks_segment, rowid, text) VALUES('delete', ?, ?)",
            bind: [.integer(rowID), .text(Segmentation.segment(text))])
    }

    /// 寫入一批 chunk，回傳每個 chunk 的 rowid（順序與輸入相同）。
    @discardableResult
    public func insert(chunks: [CorpusChunk], sourceKey: String) throws -> [Int64] {
        var rowIDs: [Int64] = []
        for chunk in chunks {
            // upsert 之前先把**舊文字**的 FTS 列刪掉。
            //
            // `content=''` 的 contentless FTS5 表不會因為重複 insert 同一個 rowid
            // 而報錯——它只是讓舊 token 與新 token 同時留著，於是被改寫的內容
            // 「安靜地仍然命中舊文字」。這正是 `deleteChunks` 的註解在防的失敗模式，
            // 只是它從另一條路（upsert）繞了進來。
            var existing: (rowID: Int64, text: String)?
            try query(
                "SELECT id, text FROM chunks WHERE project_fingerprint = ? AND uuid = ?",
                bind: [.text(chunk.projectFingerprint), .text(chunk.uuid)]
            ) { statement in
                let rowID = sqlite3_column_int64(statement, 0)
                let old = columnText(statement, 1)
                existing = (rowID, old)
            }
            if let existing, existing.text != chunk.text {
                try deleteFTSRows(rowID: existing.rowID, text: existing.text)
            }
            // 同一個 uuid 重複出現（例如同一份檔案被重讀）時覆蓋既有列：
            // uuid 在語料裡唯一，兩筆同 uuid 代表後者是修正版。
            try execute(
                """
                INSERT INTO chunks(
                    source_key, project, project_fingerprint, session_id, uuid, timestamp,
                    role, text, anchor_hash, anchor_span_lower, anchor_span_upper)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(project_fingerprint, uuid) DO UPDATE SET
                    text=excluded.text,
                    role=excluded.role,
                    anchor_hash=excluded.anchor_hash,
                    anchor_span_lower=excluded.anchor_span_lower,
                    anchor_span_upper=excluded.anchor_span_upper,
                    -- 導航欄位只在**觀察到更晚的那一份**時更新。session_id 不是身分，
                    -- 它是「讀者最可能打得開的那個 session」，所以取最新的。
                    session_id=CASE WHEN excluded.timestamp >= chunks.timestamp
                                    THEN excluded.session_id ELSE chunks.session_id END,
                    source_key=CASE WHEN excluded.timestamp >= chunks.timestamp
                                    THEN excluded.source_key ELSE chunks.source_key END,
                    timestamp=MAX(excluded.timestamp, chunks.timestamp)
                """,
                bind: [
                    .text(sourceKey), .text(chunk.project), .text(chunk.projectFingerprint),
                    .text(chunk.sessionID), .text(chunk.uuid),
                    .double(chunk.timestamp.timeIntervalSince1970),
                    .text(chunk.role), .text(chunk.text),
                    .text(chunk.anchor.contentHash.hex),
                    .integer(Int64(chunk.anchor.span.lowerBound)),
                    .integer(Int64(chunk.anchor.span.upperBound)),
                ])
            var rowID: Int64 = 0
            try query(
                "SELECT id FROM chunks WHERE project_fingerprint = ? AND uuid = ?",
                bind: [.text(chunk.projectFingerprint), .text(chunk.uuid)]
            ) { statement in
                rowID = sqlite3_column_int64(statement, 0)
            }
            try execute(
                "INSERT INTO chunks_trigram(rowid, text) VALUES(?, ?)",
                bind: [.integer(rowID), .text(chunk.text)])
            try execute(
                "INSERT INTO chunks_segment(rowid, text) VALUES(?, ?)",
                bind: [.integer(rowID), .text(Segmentation.segment(chunk.text))])
            rowIDs.append(rowID)
        }
        return rowIDs
    }

    public func chunkCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM chunks") { statement in
            count = Int(sqlite3_column_int64(statement, 0))
        }
        return count
    }

    // MARK: - 交易

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - 低階

    /// 可綁定的參數型別。列舉而非 `Any`：型別混淆在 SQLite 的 C API 是安靜的
    /// （綁錯型別不報錯，只是查不到），列舉讓它變成編譯錯誤。
    public enum Value {
        case text(String)
        case integer(Int64)
        case double(Double)
    }

    public func execute(_ sql: String, bind values: [Value] = []) throws {
        let statement = try prepare(sql, bind: values)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else {
            throw DatabaseError.statementFailed(sql: sql, message: lastErrorMessage)
        }
    }

    public func query(
        _ sql: String, bind values: [Value] = [], row: (OpaquePointer) throws -> Void
    ) throws {
        let statement = try prepare(sql, bind: values)
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                try row(statement!)
            } else if code == SQLITE_DONE {
                return
            } else {
                throw DatabaseError.statementFailed(sql: sql, message: lastErrorMessage)
            }
        }
    }

    private func prepare(_ sql: String, bind values: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.statementFailed(sql: sql, message: lastErrorMessage)
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text):
                // **明確給 byte 長度**，不用 -1。
                //
                // -1 讓 SQLite 以第一個 NUL 為結尾，而 JSON 字串合法地可以含 \u0000
                // （工具輸出、被貼進 text block 的二進位轉義）。截斷的後果是 DB 與 FTS
                // 只存前半段，但 `contentHash` 與 `span` 是從完整的 Swift String 算的
                // ——命中回傳的文字與 anchor 指標不一致，既有事件也可能因此解析不到。
                let bytes = Array(text.utf8)
                sqlite3_bind_text(statement, index, bytes, Int32(bytes.count), SQLITE_TRANSIENT)
            case .integer(let number):
                sqlite3_bind_int64(statement, index, number)
            case .double(let number):
                sqlite3_bind_double(statement, index, number)
            }
        }
        return statement
    }

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "資料庫已關閉"
    }
}

// 刻意**不**提供 `ExpressibleByStringLiteral` 之類的隱式轉換。
//
// 那種便利有個不對稱：字面值可以直接寫、變數不行，於是同一個呼叫點會因為
// 「這個值是常數還是變數」而編不編得過。顯式 `.text(…)` / `.integer(…)` 讓
// 「這個參數以什麼型別綁進 SQLite」在每個呼叫點都看得見——而型別綁錯在 C API
// 是安靜的：不報錯，只是查不到。
