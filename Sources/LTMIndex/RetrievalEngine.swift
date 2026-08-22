import Accelerate
import Foundation
import LTMCore
import SQLite3

/// 一筆檢索命中。
///
/// 帶著完整的指標四元組——不變式 3 在這一層就成立，不是等 facade 補上。
public struct ScoredChunk: Sendable, Equatable {
    public let project: String
    /// 持有這則 turn 的**全部**來源各自的 session 識別碼，依 `source_key` 字典序。
    ///
    /// 至少一個元素。session resume 把同一則 turn 複製進新檔案（全語料 8,324 檔
    /// 12,488 筆內容 100% 相同——`docs/measurements/2026-08-18-resume-duplication.md`），
    /// 去重之後是**一個** chunk、多個持有者；先前只回傳其中一個，而挑選規則在真實
    /// 語料裡永遠平手、實際由檔名字典序決定（#25）。
    public let sessionSources: [String]
    public let uuid: String
    public let timestamp: Date
    public let text: String
    public let anchor: Anchor
    /// RRF 融合分數。
    public let fusedScore: Double
    /// 在**輸出順序**裡的名次（0 起算）。
    ///
    /// 輸出順序是 band-major 的（見 `band`），所以這**不是**純融合分數的名次——
    /// 兩者只在沒有跨帶反轉時一致。名字先前叫 `fusedRank`，而它在分層落地之後
    /// 已經不是那個意思了；一個說「融合名次」卻裝著「輸出名次」的欄位，正是這個
    /// repo 反覆踩到的「敘述與程式碼相反」。
    public let emittedRank: Int
    /// 相關度分層：**0 最相關**。
    ///
    /// 由命中的通道數決定（多重編碼——多條線索都指向它，相關度證據更強），
    /// 定義是 `Channel.allCases.count - channels.count`，不寫死 3。
    ///
    /// 這個值住在檢索層而不是 facade：它是檢索對候選的判斷，而 `MemoryStrategy`
    /// 的 seam 前置條件（`requireBandsInOrder`）要求候選**到達時**已經分好帶——
    /// 也就是說分帶與排帶本來就是檢索的職責，不是策略的重排。先前它在 facade
    /// 算並排序，於是 facade 在 seam 之外重排，違反 retrieval spec 的
    /// 「SHALL NOT reorder outside that seam」。
    public let band: Int
    /// 這一筆在哪些通道出現過。用於解釋，也用於測試融合行為。
    public let channels: Set<Channel>

    /// 由命中通道數算出相關度帶。**band 規則的唯一定義處。**
    public static func band(matching channels: Set<Channel>) -> Int {
        Channel.allCases.count - channels.count
    }

    public enum Channel: String, Sendable, Hashable, CaseIterable {
        case trigram
        case segment
        case vector
    }
}

/// 對衍生索引執行查詢。
///
/// 三條通道各自出一份排名，再用 reciprocal-rank fusion 合成一份——配置與
/// 合成方式都依 `docs/measurements/2026-08-10-fts5-tokenizer.md`（#2）的決定
/// （OR 與 RRF 在該次量測的三個 seed 上等價，取 RRF 以與向量路一致）。
///
/// **刻意不是 `Sendable`**：它持有一個以 `SQLITE_OPEN_NOMUTEX` 開啟的連線，
/// 那個旗標的意思正是「這個連線不做內部互斥，由呼叫端保證不併發使用」。宣告
/// 成 `Sendable` 會讓型別系統允許把它送進另一個 isolation domain，而那會是
/// 資料競爭——SQLite 不會報錯，只會在某次查詢回錯的結果或損毀。要並發查詢，
/// 每個 domain 開自己的連線。
public struct RetrievalEngine {
    /// RRF 的平滑常數。60 是 Cormack et al. (2009) 提出並被廣泛沿用的值；
    /// 本 repo 沒有針對它做過調參量測，所以這裡**不宣稱**它是最佳值。
    public static let rrfK = 60.0

    private let database: IndexDatabase
    private let vectors: VectorSidecar?
    private let embedder: (any EmbeddingProvider)?

    public init(
        database: IndexDatabase, vectors: VectorSidecar?, embedder: (any EmbeddingProvider)?
    ) {
        self.database = database
        self.vectors = vectors
        self.embedder = embedder
    }

    /// 查詢範圍。
    public enum Scope: Sendable, Equatable {
        case project(String)
        case allProjects
    }

