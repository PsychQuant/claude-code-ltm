import Foundation
import SQLite3
import Testing

@testable import LTMCore
@testable import LTMIndex

// 不變式 2 的性質測試：**任何**語料變異序列之後，增量索引與全量重建的可觀察狀態相同。
//
// ## 為什麼是性質測試而不是再多幾條個案
//
// `/idd-verify #24` 跑了三輪，四個 findings 是同一條不變式的不同破法：
//
// | 破法 | 哪一輪抓到 | 怎麼抓到的 |
// |---|---|---|
// | 刪掉一個來源會刪掉別的來源還持有的 turn | round-2 | 人構造反例 |
// | 活下來的 chunk 指標凍結在被刪的來源上 | round-3 | 人構造反例 |
// | FTS 文件計數隨作廢單調膨脹 | round-3 | 人構造反例 |
// | 首建就多算 FTS 文件（去重路徑不冪等） | round-3 | 人構造反例 |
//
// 四次都是靠人**臨場想到**一個反例。想不到的那些沒有任何機制會發現——而每一次
// 「我覺得修好了」的準確率到目前為止是 0/3。
//
// 所以這裡不再補第五條個案，而是把不變式本身寫成可執行的性質：隨機生成變異序列、
// 增量跑一遍、全量重建一遍、比對。破法不需要被想到，只需要被生成。
//
// ## 比較的是「可觀察狀態」，不是位元組
//
// 有些差異是合法的，把它們算進去會讓測試對真缺陷失去鑑別力：
//
// - **`chunks.id`（rowid）**：配置順序相依。anchor 不用 rowid 定址（用內容指紋 +
//   turn 識別碼 + 內容雜湊），所以它不是身分的一部分。
// - **`vector_row`**：側車的索引值。它指向的**向量內容**必須相同，值本身不必。
// - **側車檔長度與 `vector_count`**：增量不回收被刪 chunk 的向量槽，所以檔案會比
//   全量重建長。只要每個 chunk 解參考到的向量正確，這個差異不可觀察。
//
// 剩下的都必須相同——包括 FTS5 的內部統計，因為 bm25 的 idf 與 avgdl 是**全域**的：
// 文件計數歪一格，整份索引的每一次 lexical 查詢名次都跟著歪，而名次進 RRF、
// RRF 決定帶內次序。那是可觀察的。
//
// ## 這個性質測試**不**涵蓋什麼
//
// 寫下來是因為「有性質測試了」很容易被讀成「不變式 2 已經被守住了」。它守住的是
// 生成器走得到的那一塊，不是全部：
//
// - **同一則 turn 在兩個來源裡文字不同**。生成器對同一個 identity 永遠產生相同的
//   文字（真實 resume 也是複製，所以這是主要情形）。但檔案截斷、寫入中斷都可能
//   讓兩份不一致，而 `text` / `anchor_hash` 目前是「最後寫的贏」且**不會**在來源
//   被刪除後重算——那條路徑沒有被生成到，也就沒有被守住。
// - **讀不到的來源**（權限、I/O 錯誤）。生成器只會建立、改寫、追加、刪除、resume，
//   不會讓一個檔變成讀不到。目錄層級的列舉失敗同理（#26）。
// - **並發寫入**。單執行緒依序套用變異。
// - **真實 embedder**。用 `StubEmbedder`，所以向量比對驗的是「同樣的文字得到同樣的
//   向量、且 `vector_row` 解參考正確」，不是 `NLContextualEmbedding` 的行為。
// - **崩潰中止**。沒有在建置中途殺掉行程再續跑。
// **上面四條已於 #29 關閉**（三個 project、`chunk_sources.timestamp` 與 `state.json`
// 進 `Snapshot`、每個檔混入四種跳過行、`ORDER BY` 拿掉 `c.uuid` 改成按分數分組）。
// 各自的變異驗證：唯一鍵退回 `uuid` 單獨 → 紅 100；跳過分類漂移 → 紅 100；
// 續讀位置忘了加 `startOffset` → 紅 92；分組換成裸順序 → 紅 80。
//
// 最後那個數字是這次最有資訊的一條：**rowid 造成的組內名次分岔真實且普遍**
// （100 個 seed 裡 80 個），而舊的 `c.uuid` 決勝把它整個遮住。分組正好容忍那一層、
// 同時保留跨 tie 的比對。
//
// **仍然不涵蓋的**：
//
// - **常數性的錯誤**。這是等價性測試的固有限制——它比的是增量與全量，所以一個
//   對兩側都一樣的錯誤看不見。實測：把 `chunk_sources.timestamp` 寫死 0，100 個
//   seed 全綠。`timestamp` 進 `Snapshot` 買到的是**路徑相依**的分岔，不是正確性。
// - **`ON CONFLICT(chunk_id, source_key) DO UPDATE` 那條路徑**。拿掉它的
//   `timestamp=excluded.timestamp` 之後 100 個 seed 全綠——這個生成器似乎產不出
//   同一個 `(chunk_id, source_key)` 被插入兩次的情形。那條 SQL 目前無人守。
// - **跨 tie 的名次分岔**。分組讓它**可見**，但我沒能構造出一個會產生它的變異
//   （那需要生產端的排序真的分岔），所以「分組抓得到跨 tie 分岔」這半仍未驗證。
//
// 要加涵蓋範圍，加的是**變異種類**（生成器）或**比較面向**（`Snapshot`），不是
// 再寫一條個案測試。這是這個檔案存在的理由。

