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
        let refreshed = try refreshIncrementally()

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

        // 檢索**已經**以 band-major 順序回傳（`RetrievalEngine.search`），所以
        // 這裡逐筆映射、不重排。
        //
        // 「不重排」是字面的：retrieval spec 的 requirement 寫
        // 「SHALL NOT reorder outside that seam」，而它的 scenario 要求
        // 「the emitted order equals the fused retrieval order」。分層曾經在這裡做
        // ——那就是 seam 之外的重排，即使排序規則本身是對的。
        //
        // 分帶與排帶屬於檢索而不是策略，理由不是美學：`MemoryStrategy` 的前置條件
        // `requireBandsInOrder` 要求候選**到達時**已經分好帶。一個 seam 要求它的
        // 輸入具備某個性質，那個性質就是輸入方的職責。
        let candidates = scored.map {
            Candidate(
                anchor: $0.anchor, baseScore: $0.fusedScore,
                band: RelevanceBand(rank: $0.band))
        }
        let projection = try makeProjection(database: database, strategy: chosen, now: now)
        let ranked = try chosen.rerank(candidates, with: projection)

        let byAnchor = Dictionary(scored.map { ($0.anchor, $0) }, uniquingKeysWith: { first, _ in first })
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
    /// 回傳有新內容的來源檔數。
    ///
    /// ## 為什麼是委派而不是自己寫一份
    ///
    /// 這裡曾經有一份**平行的**寫入實作：自己算向量、自己配 row、自己 append
    /// 側車、自己覆寫 state。它與 `IndexBuilder` 做同一件事，卻是兩份程式碼——
    /// 於是修好其中一份不會修好另一份，而且不會有任何訊號。
    ///
    /// 實際發生過：`IndexBuilder` 的寫入順序被改成「側車先落地並 fsync、之後
    /// 才提交指向它的指標」，這一份沒有跟著改，仍然是先提交 `vector_count` 再
    /// append。崩在兩者之間會留下「DB 宣稱 N 個向量、檔案只有 N−k 個」，而
    /// 查詢路徑的側車核對會就此拒答，直到使用者跑 `ltm build --full`。這一份
    /// 也沒有 `truncateSidecar`，所以殘留的多餘 bytes 永遠不會被清掉。
    ///
    /// 兩個寫者就是兩份會漂移的規格。刪掉一份是唯一不會再漂移的修法。
    ///
    /// ## 兩處刻意的差異
    ///
    /// - **拿不到鎖不失敗**：查詢仍可用既有索引回答，只是這一輪不併入新內容。
    ///   `build` 相反——它的工作就是寫入，拿不到鎖必須明確失敗。
    /// - **不可能觸發整份重建**：`query` 在呼叫這裡之前已經檢查過 layout 版本、
    ///   embedding revision 與 anchor 定址規則，三者不符都已拒答。所以
    ///   `build()` 內的 `stampsMismatch` 分支在這條路徑上到不了。
    private func refreshIncrementally() throws -> Int {
        let builder = IndexBuilder(
            location: location, scanner: CorpusScanner(corpusRoot: corpusRoot), embedder: embedder)
        do {
            return try builder.build().sourcesRefreshed
        } catch IndexBuilder.BuildError.lockHeld {
            return 0
        }
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
