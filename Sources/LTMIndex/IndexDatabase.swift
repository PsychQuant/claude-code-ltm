import Foundation
import LTMCore
import SQLite3

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
    public static let layoutVersion = 1

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
    /// **失敗即中止並指名 SQLite 版本**，不退回 `LIKE` 掃描。理由是誠實邊界：
    /// 沒有 trigram 的中文 recall 是 14–15%（#2 的量測），而退化後的結果看起來
    /// 完全正常——使用者只會覺得「這東西找不到東西」，不會知道索引配置掉了一路。
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
                session_id TEXT NOT NULL,
                uuid TEXT NOT NULL UNIQUE,
                timestamp REAL NOT NULL,
                role TEXT NOT NULL,
                text TEXT NOT NULL,
                anchor_hash TEXT NOT NULL,
                anchor_span_lower INTEGER NOT NULL,
                anchor_span_upper INTEGER NOT NULL,
                vector_row INTEGER
            )
            """)
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
            if let raw = sqlite3_column_text(statement, 0) {
                result = String(cString: raw)
            }
        }
        return result
    }

    /// 索引宣告的 layout 版本與 embedding revision。
    public struct Stamps: Sendable, Equatable {
        public let layoutVersion: Int?
        public let embeddingRevision: String?
        public init(layoutVersion: Int?, embeddingRevision: String?) {
            self.layoutVersion = layoutVersion
            self.embeddingRevision = embeddingRevision
        }
    }

    public func stamps() throws -> Stamps {
        Stamps(
            layoutVersion: try meta("layout_version").flatMap(Int.init),
            embeddingRevision: try meta("embedding_revision"))
    }

    public func writeStamps(embeddingRevision: String) throws {
        try setMeta("layout_version", String(Self.layoutVersion))
        try setMeta("embedding_revision", embeddingRevision)
    }

    // MARK: - chunk 寫入

    /// 刪掉某來源檔的全部 chunk（prefix 不符 → 整份重解時用）。
    public func deleteChunks(sourceKey: String) throws {
        // FTS5 是 external-content 表，刪 chunk 前要先把它的 FTS 列刪掉，
        // 否則被作廢的舊文字仍然命中得到——那正是「安靜地回舊文字」的來源。
        try query("SELECT id, text FROM chunks WHERE source_key = ?", bind: [.text(sourceKey)]) {
            statement in
            let rowID = sqlite3_column_int64(statement, 0)
            let text = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            try? self.deleteFTSRows(rowID: rowID, text: text)
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
            // 同一個 uuid 重複出現（例如同一份檔案被重讀）時覆蓋既有列：
            // uuid 在語料裡唯一，兩筆同 uuid 代表後者是修正版。
            try execute(
                """
                INSERT INTO chunks(
                    source_key, project, session_id, uuid, timestamp, role, text,
                    anchor_hash, anchor_span_lower, anchor_span_upper)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(uuid) DO UPDATE SET
                    source_key=excluded.source_key, project=excluded.project,
                    session_id=excluded.session_id, timestamp=excluded.timestamp,
                    role=excluded.role, text=excluded.text,
                    anchor_hash=excluded.anchor_hash,
                    anchor_span_lower=excluded.anchor_span_lower,
                    anchor_span_upper=excluded.anchor_span_upper
                """,
                bind: [
                    .text(sourceKey), .text(chunk.project), .text(chunk.sessionID),
                    .text(chunk.uuid), .double(chunk.timestamp.timeIntervalSince1970),
                    .text(chunk.role), .text(chunk.text),
                    .text(chunk.anchor.contentHash.hex),
                    .integer(Int64(chunk.anchor.span.lowerBound)),
                    .integer(Int64(chunk.anchor.span.upperBound)),
                ])
            var rowID: Int64 = 0
            try query("SELECT id FROM chunks WHERE uuid = ?", bind: [.text(chunk.uuid)]) { statement in
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
                sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
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