// MARK: - 可重現的隨機

/// xorshift64。**種子式**——性質測試的失敗必須能用同一個種子重跑。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // 0 是 xorshift 的吸收態，會讓整條序列變成常數。
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        if state == 0 { state = 0x9E37_79B9_7F4A_7C15 }
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - 語料變異

/// 一則 turn 的身分與內容。同一個 `identity` 可以出現在多個檔（那就是 resume）。
private struct TurnSpec {
    let identity: Int
    let session: String
    let timestampOffset: Int

    var uuid: String { String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", identity) }
    var text: String { "第\(identity)則內容 keyword\(identity % 4) 共通詞" }
    var timestamp: String {
        let base = Date(timeIntervalSince1970: 1_770_000_000 + Double(timestampOffset) * 60)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: base)
    }

    var line: String {
        turnLine(uuid: uuid, session: session, role: "user", text: text, timestamp: timestamp)
    }
}

/// **會被跳過的行**（#29 缺口 3）。
///
/// 生成語料先前 0% 是跳過行，而真實語料是 **46%**（677,913 解析 / 583,924 跳過，
/// 見 `docs/measurements/2026-08-18-resume-duplication.md`）。跳過路徑與它的分類
/// 計數因此在這個性質測試裡零覆蓋。
///
/// 四種各自打到 `SkipTally` 的不同欄位——**分類本身也要在增量與全量之間相同**，
/// 否則「跳過的理由」會靜默漂移。
private enum SkipLine: CaseIterable {
    case notATurn
    case missingPointerField
    case malformedIdentifier
    case unparseableLine

    var text: String {
        switch self {
        case .notATurn:
            return #"{"type":"queue-operation","payload":{"op":"noop"}}"#
        case .missingPointerField:
            return #"{"type":"user","message":{"role":"user","content":"缺 uuid 的一行"}}"#
        case .malformedIdentifier:
            return #"{"uuid":"not-a-uuid","sessionId":"also-not","timestamp":"2026-08-17T06:00:00Z","type":"user","message":{"role":"user","content":"識別碼形狀不對"}}"#
        case .unparseableLine:
            return "{ this is not json"
        }
    }
}