    /// 執行查詢。
    ///
    /// - Parameter limit: 最多回幾筆（融合後）。
    public func search(query: String, limit: Int, scope: Scope) throws -> [ScoredChunk] {
        // 每條通道各取比 limit 深一些的候選：融合會重排，只取 limit 深度的話
        // 「在單一通道排名較後、但三條都出現」的候選會被截掉，而那正是融合要
        // 撈出來的東西。
        let channelDepth = max(limit * 5, 50)

        let trigramHits = try lexicalHits(
            table: "chunks_trigram", matchText: query, depth: channelDepth, scope: scope)
        let segmentHits = try lexicalHits(
            table: "chunks_segment", matchText: Segmentation.segment(query), depth: channelDepth,
            scope: scope)
        let vectorHits = try vectorRanking(query: query, depth: channelDepth, scope: scope)

        var fused: [Int64: (score: Double, channels: Set<ScoredChunk.Channel>)] = [:]
        for (channel, ranking) in [
            (ScoredChunk.Channel.trigram, trigramHits),
            (ScoredChunk.Channel.segment, segmentHits),
            (ScoredChunk.Channel.vector, vectorHits),
        ] {
            for (rank, rowID) in ranking.enumerated() {
                let contribution = 1.0 / (Self.rrfK + Double(rank + 1))
                var entry = fused[rowID] ?? (score: 0, channels: [])
                entry.score += contribution
                entry.channels.insert(channel)
                fused[rowID] = entry
            }
        }

        // **band-major**：先相關度層、層內才看融合分數，同分用 rowid 決勝（讓順序
        // 在同一份索引上可重現）。
        //
        // 截斷也走同一個順序。先前是「用融合分數選 top-k、用 band 排顯示」——
        // 選集與排序用兩個不同的判準，於是一個 band 1 的候選可能被截掉而 band 2
        // 的照樣回傳，而使用者看到的是一份宣稱按相關度分層的清單。
        let ordered = fused.sorted { lhs, rhs in
            let lb = ScoredChunk.band(matching: lhs.value.channels)
            let rb = ScoredChunk.band(matching: rhs.value.channels)
            if lb != rb { return lb < rb }
            if lhs.value.score != rhs.value.score { return lhs.value.score > rhs.value.score }
            return lhs.key < rhs.key
        }.prefix(limit)

        // 全部來源一次撈完，不在下面的迴圈裡逐 chunk 查（N+1）。
        let sourcesByChunk = try database.sessionSources(chunkIDs: ordered.map(\.key))

        var results: [ScoredChunk] = []
        for (offset, entry) in ordered.enumerated() {
            guard let chunk = try loadChunk(rowID: entry.key) else { continue }
            // 來源集合**就是**導航資訊，沒有代表值可挑（#25／`ltm-analogy` 性質 1）。
            // 撈不到任何來源列代表 `chunk_sources` 與 `chunks` 不一致——那是資料
            // 損壞，依 retrieval spec「不得部分回傳」跳過這一筆，與 `loadChunk`
            // 對損壞列的處置一致。
            guard let sources = sourcesByChunk[entry.key], !sources.isEmpty else { continue }
            results.append(
                ScoredChunk(
                    project: chunk.project, sessionSources: sources,
                    uuid: chunk.uuid,
                    timestamp: chunk.timestamp, text: chunk.text, anchor: chunk.anchor,
                    fusedScore: entry.value.score, emittedRank: offset,
                    band: ScoredChunk.band(matching: entry.value.channels),
                    channels: entry.value.channels))
        }
        return results
    }

    // MARK: - 通道

    /// 一條 FTS5 通道的排名（rowid 序列，最相關在前）。
    func lexicalHits(table: String, matchText: String, depth: Int, scope: Scope) throws -> [Int64] {
        let pattern = Self.ftsPhrase(matchText)
        guard !pattern.isEmpty else { return [] }
        var rowIDs: [Int64] = []
        // `bm25()` 回的是負值、越小越相關，所以升冪就是相關度降冪。
        var sql = """
            SELECT f.rowid FROM \(table) f
            JOIN chunks c ON c.id = f.rowid
            WHERE f.\(table) MATCH ?
            """
        var bindings: [IndexDatabase.Value] = [.text(pattern)]
        if case .project(let name) = scope {
            sql += " AND c.project = ?"
            bindings.append(.text(name))
        }
        sql += " ORDER BY bm25(\(table)) LIMIT ?"
        bindings.append(.integer(Int64(depth)))
        try database.query(sql, bind: bindings) { statement in
            rowIDs.append(sqlite3_column_int64(statement, 0))
        }
        return rowIDs
    }

