import Accelerate
import Foundation
import LTMCore
import SQLite3

/// 一筆檢索命中。
///
/// 帶著完整的指標四元組——不變式 3 在這一層就成立，不是等 facade 補上。
public struct ScoredChunk: Sendable, Equatable {
    public let project: String
    public let sessionID: String
    public let uuid: String
    public let timestamp: Date
    public let text: String
    public let anchor: Anchor
    /// RRF 融合分數。
    public let fusedScore: Double
    /// 融合後的名次（0 起算），成為 `RelevanceBand` 的 rank。
    public let fusedRank: Int
    /// 這一筆在哪些通道出現過。用於解釋，也用於測試融合行為。
    public let channels: Set<Channel>

    public enum Channel: String, Sendable, Hashable {
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

        // 名次相同時用 rowid 決勝，讓順序在同一份索引上可重現。
        let ordered = fused.sorted { lhs, rhs in
            lhs.value.score == rhs.value.score
                ? lhs.key < rhs.key : lhs.value.score > rhs.value.score
        }.prefix(limit)

        var results: [ScoredChunk] = []
        for (offset, entry) in ordered.enumerated() {
            guard let chunk = try loadChunk(rowID: entry.key) else { continue }
            results.append(
                ScoredChunk(
                    project: chunk.project, sessionID: chunk.sessionID, uuid: chunk.uuid,
                    timestamp: chunk.timestamp, text: chunk.text, anchor: chunk.anchor,
                    fusedScore: entry.value.score, fusedRank: offset,
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
        let sessionID: String
        let uuid: String
        let timestamp: Date
        let text: String
        let anchor: Anchor
    }

    private func loadChunk(rowID: Int64) throws -> StoredChunk? {
        var found: StoredChunk?
        try database.query(
            """
            SELECT project, session_id, uuid, timestamp, text,
                   anchor_hash, anchor_span_lower, anchor_span_upper
            FROM chunks WHERE id = ?
            """, bind: [.integer(rowID)]
        ) { statement in
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            let sessionID = text(1)
            let uuid = text(2)
            let hashHex = text(5)
            let lower = Int(sqlite3_column_int64(statement, 6))
            let upper = Int(sqlite3_column_int64(statement, 7))
            // 索引裡的值理論上都是寫入時驗過的，但它是磁碟上的外來資料——
            // 損壞的列跳過，不 trap。
            guard let hash = try? ContentHash(validating: hashHex),
                (try? Anchor.validate(lower: lower, upper: upper)) != nil,
                (try? OpaqueIdentifier.validate(sessionID)) != nil,
                (try? OpaqueIdentifier.validate(uuid)) != nil
            else { return }
            found = StoredChunk(
                project: text(0), sessionID: sessionID, uuid: uuid,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                text: text(4),
                anchor: Anchor(
                    source: sessionID, turnID: uuid, contentHash: hash, span: lower..<upper))
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