private enum Mutation: CustomStringConvertible {
    case createFile(name: String, turns: [Int])
    /// 整份改寫（前綴雜湊不符 → 該來源被作廢並整份重解）。
    case rewriteFile(name: String, turns: [Int])
    /// 追加（前綴對得上 → 只讀尾巴）。
    case appendTurn(name: String, turn: Int)
    case deleteFile(name: String)
    /// session resume：把既有檔的一部分複製進新檔，換一個 sessionId。
    case resumeCopy(from: String, to: String)

    var description: String {
        switch self {
        case .createFile(let n, let t): return "create(\(n), \(t))"
        case .rewriteFile(let n, let t): return "rewrite(\(n), \(t))"
        case .appendTurn(let n, let t): return "append(\(n), #\(t))"
        case .deleteFile(let n): return "delete(\(n))"
        case .resumeCopy(let f, let t): return "resume(\(f) → \(t))"
        }
    }
}

/// 語料的當下狀態（檔名 → turn 序列）。用它產生變異，也用它把檔案寫到磁碟。
private struct CorpusModel {
    var files: [String: [TurnSpec]] = [:]
    /// 每個檔屬於哪個 project（#29 缺口 1）。
    ///
    /// 先前所有檔都在同一個 project 底下，所以複合唯一鍵
    /// `(project_fingerprint, uuid)` 的「**跨 project 同 uuid 不得合併**」這一半
    /// 完全沒被驗證過——而那正是引入複合鍵那次改動的核心。
    var fileProjects: [String: String] = [:]
    private var sessionCounter = 0

    mutating func nextSession() -> String {
        sessionCounter += 1
        return String(format: "%08x-1111-2222-3333-444444444444", sessionCounter)
    }
}

// MARK: - 索引快照

private struct ChunkRow: Equatable, Comparable {
    let fingerprint: String
    let uuid: String
    let project: String
    let role: String
    let text: String
    let timestamp: Double
    let anchorHash: String
    let spanLower: Int
    let spanUpper: Int
    /// **解參考之後**的向量，不是 `vector_row`。
    let vector: [Float]?

    static func < (a: ChunkRow, b: ChunkRow) -> Bool {
        (a.fingerprint, a.uuid) < (b.fingerprint, b.uuid)
    }
}

private struct Snapshot {
    var chunks: [ChunkRow]
    var links: [String]
    /// 兩張 FTS5 表的 averages 紀錄原文（含全域文件計數與平均長度）。
    var ftsAverages: [String]
    /// 每條 lexical 通道對每個探針查詢的名次序列。
    var lexicalRanks: [String]
    /// `state.json` 的內容（#29 缺口 2）。
    ///
    /// 續讀位置錯了不會影響**這一輪**的索引內容，但會影響**下一輪**——而下一輪的
    /// 錯誤看起來會像是語料自己變了。把它納入比對，讓那個錯誤在發生的那一輪就
    /// 被看見，而不是在下一輪被誤診。
    var scanState: [String]
}