    /// 向量通道的排名。
    ///
    /// 暴力 cosine，不建 ANN 索引——理由與重議觸發條件記在
    /// `docs/measurements/2026-08-08-baseline.md`。向量在寫入時已正規化，所以
    /// 相似度就是點積。
    func vectorRanking(query: String, depth: Int, scope: Scope) throws -> [Int64] {
        guard let embedder, let vectors,
            let queryVector = try embedder.vector(for: query)
        else { return [] }
        guard queryVector.count == vectors.dimension else { return [] }

        // 取出候選 (rowid, vector_row)。範圍過濾在 SQL 端做，免得對整個語料算
        // 相似度之後再丟掉大半。
        var rows: [(rowID: Int64, vectorRow: Int)] = []
        var sql = "SELECT id, vector_row FROM chunks WHERE vector_row IS NOT NULL"
        var bindings: [IndexDatabase.Value] = []
        if case .project(let name) = scope {
            sql += " AND project = ?"
            bindings.append(.text(name))
        }
        try database.query(sql, bind: bindings) { statement in
            rows.append(
                (rowID: sqlite3_column_int64(statement, 0),
                 vectorRow: Int(sqlite3_column_int64(statement, 1))))
        }
        guard !rows.isEmpty else { return [] }

        var scored: [(rowID: Int64, similarity: Float)] = []
        scored.reserveCapacity(rows.count)
        for row in rows {
            guard let candidate = vectors.vector(at: row.vectorRow) else { continue }
            var dot: Float = 0
            vDSP_dotpr(queryVector, 1, candidate, 1, &dot, vDSP_Length(queryVector.count))
            scored.append((rowID: row.rowID, similarity: dot))
        }
        scored.sort { lhs, rhs in
            lhs.similarity == rhs.similarity ? lhs.rowID < rhs.rowID : lhs.similarity > rhs.similarity
        }
        return scored.prefix(depth).map(\.rowID)
    }

    // MARK: - 讀取

    private struct StoredChunk {
        let project: String
        let uuid: String
        let timestamp: Date
        let text: String
        let anchor: Anchor
    }

    private func loadChunk(rowID: Int64) throws -> StoredChunk? {
        var found: StoredChunk?
        try database.query(
            """
            SELECT project, uuid, timestamp, text,
                   anchor_hash, anchor_span_lower, anchor_span_upper, project_fingerprint
            FROM chunks WHERE id = ?
            """, bind: [.integer(rowID)]
        ) { statement in
            // 欄位索引對應上面的 SELECT 順序：
            // 0 project, 1 uuid, 2 timestamp, 3 text, 4 anchor_hash,
            // 5 span_lower, 6 span_upper, 7 project_fingerprint
            func text(_ column: Int32) -> String { columnText(statement, column) }
            let uuid = text(1)
            let hashHex = text(4)
            let fingerprint = text(7)
            let lower = Int(sqlite3_column_int64(statement, 5))
            let upper = Int(sqlite3_column_int64(statement, 6))
            // 索引裡的值理論上都是寫入時驗過的，但它是磁碟上的外來資料——
            // 損壞的列跳過，不 trap。
            guard let hash = try? ContentHash(validating: hashHex),
                (try? Anchor.validate(lower: lower, upper: upper)) != nil,
                (try? OpaqueIdentifier.validate(fingerprint)) != nil,
                (try? OpaqueIdentifier.validate(uuid)) != nil
            else { return }
            found = StoredChunk(
                project: text(0), uuid: uuid,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                text: text(3),
                // source 是 **project 指紋**，與寫入端（`CorpusScanner`）一致。
                // 用 sessionID 重建 anchor 會讓同一則 turn 在 resume 前後得到不同的
                // anchor，於是既有事件全部對不上——B3 的病灶就在讀寫兩端不一致。
                anchor: Anchor(
                    source: fingerprint, turnID: uuid, contentHash: hash, span: lower..<upper))
        }
        return found
    }

    /// 把查詢包成 FTS5 的 phrase，讓使用者輸入的字元不會被當成查詢語法。
    ///
    /// FTS5 把 `-` `*` `:` `(` `)` `"` 等當運算子，直接把查詢丟進 MATCH 會讓
    /// 「查一個含連字號的詞」變成語法錯誤或意料外的布林查詢。包成雙引號 phrase
    /// 之後只剩雙引號本身要跳脫（重複一次）。
    static func ftsPhrase(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
