import Foundation
import LTMCore
import SQLite3
import LTMIndex
import LTMMemory
import LTMQuery

/// 索引背書的 `CorpusReader`，**預先載入**成值型別。
///
/// `LTMCore` 宣告了這個 protocol 並註明「實作住在 ingest 層」；這就是它。
/// projection 需要它把 anchor 還原成文字，才能判斷一筆使用歷史指的內容還在不在。
///
/// 為什麼是預載而不是包一個資料庫連線：
///
/// 1. `CorpusReader` 是 `Sendable`，而 SQLite 連線（`SQLITE_OPEN_NOMUTEX`）不是。
///    用 `@unchecked Sendable` 硬繞過去，就是把一個型別系統攔得住的資料競爭
///    改成靠註解自律。
/// 2. projection 會對**每一筆事件**的 anchor 呼叫一次；包連線等於在迴圈裡打
///    N 次資料庫，而需要的 turn 集合在進迴圈前就已經知道了。
///
/// 內容來源仍是索引（純衍生物），只是換成一次撈齊。
struct PreloadedCorpusReader: CorpusReader {
    /// 鍵是 `source` 與 `turnID` 的組合。用 NUL 當分隔字元：它不可能出現在
    /// `OpaqueIdentifier` 允許的字元集裡，所以兩個欄位不會黏成同一個鍵。
    private let turns: [String: Turn]

    init(turns: [String: Turn]) { self.turns = turns }

    static func key(source: String, turnID: String) -> String { "\(source)\u{0}\(turnID)" }

    func turn(id: String, inSource source: String) -> Turn? {
        turns[Self.key(source: source, turnID: id)]
    }

    /// 把指定的 (source, turnID) 一次撈齊。
    static func load(anchors: [Anchor], from database: IndexDatabase) throws -> PreloadedCorpusReader {
        var turns: [String: Turn] = [:]
        for anchor in Set(anchors) {
            try database.query(
                "SELECT role, timestamp, text FROM chunks WHERE uuid = ? AND session_id = ?",
                bind: [.text(anchor.turnID), .text(anchor.source)]
            ) { statement in
                let role = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                let timestamp = sqlite3_column_double(statement, 1)
                let text = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                turns[key(source: anchor.source, turnID: anchor.turnID)] = Turn(
                    id: anchor.turnID, role: role,
                    timestamp: Date(timeIntervalSince1970: timestamp), text: text)
            }
        }
        return PreloadedCorpusReader(turns: turns)
    }
}

/// LTMMemory 的語料守衛，注入給索引層。
///
/// 依賴反轉的另一端：判定的實作在 LTMMemory（`CorpusLocation`），需求宣告在
/// LTMIndex（`CorpusContainmentPolicy`），而 facade 是唯一同時看得到兩者的地方。
public struct MemoryCorpusPolicy: CorpusContainmentPolicy {
    public init() {}
    public func isInsideReadOnlyCorpus(_ url: URL) -> Bool {
        CorpusLocation.isInsideReadOnlyCorpus(url)
    }
}

/// 一筆回傳給呼叫端的結果。
///
/// 指標四欄 + 位移 + 理由。**檢索負責導航，不負責當答案**（不變式 3 的推論），
/// 所以 `snippet` 是原文片段而不是摘要——摘要會讓呼叫端以為它可以直接用。
public struct QueryHit: Sendable, Equatable {
    public let project: String
    public let sessionID: String
    public let uuid: String
    public let timestamp: Date
    public let snippet: String
    public let score: Double
    public let band: Int
    /// 相對於純檢索順序的位移（正數代表上移）。
    public let displacement: Int
    /// 這一筆自己的使用歷史狀態。
    public let historyDescription: String
    /// 實際發生的位移方向與幅度。
    public let movementDescription: String
    public let anchor: Anchor
}

/// 一次查詢的完整結果。
public struct QueryOutcome: Sendable {
    public let hits: [QueryHit]
    public let strategyID: String
    /// 這次查詢是否有把新內容併進索引（增量續讀）。
    public let refreshedSources: Int
    /// 寫了幾筆 `shown` 事件（未開啟記錄時為 0）。
    public let eventsRecorded: Int
}

/// 唯一同時看得到索引、策略與事件儲存的地方。
///
/// CLI 與（Stage 2 的）MCP server 都只是它的 adapter：adapter 翻譯輸入輸出，
/// 契約住在這裡。判準是刪除測試——刪掉 facade，兩個介面都斷；刪掉 CLI，
/// MCP 照常。
public struct LTMService {
    public let location: DerivedLocation
    public let corpusRoot: URL
    private let embedder: any EmbeddingProvider
    private let eventStore: (any EventStore)?