private func snapshot(_ location: DerivedLocation, probes: [String]) throws -> Snapshot {
    let database = try IndexDatabase(path: location.databaseURL.path)
    defer { database.close() }

    let dimension = try database.meta("vector_dimension").flatMap(Int.init) ?? 4
    let sidecar = (try? VectorSidecar.open(url: location.vectorsURL, dimension: dimension))

    var chunks: [ChunkRow] = []
    try database.query(
        """
        SELECT project_fingerprint, uuid, project, role, text, timestamp,
               anchor_hash, anchor_span_lower, anchor_span_upper, vector_row
        FROM chunks
        """
    ) { statement in
        func str(_ i: Int32) -> String {
            sqlite3_column_text(statement, i).map { String(cString: $0) } ?? ""
        }
        let row =
            sqlite3_column_type(statement, 9) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(statement, 9))
        chunks.append(
            ChunkRow(
                fingerprint: str(0), uuid: str(1), project: str(2),
                role: str(3), text: str(4),
                timestamp: sqlite3_column_double(statement, 5),
                anchorHash: str(6),
                spanLower: Int(sqlite3_column_int64(statement, 7)),
                spanUpper: Int(sqlite3_column_int64(statement, 8)),
                vector: row.flatMap { sidecar?.vector(at: $0) }))
    }

    var links: [String] = []
    // **`session_id` 在這裡比對**（#25，layout 5）。它先前是 `chunks` 的欄位、
    // 由 `ChunkRow` 涵蓋；現在導航的 session 只住在 `chunk_sources`，所以覆蓋
    // 必須跟著搬過來，否則刪掉 `ChunkRow.sessionID` 等於靜默移除 session 的
    // 不變式 2 覆蓋。（本檔頂端「不比對 chunk_sources 的 session_id」那條
    // 已知限制因此只剩 `timestamp`。）
    // **`timestamp` 也在這裡比對**（#29 缺口 2）。導航欄位是從連結重算的，所以
    // 「連結的值錯了、但重算結果碰巧相同」這一類分岔，只比對重算結果看不見。
    try database.query(
        "SELECT chunk_id, source_key, session_id, timestamp FROM chunk_sources"
    ) { statement in
        // chunk_id 是 rowid，跨兩份索引不可比——換成該 chunk 的身分。
        links.append(
            "\(sqlite3_column_int64(statement, 0))|\(String(cString: sqlite3_column_text(statement, 1)))"
                + "|\(String(cString: sqlite3_column_text(statement, 2)))"
                + "|\(sqlite3_column_double(statement, 3))")
    }
    // 把 rowid 換成 (fingerprint, uuid)。
    var identityByRowID: [Int64: String] = [:]
    try database.query("SELECT id, project_fingerprint, uuid FROM chunks") { statement in
        identityByRowID[sqlite3_column_int64(statement, 0)] =
            "\(String(cString: sqlite3_column_text(statement, 1)))|\(String(cString: sqlite3_column_text(statement, 2)))"
    }
    links = links.map { entry in
        let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
        let identity = Int64(parts[0]).flatMap { identityByRowID[$0] } ?? "(orphan-link)"
        return "\(identity)|\(parts[1])"
    }.sorted()

    var averages: [String] = []
    for table in ["chunks_trigram", "chunks_segment"] {
        var value = "(none)"
        try database.query("SELECT quote(block) FROM \(table)_data WHERE id = 1") { statement in
            value = String(cString: sqlite3_column_text(statement, 0))
        }
        averages.append("\(table)=\(value)")
    }

    var ranks: [String] = []
    for table in ["chunks_trigram", "chunks_segment"] {
        for probe in probes {
            let pattern = RetrievalEngine.ftsPhrase(
                table == "chunks_segment" ? Segmentation.segment(probe) : probe)
            guard !pattern.isEmpty else { continue }
            // **`ORDER BY` 不再帶 `c.uuid` 決勝**（#29 缺口 4）。那個決勝是為了讓
            // 比對穩定，代價是 **bm25 同分時 rowid 造成的名次分岔在這裡看不到**
            // ——而 rowid 正是增量與全量重建之間最會不同的東西。
            //
            // 改成**按分數分組**：同分的一組比集合（容忍 rowid 造成的組內順序），
            // 組與組之間比順序（抓得到跨 tie 的分岔）。兩者缺一：只比集合會漏掉
            // 名次錯亂，只比順序會被 rowid 的無害差異吵死。
            var grouped: [(score: Double, uuids: Set<String>)] = []
            try database.query(
                """
                SELECT c.uuid, bm25(\(table)) AS s FROM \(table) f JOIN chunks c ON c.id = f.rowid
                WHERE f.\(table) MATCH ? ORDER BY s DESC
                """, bind: [.text(pattern)]
            ) { statement in
                let uuid = String(cString: sqlite3_column_text(statement, 0))
                let score = sqlite3_column_double(statement, 1)
                if var last = grouped.last, last.score == score {
                    last.uuids.insert(uuid)
                    grouped[grouped.count - 1] = last
                } else {
                    grouped.append((score: score, uuids: [uuid]))
                }
            }
            let rendered = grouped.map { "{\($0.uuids.sorted().joined(separator: ","))}" }
                .joined(separator: ">")
            ranks.append("\(table)/\(probe) → \(rendered)")
        }
    }

    var scanState: [String] = []
    if let data = try? Data(contentsOf: location.stateURL),
        let decoded = try? JSONDecoder().decode(ScanState.self, from: data)
    {
        scanState = decoded.files.map { "\($0.key)|\($0.value.prefixHash)|\($0.value.processedBytes)" }
            .sorted()
    }

    return Snapshot(
        chunks: chunks.sorted(), links: links, ftsAverages: averages, lexicalRanks: ranks,
        scanState: scanState)
}

