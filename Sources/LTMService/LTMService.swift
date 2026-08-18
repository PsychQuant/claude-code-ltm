import Foundation
import LTMCore
import SQLite3

/// 讀一個 TEXT 欄位，**用明確的 byte 長度**而不是 C-string 語意。
///
/// `String(cString:)` 在第一個 NUL 停下來，與寫入端 `bind_text(-1)` 是同一個截斷的
/// 兩端。兩邊都改才有意義：只改寫入端，讀出來的仍然是半截。
func columnText(_ statement: OpaquePointer, _ column: Int32) -> String {
    guard let raw = sqlite3_column_text(statement, column) else { return "" }
    let count = Int(sqlite3_column_bytes(statement, column))
    return String(decoding: UnsafeBufferPointer(start: raw, count: count), as: UTF8.self)
}
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
                // anchor.source 是 project 指紋，所以這裡用 project_fingerprint 比對，
                // 不是 session_id。
                "SELECT role, timestamp, text FROM chunks WHERE uuid = ? AND project_fingerprint = ?",
                bind: [.text(anchor.turnID), .text(anchor.source)]
            ) { statement in
                let role = columnText(statement, 0)
                let timestamp = sqlite3_column_double(statement, 1)
                let text = columnText(statement, 2)
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
/// 綁定「當下實際使用的語料根」的 containment 判定。
///
/// 先前這個型別只問固定的 `~/.claude/projects`，於是語料根被環境變數覆寫時，
/// 一個指向**正在被掃描的語料**的衍生根照樣通過檢查——而 code 註解當時寫著
/// 「覆寫不會放寬任何守衛」。那句話是假的。
///
/// 現在它同時保護兩者：預設語料根**與**這次實際使用的語料根。少任何一邊都有洞：
/// 只看預設 → 覆寫路徑沒守衛；只看當下 → 有人把 derived 指進預設語料。
public struct MemoryCorpusPolicy: CorpusContainmentPolicy {
    private let additionalRoots: [URL]

    public init(corpusRoots: [URL] = []) {
        self.additionalRoots = corpusRoots
    }

    public func isInsideReadOnlyCorpus(_ url: URL) -> Bool {
        if CorpusLocation.isInsideReadOnlyCorpus(url) { return true }
        return additionalRoots.contains { CorpusLocation.isInside(url, root: $0) }
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
    /// 這一筆是被哪幾條檢索通道找到的。
    ///
    /// 它同時是**解釋**（為什麼這筆會出現）與 **band 的來源**（見 retrieval spec
    /// 的 "A candidate's relevance band is the number of retrieval channels it
    /// matched"）。暴露它讓「band 從哪來」在輸出上看得見，而不是只能讀 code 推斷。
    public let channels: [String]
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
        /// 索引裡的 anchor 是用另一條 source 規則算的。
        ///
        /// **拒絕而非重新詮釋**：指紋不帶產生它的規則，把舊值拿去跟新規則比對，
        /// 要嘛解析到錯的 turn、要嘛報 orphan，兩者都與正確行為分不出來。
        case anchorSourceRuleMismatch(indexed: String, expected: String)
        /// 無法決定查詢範圍，而且沒有明示要跨 project。
        case ambiguousScope(detail: String)
        /// 側車檔的向量筆數與索引宣稱的不符。
        case vectorSidecarMismatch(declared: Int, found: Int)
        /// 某個要寫入的根落在語料裡。
        case rootInsideCorpus(path: String)
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

    /// 由 roots 參數化組出 facade。**CLI 與測試共用這一條路徑。**
    ///
    /// 先前有一個只有 production 走的 `standard()`，而 CLI 為了支援環境變數覆寫
    /// 自己另建一條——於是出貨的守衛零測試覆蓋（測試全都注入 stub policy），
    /// 而兩條路徑各自長出自己的 containment 缺陷。一條路徑，兩個呼叫端。
    public static func make(
        corpusRoot: URL,
        derivedRoot: URL,
        embedder: any EmbeddingProvider,
        eventStore: (any EventStore)? = nil,
        memoryRoot: URL? = nil
    ) throws -> LTMService {
        let policy = MemoryCorpusPolicy(corpusRoots: [corpusRoot])
        // **建立任何東西之前**先驗 memory root。`FileEventStore` 事後會拒絕語料內的
        // 路徑，但目錄那時已經建好了——違反不變式 1 的是那個 mkdir，不是 append。
        if let memoryRoot, policy.isInsideReadOnlyCorpus(memoryRoot) {
            throw ServiceError.rootInsideCorpus(path: memoryRoot.path)
        }
        return LTMService(
            location: try DerivedLocation(root: derivedRoot, policy: policy),
            corpusRoot: corpusRoot, embedder: embedder, eventStore: eventStore)
    }

    // MARK: - 建置

    @discardableResult
    public func build(full: Bool = false) throws -> BuildReport {
        try IndexBuilder(
            location: location, scanner: CorpusScanner(corpusRoot: corpusRoot), embedder: embedder
        ).build(full: full)
    }

    /// 一筆候選的相關度帶：命中越多通道，帶越高（數值越小）。
    ///
    /// 單一來源——先前這個算式散在候選建構處，而排序也需要它，複製一份就會漂移。
    /// 通道總數不寫死：`ScoredChunk.Channel.allCases.count` 讓第四條通道加入時
    /// 不會靜默產生負數帶。
    static func band(for chunk: ScoredChunk) -> Int {
        ScoredChunk.Channel.allCases.count - chunk.channels.count
    }

    /// 依 band 分層排序，帶內維持融合次序。
    ///
    /// 抽成具名函式而不是 inline 排序：它承載一個**前置條件**（seam 要求同帶是
    /// 單一連續區段），而前置條件需要能被單獨測到——inline 的話，唯一的測試途徑
    /// 是碰巧構造出會觸發的語料。
    public static func layered(_ chunks: [ScoredChunk]) -> [ScoredChunk] {
        chunks.sorted { lhs, rhs in
            let lb = band(for: lhs), rb = band(for: rhs)
            return lb == rb ? lhs.fusedRank < rhs.fusedRank : lb < rb
        }
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

        let indexedRule = stamps.anchorSourceRule ?? "(無)"
        guard indexedRule == IndexDatabase.anchorSourceRule else {
            throw ServiceError.anchorSourceRuleMismatch(
                indexed: indexedRule, expected: IndexDatabase.anchorSourceRule)
        }

        // 查詢時的 staleness 檢查：語料前進了就先把尾巴讀進來再回答。
        // 這裡**只做增量**——需要整份重建的情況（版本／revision 不符）在上面
        // 已經拒答了，不會走到這裡。
        let refreshed = try refreshIncrementally(database: database)

        let dimension = try database.meta("vector_dimension").flatMap(Int.init) ?? embedder.dimension
        let declaredVectors = try database.meta("vector_count").flatMap(Int.init) ?? 0
        // 側車與索引宣稱的筆數必須對得上。
        //
        // 先前這裡是 `try? VectorSidecar.open(...)`，於是側車遺失或被截斷時 `vectors`
        // 變成 nil、`vectorRanking` 直接回空陣列——檢索**靜默降級成 lexical-only**。
        // 那與這份 code 自己在別處的宣示直接衝突：tokenizer 不可用時大聲中止，
        // 向量不可用時卻無聲。少一路通道的結果看起來完全正常，這正是不能靜默的理由。
        var vectors: VectorSidecar?
        if declaredVectors > 0 {
            guard let opened = try? VectorSidecar.open(url: location.vectorsURL, dimension: dimension),
                opened.count == declaredVectors
            else {
                throw ServiceError.vectorSidecarMismatch(
                    declared: declaredVectors,
                    found: (try? VectorSidecar.open(url: location.vectorsURL, dimension: dimension))?
                        .count ?? 0)
            }
            vectors = opened
        }
        let engine = RetrievalEngine(database: database, vectors: vectors, embedder: embedder)
        let scored = try engine.search(query: text, limit: limit, scope: scope)

        let chosen = strategy ?? ArchivalStrategy()

        // **候選必須先依 band 分層排序，再送進 seam。**
        //
        // `MemoryStrategySupport.requireBandsInOrder` 要求「同一個帶在輸入裡是單一
        // 連續區段」——那是圍籬能成立的前提（逐位比對驗帶只在該前提下等價於
        // 「不得跨帶移動」）。而融合分數與通道數**不單調相關**：一個命中兩條通道
        // 但各通道名次都很前的候選，分數可以高於命中三條卻名次都很深的候選。
        //
        // 少了這一步，`ltm query` 會直接失敗。實測（99 個真實 project、k=20）：
        // 15 個查詢中 1 個回 `bandsOutOfOrder(at: 3)`，exit 非零。band 改成分層之前
        // （band = 融合名次，嚴格遞增）這個前置條件永遠不可能 fire，所以這是 band
        // 改動**新引入**的失敗，不是既有缺陷。
        //
        // 排序本身也是語意上正確的：band 是相關度分層，高帶的候選本就該在前面；
        // 融合分數只決定**帶內**次序。這就是「相關度主導提取、使用強度只做微調」
        // 在檢索層的樣子。
        let layered = LTMService.layered(scored)
        // band 是**相關度分層**，不是名次。
        //
        // 先前這裡填的是 `fusedRank`，於是每個候選自成一帶，「同帶內的其他候選」
        // 恆為空集合，任何策略都無處可移——而且是**靜默**的：沒有跨帶嘗試，
        // `RankingGuard` 不會 fire，`human-like` 與 `archival` 逐字相同。
        //
        // 改用命中的通道數分層（多重編碼：多條線索都指向它 ⇒ 相關度證據更強）。
        // 這個規則零參數——本專案在評估集（#16）出現之前沒有東西可以校準桶數或
        // 分數邊界，而把未校準的參數寫進出貨的 spec 正是誠實邊界要擋的事。
        //
        // 帶內分佈已量測：`docs/measurements/2026-08-17-band-population.md`。
        let candidates = layered.map {
            Candidate(
                anchor: $0.anchor, baseScore: $0.fusedScore,
                band: RelevanceBand(rank: LTMService.band(for: $0)))
        }
        let projection = try makeProjection(database: database, strategy: chosen, now: now)
        let ranked = try chosen.rerank(candidates, with: projection)

        let byAnchor = Dictionary(layered.map { ($0.anchor, $0) }, uniquingKeysWith: { first, _ in first })
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
                    anchor: result.candidate.anchor,
                    channels: source.channels.map(\.rawValue).sorted()))
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
        // 這條路徑**是寫者**：它改 SQLite、append 側車、覆寫 state。所以它必須拿
        // 與 `IndexBuilder` 同一把單寫者鎖。
        //
        // 先前只有 build 拿鎖，於是兩個並行的 `ltm query`（或 query 與 build 重疊）
        // 會各自讀到同一份舊 state、各自配置 vector row、各自 append 側車——即使
        // SQLite 把交易序列化，**側車 append 的先後與 DB 配置 row 的先後不保證一致**，
        // 結果是某個 chunk 的 `vector_row` 指向別人的向量。WAL 涵蓋不到外部側車檔。
        //
        // 拿不到鎖時**不等待也不失敗**：查詢仍可用既有索引回答，只是這一輪不併入
        // 新內容。這與 build 不同——build 的工作就是寫入，拿不到鎖必須明確失敗。
        let lock: FileLock
        do {
            lock = try FileLock.acquire(at: location.lockURL)
        } catch {
            return 0
        }
        defer { lock.release() }

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