    public enum ServiceError: Error, Sendable, Equatable {
        /// 索引不存在。訊息一律指名 `ltm build`。
        case indexMissing(path: String)
        /// 索引裡的向量與目前的 embedding revision 不同代。
        ///
        /// **拒答而不是降級**：跨 revision 的 cosine 不會報錯，只會安靜地給出
        /// 無意義的距離。一個警告旁邊擺著看起來合理的結果，不會阻止那些結果
        /// 被採用。
        case embeddingRevisionMismatch(indexed: String, runtime: String)
        /// 索引的 layout 版本與這個 binary 不同。
        case layoutVersionMismatch(indexed: Int?, expected: Int)
        /// 無法決定查詢範圍，而且沒有明示要跨 project。
        case ambiguousScope(detail: String)
    }

    public init(
        location: DerivedLocation,
        corpusRoot: URL = CorpusLocation.readOnlyRoot,
        embedder: any EmbeddingProvider,
        eventStore: (any EventStore)? = nil
    ) {
        self.location = location
        self.corpusRoot = corpusRoot
        self.embedder = embedder
        self.eventStore = eventStore
    }

    /// 依預設路徑組出 facade（CLI 用）。
    public static func standard(
        embedder: any EmbeddingProvider, eventStore: (any EventStore)? = nil
    ) throws -> LTMService {
        LTMService(
            location: try DerivedLocation(policy: MemoryCorpusPolicy()),
            embedder: embedder, eventStore: eventStore)
    }

    // MARK: - 建置

    @discardableResult
    public func build(full: Bool = false) throws -> BuildReport {
        try IndexBuilder(
            location: location, scanner: CorpusScanner(corpusRoot: corpusRoot), embedder: embedder
        ).build(full: full)
    }

    // MARK: - 查詢

    /// 執行查詢。
    ///
    /// - Parameters:
    ///   - strategy: 省略時用 `archival`（不重排）。純檢索順序是檢查工具的誠實
    ///     預設；要看使用歷史的影響是明示的選擇。
    ///   - recordEvents: 是否寫 `shown` 事件。**預設不寫**——開發與檢查用的查詢
    ///     會污染策略比較所依據的使用歷史。
    public func query(
        text: String,
        limit: Int = 20,
        scope: RetrievalEngine.Scope,
        strategy: (any MemoryStrategy)? = nil,
        recordEvents: Bool = false,
        now: Date = Date()
    ) throws -> QueryOutcome {
        guard FileManager.default.fileExists(atPath: location.databaseURL.path) else {
            throw ServiceError.indexMissing(path: location.databaseURL.path)
        }
        let database = try IndexDatabase(path: location.databaseURL.path)
        defer { database.close() }

        let stamps = try database.stamps()
        guard stamps.layoutVersion == IndexDatabase.layoutVersion else {
            throw ServiceError.layoutVersionMismatch(
                indexed: stamps.layoutVersion, expected: IndexDatabase.layoutVersion)
        }
        guard let indexedRevision = stamps.embeddingRevision,
            indexedRevision == embedder.revision
        else {
            throw ServiceError.embeddingRevisionMismatch(
                indexed: stamps.embeddingRevision ?? "(無)", runtime: embedder.revision)
        }

        // 查詢時的 staleness 檢查：語料前進了就先把尾巴讀進來再回答。
        // 這裡**只做增量**——需要整份重建的情況（版本／revision 不符）在上面
        // 已經拒答了，不會走到這裡。
        let refreshed = try refreshIncrementally(database: database)

        let dimension = try database.meta("vector_dimension").flatMap(Int.init) ?? embedder.dimension
        let vectors = try? VectorSidecar.open(url: location.vectorsURL, dimension: dimension)
        let engine = RetrievalEngine(database: database, vectors: vectors, embedder: embedder)
        let scored = try engine.search(query: text, limit: limit, scope: scope)

        let chosen = strategy ?? ArchivalStrategy()
        let candidates = scored.map {
            Candidate(
                anchor: $0.anchor, baseScore: $0.fusedScore,
                band: RelevanceBand(rank: $0.fusedRank))
        }
        let projection = try makeProjection(database: database, strategy: chosen, now: now)
        let ranked = try chosen.rerank(candidates, with: projection)

        let byAnchor = Dictionary(uniqueKeysWithValues: scored.map { ($0.anchor, $0) })
        var hits: [QueryHit] = []
        for result in ranked {
            guard let source = byAnchor[result.candidate.anchor] else { continue }
            hits.append(
                QueryHit(
                    project: source.project, sessionID: source.sessionID, uuid: source.uuid,
                    timestamp: source.timestamp, snippet: source.text,
                    score: result.candidate.baseScore, band: result.candidate.band.rank,
                    displacement: result.displacement,
                    historyDescription: String(describing: result.reason.history),
                    movementDescription: String(describing: result.reason.movement),
                    anchor: result.candidate.anchor))
        }

        var recorded = 0
        if recordEvents, let eventStore {
            recorded = try record(
                kind: .shown, anchors: hits.map(\.anchor), policy: chosen.id, store: eventStore,
                now: now)
        }

        return QueryOutcome(
            hits: hits, strategyID: chosen.id.value, refreshedSources: refreshed,
            eventsRecorded: recorded)
    }