/// 兩份快照的差異，逐面向命名——「不相等」對這個測試沒有用，要說出哪一面不相等。
private func divergences(incremental a: Snapshot, fullRebuild b: Snapshot) -> [String] {
    var out: [String] = []

    let aIDs = a.chunks.map { "\($0.fingerprint.prefix(8))/\($0.uuid.prefix(8))" }
    let bIDs = b.chunks.map { "\($0.fingerprint.prefix(8))/\($0.uuid.prefix(8))" }
    if aIDs != bIDs {
        out.append("chunk 集合不同：增量 \(aIDs) vs 全量 \(bIDs)")
    } else {
        for (x, y) in zip(a.chunks, b.chunks) where x != y {
            var fields: [String] = []
            if x.text != y.text { fields.append("text") }
            if x.anchorHash != y.anchorHash { fields.append("anchor_hash") }
            if x.timestamp != y.timestamp { fields.append("timestamp") }
            if x.role != y.role { fields.append("role") }
            if x.project != y.project { fields.append("project") }
            if x.spanLower != y.spanLower || x.spanUpper != y.spanUpper { fields.append("span") }
            if x.vector != y.vector { fields.append("vector(解參考後)") }
            out.append("chunk \(x.uuid.prefix(8)) 欄位不同：\(fields.joined(separator: ", "))")
        }
    }

    if a.links != b.links {
        out.append("chunk_sources 不同：增量 \(a.links) vs 全量 \(b.links)")
    }
    if a.ftsAverages != b.ftsAverages {
        out.append("FTS 全域統計不同：增量 \(a.ftsAverages) vs 全量 \(b.ftsAverages)")
    }
    if a.lexicalRanks != b.lexicalRanks {
        let diff = zip(a.lexicalRanks, b.lexicalRanks).filter { $0 != $1 }
        out.append("lexical 名次不同：\(diff.map { "增量[\($0.0)] 全量[\($0.1)]" }.joined(separator: " ; "))")
    }
    if a.scanState != b.scanState {
        let diff = Set(a.scanState).symmetricDifference(Set(b.scanState)).sorted()
        out.append("state.json 不同（#29 缺口 2）：續讀位置或 prefixHash 分岔 —— \(diff)")
    }
    return out
}

// MARK: - 性質

private struct EquivalencePolicy: CorpusContainmentPolicy {
    func isInsideReadOnlyCorpus(_ url: URL) -> Bool { false }
}

