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
    ///
    /// 4 → 5（#25）：`chunks.session_id` 移除。它曾經存「這則 turn 屬於哪個
    /// session」的單一值，而那個值是從一組等價來源裡挑出來的代表——挑選規則
    /// 由 `source_key`（檔案路徑＝位置）決定，且會隨新 resume 檔出現而改變。
    /// 導航資訊改由 `chunk_sources` 回傳全部來源。留著這個欄位會違反不變式 2：
    /// 停止維護後它的值變成 insertion-order 相依，增量與全量重建不再等價
    /// （由 `IncrementalEquivalenceTests` 的性質測試抓到）。
    public static let layoutVersion = 5

    public enum DatabaseError: Error, Sendable, Equatable {
        case openFailed(path: String, message: String)
        case statementFailed(sql: String, message: String)
        /// FTS5 或 trigram tokenizer 不可用。**大聲失敗**，附 SQLite 版本。
        case tokenizerUnavailable(sqliteVersion: String, detail: String)
        /// 續讀游標的寫入不在交易內。
        ///
        /// 這是**機制而不是規則**。把游標寫進 DB 是為了讓它與內容共享一個持久性
        /// 域；寫在交易外就等於把先前那個跨域窗口原樣搬進 DB，而且**沒有任何
        /// 單元測試抓得到**——那個失敗模式需要「已提交的交易被硬重啟回滾」，
        /// 測試造不出來（實測：把呼叫移到交易外，465 條測試全綠）。
        ///
        /// 所以這裡不是在註解裡叫呼叫端小心，是讓那條路走不通。
        case scanStateWriteOutsideTransaction(sourceKey: String)
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
    /// 探測用的 tokenizer 名。與 `RetrievalEngine.LexicalTable` 同一個理由：SQL
    /// 識別碼無法參數化，所以讓被內插的東西只能來自封閉集合。
    public enum ProbeTokenizer: String, CaseIterable {
        case trigram
        case unicode61
    }

    public func probeTokenizers() throws {
        for probe in ProbeTokenizer.allCases {
            let tokenizer = probe.rawValue
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
                project TEXT NOT NULL,
                project_fingerprint TEXT NOT NULL,
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
        // 掃描續讀游標。**放在 DB 裡而不是 state.json，是為了讓它與內容同進同出。**
        //
        // 先前它是一個獨立的 JSON 檔，每批用 `Data.write(.atomic)` 覆寫一次。
        // 那讓「已索引到哪」與「索引裡有什麼」落在**兩個各自不保證落地的**持久性
        // 域，而它們互相假設對方已落地：
        //
        //   - `PRAGMA synchronous=NORMAL` + WAL：COMMIT **不 fsync**，硬重啟可以
        //     回滾已提交的交易（SQLite 明文）。
        //   - `Data.write(.atomic)` 是 temp + rename，**也不 fsync**。
        //   - `CorpusScanner` 的續讀判定**只讀 state**，從不回頭問 DB 有沒有那些 chunk。
        //
        // 交錯：批次 1–5 commit（WAL 未 fsync）→ 每批的 state 落地 → 斷電 →
        // WAL 尾巴回滾到批次 2，而 state 存活在批次 5 → 重跑時 scanner 認為
        // 3/4/5 的來源已處理、從 `processedBytes` 之後續讀 → **那些 chunk 永遠
        // 不再被產出**。`ltm build` 印「✓ 索引完成」，`ltm query` 照常回答，
        // 症狀只有「以前找得到的東西現在找不到」。違反不變式 2 且無訊號。
        //
        // 側車那側不會示警：它 fsync 過所以比回滾後的 `vector_count` 長，開頭的
        // `truncateSidecar` 把它截短，兩邊筆數從此吻合。
        //
        // 放進同一個交易之後，回滾會把 state 一起帶走——兩者**由構造**一致，
        // 不是靠加 fsync 去縮小窗口。（由跨模型盲驗的 devil's advocate 指出；
        // 其他五個 reviewer 都沒看到這條。）
        try execute(
            """
            CREATE TABLE IF NOT EXISTS scan_state (
                source_key TEXT PRIMARY KEY NOT NULL,
                prefix_hash TEXT NOT NULL,
                processed_bytes INTEGER NOT NULL CHECK (processed_bytes >= 0)
            )
            """)
        // 唯一鍵與 anchor 的 (source, turnID) 對齊，所以一個 anchor 恰好對應一個 chunk。
        //
        // 先前是 `uuid` 單獨 UNIQUE。那假設 turn 識別碼在整份語料裡唯一，而實測
        // 全語料 8,324 檔有 12,488 個 uuid 出現在一個以上的檔案，內容 100% 相同
        // （`docs/measurements/2026-08-18-resume-duplication.md`）。單獨 UNIQUE 的後果是
        // upsert 改寫身分欄位，使既有事件的 anchor 全部 orphan。
        try execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS chunks_identity ON chunks(project_fingerprint, uuid)")
        // 一則 turn 可以出現在**多個**來源檔——session resume 就是這樣（全語料 8,324 檔
        // 12,488 筆，見 `docs/measurements/2026-08-18-resume-duplication.md`）。所以「這個 chunk 來自哪裡」是多對多的事實，不能存成 chunks
        // 的一個欄位。
        //
        // 先前正是一個欄位。它與去重（唯一鍵 `(project_fingerprint, uuid)`）交互
        // 之後會**刪掉還存在的 turn**：兩個檔都有 T，去重後只有一列，欄位只記得住
        // 其中一個檔；刪掉那個檔就把 T 從索引刪掉，而另一個檔沒有變動，增量掃描
        // 不會重新產出它。結果是增量與全量重建不等價——違反不變式 2，且無聲。
        //
        // 兩個機制各自正確，交互作用不正確。所以改的是**形狀**，不是刪除邏輯。
        try execute(
            """
            CREATE TABLE IF NOT EXISTS chunk_sources (
                chunk_id INTEGER NOT NULL,
                source_key TEXT NOT NULL,
                session_id TEXT NOT NULL,
                timestamp REAL NOT NULL,
                PRIMARY KEY (chunk_id, source_key)
            )
            """)
        try execute(
            "CREATE INDEX IF NOT EXISTS chunk_sources_by_source ON chunk_sources(source_key)")
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

    /// 寫入一個來源的續讀游標。**呼叫端必須在批次的交易內呼叫它**——放在交易外
    /// 就等於把先前那個跨持久性域的窗口原樣搬進 DB。
    public func upsertScanState(sourceKey: String, prefixHash: String, processedBytes: Int) throws {
        // autocommit 開著 = 不在交易內。見 `scanStateWriteOutsideTransaction`。
        guard sqlite3_get_autocommit(handle) == 0 else {
            throw DatabaseError.scanStateWriteOutsideTransaction(sourceKey: sourceKey)
        }
        try execute(
            """
            INSERT INTO scan_state(source_key, prefix_hash, processed_bytes) VALUES(?, ?, ?)
            ON CONFLICT(source_key) DO UPDATE SET
                prefix_hash = excluded.prefix_hash,
                processed_bytes = excluded.processed_bytes
            """,
            bind: [.text(sourceKey), .text(prefixHash), .integer(Int64(processedBytes))])
    }

    public func deleteScanState(sourceKey: String) throws {
        guard sqlite3_get_autocommit(handle) == 0 else {
            throw DatabaseError.scanStateWriteOutsideTransaction(sourceKey: sourceKey)
        }
        try execute("DELETE FROM scan_state WHERE source_key = ?", bind: [.text(sourceKey)])
    }

    /// 讀回全部續讀游標。空表回空 state——呼叫端要自己分辨「沒有續讀點」與
    /// 「表不存在」，後者在 `createSchema()` 之後不可能發生。
    public func scanState() throws -> ScanState {
        var files: [String: SourceFileState] = [:]
        var rejected: [String] = []
        try query("SELECT source_key, prefix_hash, processed_bytes FROM scan_state") { statement in
            let key = columnText(statement, 0)
            let hash = columnText(statement, 1)
            let bytes = Int(sqlite3_column_int64(statement, 2))
            // `CHECK` 只約束**這個 schema 建立之後**寫進去的列。舊索引裡的列、
            // 以及任何一條外部 `UPDATE`，都到得了這裡。讀不回來的列**丟棄並回報**
            // ——交給掃描器會讓它從一個不可能的位置續讀。
            //
            // 丟棄的後果是那個來源從頭重掃（正確但慢），不是索引少東西。
            guard bytes >= 0 else { rejected.append(key); return }
            files[key] = SourceFileState(prefixHash: hash, processedBytes: bytes)
        }
        if !rejected.isEmpty {
            // 沉默的丟棄等於索引少了東西而沒人會發現（CLAUDE.md）。
            FileHandle.standardError.write(
                Data(
                    ("⚠ scan_state 有 \(rejected.count) 列的 processed_bytes 是負值，已丟棄"
                        + "（那些來源將從頭重掃）：\(rejected.sorted().prefix(5).joined(separator: "、"))\n")
                        .utf8))
        }
        return ScanState(files: files)
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

    /// 由尚存的 `chunk_sources` 連結重算 chunk 的 `timestamp`。
    ///
    /// ## 為什麼只剩 timestamp（#25）
    ///
    /// 這裡曾經同時重算 `session_id`，規則是「時間戳最新者勝，平手取 `source_key`
    /// 字典序最大」。那條規則現在整個拿掉了，因為它做的事是**從一組等價來源裡
    /// 挑一個當代表**，而那個代表值：
    ///
    /// 1. 由 `source_key`（檔案路徑＝**位置**）決定，違反 `ltm-analogy` 的性質 1
    ///    「內容定址，不是位置定址」；
    /// 2. **會變**——實測：一則內容從未改動的 turn，其代表值會因為**另一個
    ///    resume 檔出現**而改變（極值隨集合成長而移動）。CLAUDE.md 記載這條
    ///    判準已被違反兩次，判準是「會不會變」而非禁用清單；這是第三次。
    ///
    /// 導航資訊改由 `sessionSources(chunkIDs:)` 回傳**全部**來源，沒有代表值。
    ///
    /// `chunks.session_id` 欄位已在 layout 5 移除。要知道一則 turn 屬於哪些
    /// session，唯一的來源是 `chunk_sources`。（中途曾考慮「留欄位但不維護」，
    /// 但那讓它的值變成 insertion-order 相依，增量與全量重建不再等價——性質
    /// 測試抓到了，所以改成刪除。）
    ///
    /// `timestamp` 留在這裡是因為它**不是**同一類東西：它是那段經歷發生的時間
    /// （記憶的性質），而不是它被哪個檔記下來（紀錄的性質）。它也真的有讀者
    /// （排序與範圍查詢）。
    ///
    /// 這裡仍然是「對來源集合取極值」——與被移除的 `session_id` 同一個形狀。
    /// 它目前安全，因為 resume 複製不改原始時間戳，所以 `MAX` 退化成常數：
    /// 實測 8,744 檔、**2,736 個會成為 chunk 的跨檔 turn**，時間戳相異率 **0.00%**
    /// （`docs/measurements/2026-08-18-resume-duplication.md` 的「補量」一節；
    /// 該紀錄原本明文不涵蓋時間戳，是 #25 verify 抓到引用落空後補的）。
    ///
    /// **這是語料當下的形狀，不是寫入契約**。若 Claude Code 之後改成複製時重寫
    /// timestamp，這個前提就失效，而本欄位會退化成與 `session_id` 相同的病灶；
    /// 屆時的修法一樣是不挑極值。
    ///
    /// 先前這裡寫的是 `ORDER BY s.timestamp DESC, s.source_key DESC LIMIT 1`，
    /// 與 `MAX()` 等價（平手時取誰都一樣，因為只取 timestamp 本身），但那個
    /// `source_key` tiebreak 是**死的**，且在一份專門記錄「source_key 排序就是
    /// 位置定址」的檔案裡會讓讀者以為 timestamp 仍有 path-derived 的成分。
    private func refreshNavigation(chunkID: Int64) throws {
        try execute(
            """
            UPDATE chunks SET
                timestamp = (SELECT MAX(s.timestamp) FROM chunk_sources s
                             WHERE s.chunk_id = chunks.id)
            WHERE id = ? AND EXISTS(SELECT 1 FROM chunk_sources s WHERE s.chunk_id = chunks.id)
            """, bind: [.integer(chunkID)])
    }

    /// 一批 chunk 各自的**全部**來源 session 識別碼，依 `source_key` 字典序。
    ///
    /// ## 為什麼要有這個（#25）
    ///
    /// `chunks.session_id` 是**一個**值，而 `refreshNavigation` 從多個等價來源裡挑出
    /// 它的規則在真實語料裡從未真正生效：resume 複製不改訊息時間戳，所以時間戳比較
    /// 永遠平手，實際決定勝負的是 `source_key` 字典序——與「最近觀察到」沒有因果關係
    /// （量測見 `docs/measurements/2026-08-18-resume-duplication.md`）。
    ///
    /// 修法不是換一個更好的代理指標，而是**不要挑**：`chunk_sources` 已經記著每個
    /// 持有者各自的 session id，導航回傳全部，讓消費端知道這則 turn 存在於哪幾份檔，
    /// 而不是收到一個沒有依據的挑選結果。
    ///
    /// ## 批次而不是逐 chunk
    ///
    /// 收 `[Int64]` 回 `[Int64: [String]]`，一次查詢撈完整批——呼叫端（`RetrievalEngine`）
    /// 本來就在對 k 個 rowID 迴圈，逐 chunk 再查一次會是 N+1。
    ///
    /// 空輸入回空字典，不下查詢。
    public func sessionSources(chunkIDs: [Int64]) throws -> [Int64: [String]] {
        guard !chunkIDs.isEmpty else { return [:] }
        // rowID 是本地整數、非外來字串，但仍走 bind 而不是字串內插——SQL 組裝的
        // 例外一旦開一次，下一個「這個也是本地值」就會跟著進來。
        let placeholders = Array(repeating: "?", count: chunkIDs.count).joined(separator: ",")
        var byChunk: [Int64: [String]] = [:]
        try query(
            """
            SELECT chunk_id, session_id FROM chunk_sources
            WHERE chunk_id IN (\(placeholders))
            ORDER BY chunk_id, source_key
            """, bind: chunkIDs.map { .integer($0) }
        ) { statement in
            let chunkID = sqlite3_column_int64(statement, 0)
            byChunk[chunkID, default: []].append(columnText(statement, 1))
        }
        return byChunk
    }

    /// 解除某來源檔對 chunk 的持有；**只有失去最後一個持有者的 chunk 才真的刪掉**。
    ///
    /// 「這個檔沒了」與「這則 turn 沒了」是兩件事。session resume 讓同一則 turn
    /// 同時活在多個檔裡，所以刪掉其中一個檔不代表那則 turn 消失了——它還在別的
    /// 檔裡，而那個檔沒有變動，增量掃描不會重新產出它。無條件刪除會讓增量結果與
    /// 全量重建不同（不變式 2），而唯一的症狀是「以前找得到的東西現在找不到」。
    public func deleteChunks(sourceKey: String) throws {
        // 先找出「只剩這一個持有者」的 chunk——它們才是真的要消失的。
        var orphaned: [(rowID: Int64, text: String)] = []
        try query(
            """
            SELECT c.id, c.text FROM chunks c
            JOIN chunk_sources s ON s.chunk_id = c.id AND s.source_key = ?
            WHERE (SELECT COUNT(*) FROM chunk_sources t WHERE t.chunk_id = c.id) = 1
            """, bind: [.text(sourceKey)]
        ) { statement in
            orphaned.append(
                (rowID: sqlite3_column_int64(statement, 0), text: columnText(statement, 1)))
        }
        // FTS5 是 external-content 表，刪 chunk 前要先把它的 FTS 列刪掉，
        // 否則被作廢的舊文字仍然命中得到——那正是「安靜地回舊文字」的來源。
        for chunk in orphaned {
            // **不吞錯**：FTS 刪除失敗卻照樣刪掉 chunks 並提交，會讓殘留 token
            // 在 rowid 被重用時錯配到新 chunk。唯一防「安靜地回舊文字」的那一步
            // 本身不可以是靜默的。
            try deleteFTSRows(rowID: chunk.rowID, text: chunk.text)
            try execute("DELETE FROM chunks WHERE id = ?", bind: [.integer(chunk.rowID)])
        }
        // 活下來的那些：先記住是誰，解除連結之後要重算導航欄位。
        //
        // 沒有這一步，chunk 會活下來但 `timestamp` 凍結在剛被解除持有的那個
        // 來源上。（session 已不是 chunks 的欄位——見 layout 5 的說明；它的
        // 多來源事實住在 `chunk_sources`，解除連結時自然就更新了。）
        var survivors: [Int64] = []
        try query(
            """
            SELECT s.chunk_id FROM chunk_sources s
            WHERE s.source_key = ?
              AND (SELECT COUNT(*) FROM chunk_sources t WHERE t.chunk_id = s.chunk_id) > 1
            """, bind: [.text(sourceKey)]
        ) { statement in
            survivors.append(sqlite3_column_int64(statement, 0))
        }
        try execute("DELETE FROM chunk_sources WHERE source_key = ?", bind: [.text(sourceKey)])
        for chunkID in survivors { try refreshNavigation(chunkID: chunkID) }
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
            // **只要那一列已經存在就先刪 FTS，不管文字有沒有變。**
            //
            // 先前的守衛是 `existing.text != chunk.text`，於是「同一則 turn 出現在
            // 多個來源」這條路徑（session resume 的常態）不刪、卻照樣往下插——
            // 同一個 rowid 的 postings 被加了第二次。回傳的命中列數看起來正常
            // （FTS5 不會回重複 rowid），但**全域**文件計數多算了一格。
            //
            // bm25 的 idf 與 avgdl 是全域統計，所以歪掉的不是那一則 turn，是整份
            // 索引的每一次 lexical 查詢；名次進 RRF、RRF 決定帶內次序。而且每重解
            // 一次多算一格，單調增長、沒有上限、沒有任何訊號。
            if let existing {
                try deleteFTSRows(rowID: existing.rowID, text: existing.text)
            }
            // 同一個 uuid 重複出現（例如同一份檔案被重讀）時覆蓋既有列：
            // uuid 在語料裡唯一，兩筆同 uuid 代表後者是修正版。
            try execute(
                """
                INSERT INTO chunks(
                    project, project_fingerprint, uuid, timestamp,
                    role, text, anchor_hash, anchor_span_lower, anchor_span_upper)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(project_fingerprint, uuid) DO UPDATE SET
                    text=excluded.text,
                    role=excluded.role,
                    anchor_hash=excluded.anchor_hash,
                    anchor_span_lower=excluded.anchor_span_lower,
                    anchor_span_upper=excluded.anchor_span_upper,
                    -- `timestamp` **不在這裡決定**：它是「這則 turn 目前還被哪些
                    -- 來源持有」的函數，所以住在 `chunk_sources`，由
                    -- `refreshNavigation` 從尚存的連結重算。先前它是 upsert 的
                    -- CASE，於是一個來源被刪掉之後，勝出的那份值就**凍結**在已不
                    -- 存在的檔案上——增量與全量重建因此不同（不變式 2）。
                    --
                    -- session 已不再是 chunks 的欄位（#25，layout 5）：它是多值的，
                    -- 住在 `chunk_sources`。
                    timestamp=chunks.timestamp
                """,
                bind: [
                    .text(chunk.project), .text(chunk.projectFingerprint),
                    .text(chunk.uuid),
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
            // 這個來源檔持有這個 chunk，**並記下它在這個來源裡看到的導航值**。
            // 少了這兩欄，一個來源被刪掉之後就沒有任何地方知道其餘來源看到的是什麼。
            try execute(
                """
                INSERT INTO chunk_sources(chunk_id, source_key, session_id, timestamp)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(chunk_id, source_key) DO UPDATE SET
                    session_id=excluded.session_id, timestamp=excluded.timestamp
                """,
                bind: [
                    .integer(rowID), .text(sourceKey), .text(chunk.sessionID),
                    .double(chunk.timestamp.timeIntervalSince1970),
                ])
            try refreshNavigation(chunkID: rowID)
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