    /// 把語料的新增內容併進索引（查詢路徑上的增量續讀）。
    ///
    /// 回傳有新內容的來源檔數。整份重建需要的情況不在這裡處理——那是 `build`。
    private func refreshIncrementally(database: IndexDatabase) throws -> Int {
        let statePath = location.stateURL
        guard let data = try? Data(contentsOf: statePath),
            let previous = try? JSONDecoder().decode(ScanState.self, from: data)
        else { return 0 }
        let scan = try CorpusScanner(corpusRoot: corpusRoot).scan(previous: previous)
        guard !scan.chunks.isEmpty || !scan.invalidatedSources.isEmpty else { return 0 }

        var vectorRow = try database.meta("vector_count").flatMap(Int.init) ?? 0
        var newVectors: [[Float]] = []
        try database.transaction {
            for sourceKey in scan.invalidatedSources {
                try database.deleteChunks(sourceKey: sourceKey)
            }
            for (sourceKey, chunks) in Dictionary(grouping: scan.chunks, by: \.sourceKey)
                .sorted(by: { $0.key < $1.key })
            {
                let rowIDs = try database.insert(chunks: chunks, sourceKey: sourceKey)
                for (offset, chunk) in chunks.enumerated() {
                    guard let vector = try embedder.vector(for: chunk.text) else { continue }
                    newVectors.append(vector)
                    try database.execute(
                        "UPDATE chunks SET vector_row = ? WHERE id = ?",
                        bind: [.integer(Int64(vectorRow)), .integer(rowIDs[offset])])
                    vectorRow += 1
                }
            }
            try database.setMeta("vector_count", String(vectorRow))
        }
        if !newVectors.isEmpty {
            let handle: FileHandle
            if FileManager.default.fileExists(atPath: location.vectorsURL.path) {
                handle = try FileHandle(forWritingTo: location.vectorsURL)
            } else {
                FileManager.default.createFile(atPath: location.vectorsURL.path, contents: nil)
                handle = try FileHandle(forWritingTo: location.vectorsURL)
            }
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: VectorSidecar.encode(newVectors))
            try handle.synchronize()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try? encoder.encode(scan.state).write(to: statePath, options: [.atomic])
        return scan.chunks.isEmpty ? scan.invalidatedSources.count : scan.chunks.count
    }

    /// 把事件投影成策略要看的統計。
    ///
    /// 策略宣告它消費哪些事件種類；不消費任何事件的策略（`archival`）連讀都不讀
    /// ——省下的不只是時間，更是「它真的沒看使用歷史」這件事在程式碼上看得見。
    private func makeProjection(
        database: IndexDatabase, strategy: any MemoryStrategy, now: Date
    ) throws -> Projection {
        guard !strategy.consumedSignals.isEmpty, let eventStore else {
            // 不消費任何事件的策略（archival）連讀都不讀——省下的不只是時間，
            // 更是「它真的沒看使用歷史」這件事在程式碼上看得見。
            return project([], at: now, resolvedBy: PreloadedCorpusReader(turns: [:]))
        }
        let events = try eventStore.events(from: .distantPast, to: now)
        let reader = try PreloadedCorpusReader.load(anchors: events.map(\.anchor), from: database)
        return project(events, at: now, resolvedBy: reader)
    }

    /// 寫入一批事件。
    private func record(
        kind: EventKind, anchors: [Anchor], policy: RankingPolicyID, store: any EventStore,
        now: Date
    ) throws -> Int {
        let generation = GenerationID("g-\(Int(now.timeIntervalSince1970))")
        var written = 0
        for anchor in anchors {
            try store.append(
                Event(
                    kind: kind, anchor: anchor, timestamp: now, generation: generation,
                    policy: policy, noteRef: nil, presentation: nil))
            written += 1
        }
        return written
    }
}