/// 生成一條變異序列，並在磁碟上逐步套用；每一步之後跑一次增量建置。
/// 回傳 (語料根, 增量衍生根, 套用過的序列)。
private func runIncremental(
    seed: UInt64, steps: Int, embedder: StubEmbedder
) throws -> (corpus: URL, derived: DerivedLocation, trace: [Mutation]) {
    var rng = SeededGenerator(seed: seed)
    let corpus = FileManager.default.temporaryDirectory
        .appendingPathComponent("equiv-corpus-\(seed)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    let derived = try DerivedLocation(
        root: FileManager.default.temporaryDirectory
            .appendingPathComponent("equiv-derived-\(seed)-\(UUID().uuidString)"),
        policy: EquivalencePolicy())

    var model = CorpusModel()
    var trace: [Mutation] = []
    // **三個 project**（#29 缺口 1）。檔名決定它落在哪一個，所以同一個 identity
    // 出現在不同 project 的檔裡時，跨 project 同 uuid 就自然發生了。
    let projects = ["proj-alpha", "proj-beta", "proj-gamma"]

    func flush(_ name: String) throws {
        let turns = model.files[name] ?? []
        let project = model.fileProjects[name] ?? projectFor(name)
        // **每個檔混入全部四種跳過行**（#29 缺口 3）。
        //
        // 第一版是「種類由檔名決定，一個檔一種」，而那對**檔數少的 seed 蓋不到四種**
        // ——實測 seed 99/100 就漏掉兩種。四種都放才讓覆蓋不依賴變異序列碰巧產生
        // 幾個檔。
        //
        // 這也更貼近真實語料：跳過行佔 46%（677,913 解析 / 583,924 跳過，見
        // `docs/measurements/2026-08-18-resume-duplication.md`），不是零星。
        _ = try writeSession(
            in: corpus, project: project, file: name,
            lines: SkipLine.allCases.map(\.text) + turns.map(\.line))
    }
    /// 由檔名取出確定性的序號（`f12.jsonl` → 12）。**不是 `hashValue`**：
    /// Swift 的 `String.hashValue` 每個 process 隨機種子化（`CLAUDE.md` 記過的坑），
    /// 用它會讓同一份 trace 在不同執行給出不同語料，而症狀是「偶爾成功」。
    func fileIndex(_ name: String) -> Int {
        Int(name.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })) ?? 0
    }
    func projectFor(_ name: String) -> String { projects[fileIndex(name) % projects.count] }

    func build() throws {
        _ = try IndexBuilder(
            location: derived, scanner: CorpusScanner(corpusRoot: corpus), embedder: embedder
        ).build()
    }

    // 起手一定要有東西可以變異。
    let first = "f0.jsonl"
    model.files[first] = (0..<3).map {
        TurnSpec(identity: $0, session: model.nextSession(), timestampOffset: $0)
    }
    model.fileProjects[first] = projectFor(first)
    trace.append(.createFile(name: first, turns: [0, 1, 2]))
    try flush(first)
    try build()

    for step in 0..<steps {
        let names = model.files.keys.sorted()
        let choice = Int.random(in: 0..<5, using: &rng)
        let mutation: Mutation

        switch choice {
        case 0:
            let name = "f\(step + 1).jsonl"
            // 刻意讓 identity 與既有檔重疊——多來源持有同一則 turn 是常態不是特例。
            let turns = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                Int.random(in: 0..<6, using: &rng)
            }
            model.files[name] = turns.map {
                TurnSpec(identity: $0, session: model.nextSession(),
                         timestampOffset: Int.random(in: 0..<6, using: &rng))
            }
            model.fileProjects[name] = projectFor(name)
            mutation = .createFile(name: name, turns: turns)
            try flush(name)

        case 1 where !names.isEmpty:
            let name = names[Int.random(in: 0..<names.count, using: &rng)]
            let turns = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                Int.random(in: 0..<6, using: &rng)
            }
            model.files[name] = turns.map {
                TurnSpec(identity: $0, session: model.nextSession(),
                         timestampOffset: Int.random(in: 0..<6, using: &rng))
            }
            model.fileProjects[name] = projectFor(name)
            mutation = .rewriteFile(name: name, turns: turns)
            try flush(name)

        case 2 where !names.isEmpty:
            let name = names[Int.random(in: 0..<names.count, using: &rng)]
            let identity = Int.random(in: 0..<6, using: &rng)
            model.files[name, default: []].append(
                TurnSpec(identity: identity, session: model.nextSession(),
                         timestampOffset: Int.random(in: 0..<6, using: &rng)))
            mutation = .appendTurn(name: name, turn: identity)
            try flush(name)

        case 3 where names.count > 1:
            let name = names[Int.random(in: 0..<names.count, using: &rng)]
            let owning = model.fileProjects[name] ?? projectFor(name)
            model.files.removeValue(forKey: name)
            model.fileProjects.removeValue(forKey: name)
            mutation = .deleteFile(name: name)
            try FileManager.default.removeItem(
                at: corpus.appendingPathComponent(owning).appendingPathComponent(name))

        default:
            // resume：既有檔的內容複製進新檔，換 sessionId。timestamp 保持不變
            // ——真實 resume 複製的是同一則 turn，它的時間戳不會因為被複製而改變。
            guard let source = names.first(where: { !(model.files[$0] ?? []).isEmpty }) else {
                continue
            }
            let target = "r\(step + 1).jsonl"
            let session = model.nextSession()
            model.files[target] = (model.files[source] ?? []).map {
                TurnSpec(identity: $0.identity, session: session, timestampOffset: $0.timestampOffset)
            }
            mutation = .resumeCopy(from: source, to: target)
            try flush(target)
        }

        trace.append(mutation)
        try build()
    }
    return (corpus, derived, trace)
}

@Test(
    "性質：任何語料變異序列之後，增量索引與全量重建的可觀察狀態相同（不變式 2）",
    arguments: [UInt64](1...100))
func incrementalMatchesFullRebuild(seed: UInt64) throws {
    let embedder = StubEmbedder(revision: "r1")
    let probes = ["共通詞", "keyword0", "keyword1", "keyword2", "keyword3"]

    let run = try runIncremental(seed: seed, steps: 12, embedder: embedder)
    defer {
        try? FileManager.default.removeItem(at: run.corpus)
        try? FileManager.default.removeItem(at: run.derived.root)
    }

    // 同一份語料、乾淨的衍生根 → 全量重建。這就是不變式 2 的字面意思：
    // `rm -rf ~/.claude-ltm/derived && ltm build`。
    let fullRoot = try DerivedLocation(
        root: FileManager.default.temporaryDirectory
            .appendingPathComponent("equiv-full-\(seed)-\(UUID().uuidString)"),
        policy: EquivalencePolicy())
    defer { try? FileManager.default.removeItem(at: fullRoot.root) }
    let fullReport = try IndexBuilder(
        location: fullRoot, scanner: CorpusScanner(corpusRoot: run.corpus), embedder: embedder
    ).build()

    // **跳過的分類也要相同**（#29 缺口 3）。生成語料現在每個檔都混入一行會被跳過
    // 的東西（真實語料有 46% 是跳過行），而全量重建看到的是全部檔案，所以它的
    // `SkipTally` 是這份語料的**正確答案**。
    //
    // 增量那一側不能直接比總數——它是多輪累加的，每一輪只看新內容。所以這裡比的是
    // **全量重建的分類本身非零且合理**：若跳過路徑整條壞掉（全部變成 0），或分類
    // 漂移（該進 `notATurn` 的跑到 `unparseableLine`），這條就會紅。
    #expect(
        fullReport.skipped.notATurn > 0,
        "生成語料混入的 queue-operation 行沒有被算進 notATurn —— 跳過路徑或它的分類壞了")
    #expect(fullReport.skipped.unparseableLine > 0, "非法 JSON 行沒有被算進 unparseableLine")
    #expect(
        fullReport.skipped.missingPointerField + fullReport.skipped.malformedIdentifier > 0,
        "缺欄位／識別碼形狀不符的行沒有被算進對應分類")

    let found = divergences(
        incremental: try snapshot(run.derived, probes: probes),
        fullRebuild: try snapshot(fullRoot, probes: probes))

    guard found.isEmpty else {
        Issue.record(
            """
            seed \(seed) 的變異序列讓增量與全量重建產生不同的可觀察狀態：

            序列：
            \(run.trace.map { "  - \($0)" }.joined(separator: "\n"))

            差異：
            \(found.map { "  ✗ \($0)" }.joined(separator: "\n"))
            """)
        return
    }
}
