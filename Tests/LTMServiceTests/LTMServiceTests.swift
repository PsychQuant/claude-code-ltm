import CryptoKit
import Foundation
import Testing

@testable import LTMCore
@testable import LTMIndex

@testable import LTMMemory
@testable import LTMQuery
@testable import LTMService

// 全部走合成語料。真實 `~/.claude/projects/` 在這些測試裡一次都沒被碰到——
// 隱私邊界之外，那樣的測試也不可重現（語料每天都在長）。

/// 由文字導出的**確定性**種子。
///
/// **不可以用 `String.hashValue`。** Swift 的 `Hashable` 每個 process 用隨機種子
/// （實測同一字串三次跑出 49 / 973 / 727），所以任何依賴向量順序的測試都會在不同
/// 執行之間變動——它不是偶爾失敗，是**偶爾成功**。
///
/// 代價已經付過一次：`truncationFollowsTheSameOrderAsDisplay` 被宣稱「驗過破壞
/// 會紅」，實測破壞後 8 次只紅 1 次。我只是剛好觀察到那一次。
///
/// 同一條教訓在 `Sources/LTMEval/Interleaving.swift` 已經記過（那裡改用 FNV-1a），
/// 而它沒有轉移到這裡——寫在別處的註解攔不住下一次。
func deterministicSeed(_ text: String) -> UInt64 {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.withUnsafeBytes { $0.load(as: UInt64.self) }
}

struct FixedEmbedder: EmbeddingProvider {
    var revision: String = "test-rev-1"
    var dimension: Int = 8
    /// 產不出向量的文字。用來把某一筆候選壓到**較低的帶**（少一條通道），
    /// 這是構造跨帶反轉語料的唯一可控旋鈕。
    var refusing: Set<String> = []

    func vector(for text: String) throws -> [Float]? {
        guard !refusing.contains(text) else { return nil }
        // 依內容決定的確定性向量：同文字同向量，方便斷言可重現性。
        var value = Float(deterministicSeed(text) % 997) / 997
        var out: [Float] = []
        for _ in 0..<dimension {
            value = (value * 2.3).truncatingRemainder(dividingBy: 1)
            out.append(value)
        }
        let norm = sqrt(out.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? out.map { $0 / norm } : nil
    }
}

private struct AllowAll: CorpusContainmentPolicy {
    func isInsideReadOnlyCorpus(_ url: URL) -> Bool { false }
}

private let testSession = "11111111-2222-3333-4444-555555555555"

private func turnRecord(index: Int, text: String, session: String = testSession) -> String {
    let object: [String: Any] = [
        "type": index.isMultiple(of: 2) ? "user" : "assistant",
        "uuid": String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", index),
        "sessionId": session,
        "timestamp": "2026-08-17T06:00:00.000Z",
        "message": ["role": index.isMultiple(of: 2) ? "user" : "assistant", "content": text],
    ]
    return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

/// 一組工作區：合成語料 + 衍生根 + 事件檔。
struct Workspace {
    let corpus: URL
    let derived: DerivedLocation
    let eventsURL: URL

    static func make() throws -> Workspace {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltm-svc-\(UUID().uuidString)")
        let corpus = base.appendingPathComponent("corpus")
        let derivedRoot = base.appendingPathComponent("derived")
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        return Workspace(
            corpus: corpus,
            derived: try DerivedLocation(root: derivedRoot, policy: AllowAll()),
            eventsURL: base.appendingPathComponent("events.jsonl"))
    }

    func writeSession(project: String = "proj-one", file: String = "s.jsonl", texts: [String])
        throws
    {
        let dir = corpus.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = texts.enumerated().map { turnRecord(index: $0.offset, text: $0.element) }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    func service(refusingVectorsFor texts: Set<String>) throws -> LTMService {
        var embedder = FixedEmbedder()
        embedder.refusing = texts
        return try service(embedder: embedder)
    }

    func service(embedder: FixedEmbedder = FixedEmbedder(), withEvents: Bool = false) throws
        -> LTMService
    {
        LTMService(
            location: derived, corpusRoot: corpus, embedder: embedder,
            eventStore: withEvents ? try FileEventStore(url: eventsURL) : nil)
    }

    /// `RetrievalEngine` 直接交出來的順序（不經策略 seam）。
    ///
    /// 存在的理由是「archival 不重排」這條契約需要**兩份順序可以比對**——
    /// 只看 displacement 驗不到它，那是策略對自己行為的自述。
    func retrievalOrder(text: String, limit: Int) throws -> [String] {
        let database = try IndexDatabase(path: derived.databaseURL.path)
        defer { database.close() }
        let dimension = try database.meta("vector_dimension").flatMap(Int.init) ?? 8
        let vectors = try? VectorSidecar.open(url: derived.vectorsURL, dimension: dimension)
        let engine = RetrievalEngine(
            database: database, vectors: vectors, embedder: FixedEmbedder())
        return try engine.search(query: text, limit: limit, scope: .allProjects).map(\.uuid)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: corpus.deletingLastPathComponent())
    }
}

// MARK: - Task 3.2：facade 的 staleness 與策略契約

@Test("預設策略是 archival：順序等於純檢索順序，每一筆位移都是零")
func defaultStrategyLeavesRetrievalOrderIntact() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["記憶策略的比較軸", "檢索基線量測", "另一段內容"])
    let service = try workspace.service()
    try service.build()

    let outcome = try service.query(text: "記憶策略", limit: 10, scope: .allProjects)

    #expect(!outcome.hits.isEmpty)
    #expect(outcome.strategyID == "archival")
    #expect(outcome.hits.allSatisfy { $0.displacement == 0 })

    // **實際比對兩份順序**，不是只看位移為零。
    //
    // 這條測試的名字一直宣稱「順序等於純檢索順序」，而它從來沒有比對過——
    // 斷言只有 displacement 與 band 的值域。位移為零是策略回報的**自述**；
    // 契約要的是 facade 交出來的順序真的等於檢索交出來的那一份。兩者不同：
    // facade 曾經在 seam 之外重排，而重排後每一筆的 displacement 仍然是 0
    // （策略確實沒動它們）。
    let engineOrder = try workspace.retrievalOrder(text: "記憶策略", limit: 10)
    #expect(
        outcome.hits.map(\.uuid) == engineOrder,
        "archival 不重排，所以輸出順序必須逐筆等於 RetrievalEngine 交出來的順序")

    // band 是**相關度分層**（命中通道數），不是名次——所以它會有重複值。
    #expect(outcome.hits.map(\.band).allSatisfy { (0...2).contains($0) })
}

@Test("embedding revision 不符時拒答，且錯誤指名 ltm build")
func revisionMismatchRefusesTheQuery() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["內容一", "內容二"])
    try workspace.service(embedder: FixedEmbedder(revision: "rev-old")).build()

    // 換一個 revision 的 runtime 來查：不得回傳任何結果。
    let newService = try workspace.service(embedder: FixedEmbedder(revision: "rev-new"))
    var thrown: Error?
    do {
        _ = try newService.query(text: "內容", limit: 10, scope: .allProjects)
    } catch {
        thrown = error
    }
    guard case .some(LTMService.ServiceError.embeddingRevisionMismatch(let indexed, let runtime)) =
        thrown as? LTMService.ServiceError
    else {
        Issue.record("跨 revision 查詢必須拒答，實際拋出：\(String(describing: thrown))")
        return
    }
    #expect(indexed == "rev-old")
    #expect(runtime == "rev-new")
}

@Test("索引不存在時明確失敗，不回空結果")
func missingIndexIsAnErrorNotAnEmptyResult() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["內容"])
    let service = try workspace.service()

    #expect(throws: LTMService.ServiceError.self) {
        _ = try service.query(text: "內容", limit: 10, scope: .allProjects)
    }
}

@Test("查詢時語料前進 → 先併進索引再回答")
func queryPicksUpAppendedCorpusContent() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["最初的內容"])
    let service = try workspace.service()
    try service.build()

    // 語料多了一則，但沒有重新 build。
    try workspace.writeSession(texts: ["最初的內容", "後來補上的關鍵內容"])

    let outcome = try service.query(text: "後來補上", limit: 10, scope: .allProjects)

    #expect(outcome.refresh.sourcesRefreshed > 0, "查詢應該先把新內容併進索引")
    #expect(outcome.hits.contains { $0.snippet.contains("後來補上") })
}

@Test("每一筆命中都帶齊四欄指標")
func everyHitCarriesPointer() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["指標完整性的驗證內容"])
    let service = try workspace.service()
    try service.build()

    let outcome = try service.query(text: "指標完整性", limit: 10, scope: .allProjects)
    #expect(!outcome.hits.isEmpty)
    for hit in outcome.hits {
        #expect(!hit.project.isEmpty)
        // session 分量是集合（#25）：至少一個來源，每個都非空。
        #expect(!hit.sessionSources.isEmpty)
        #expect(hit.sessionSources.allSatisfy { !$0.isEmpty })
        #expect(!hit.uuid.isEmpty)
        #expect(hit.timestamp.timeIntervalSince1970 > 0)
    }
}

// MARK: - Task 3.3：不變式 2 的等價性

@Test("不變式 2：刪掉衍生目錄重建後，同樣的查詢回同樣的結果")
func rebuildFromScratchIsResultEquivalent() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(
        texts: ["記憶策略可插拔", "檢索基線的量測", "第三段無關內容", "第四段其他內容"])
    let service = try workspace.service()
    try service.build()

    let queries = ["記憶策略", "量測", "內容"]
    let before = try queries.map { query in
        try service.query(text: query, limit: 10, scope: .allProjects).hits.map(\.uuid)
    }

    // 整個衍生目錄刪掉，從零重建。
    try FileManager.default.removeItem(at: workspace.derived.root)
    try service.build()

    let after = try queries.map { query in
        try service.query(text: query, limit: 10, scope: .allProjects).hits.map(\.uuid)
    }

    #expect(before == after, "索引是純衍生物：重建後結果必須完全一致")
    #expect(before.contains { !$0.isEmpty }, "測試本身要有命中才有意義")
}

@Test("不變式 2：增量建置與全量重建結果等價")
func incrementalBuildEqualsFullRebuild() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["第一段內容", "第二段內容"])
    let service = try workspace.service()
    try service.build()

    // 追加內容後走增量。
    try workspace.writeSession(texts: ["第一段內容", "第二段內容", "第三段新內容"])
    try service.build()
    let incremental = try service.query(text: "內容", limit: 10, scope: .allProjects).hits.map(\.uuid)

    // 同一份語料從零重建。
    try service.build(full: true)
    let full = try service.query(text: "內容", limit: 10, scope: .allProjects).hits.map(\.uuid)

    #expect(incremental == full)
    #expect(incremental.count == 3)
}

@Test("建置與查詢都不寫語料")
func buildAndQueryLeaveCorpusUntouched() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["語料唯讀的驗證內容"])
    let sessionFile = workspace.corpus.appendingPathComponent("proj-one/s.jsonl")
    let before = try Data(contentsOf: sessionFile)
    let beforeEntries = try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path)

    let service = try workspace.service()
    try service.build()
    _ = try service.query(text: "語料唯讀", limit: 10, scope: .allProjects)

    #expect(try Data(contentsOf: sessionFile) == before)
    #expect(
        try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path).sorted()
            == beforeEntries.sorted(), "語料樹不得多出或少掉任何項目")
}

@Test("索引的 anchor 規則與 binary 不同時拒答，不重新詮釋舊指紋")
func anchorRuleMismatchRefusesTheQuery() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["內容一", "內容二"])
    let service = try workspace.service()
    try service.build()

    // 模擬「上一版 binary 建的索引」：規則標記改成別的值。
    let db = try IndexDatabase(path: workspace.derived.databaseURL.path)
    try db.setMeta("anchor_source_rule", "session-id-as-source")
    db.close()

    var thrown: Error?
    do { _ = try service.query(text: "內容", limit: 10, scope: .allProjects) }
    catch { thrown = error }
    guard case .some(LTMService.ServiceError.anchorSourceRuleMismatch(let indexed, let expected)) =
        thrown as? LTMService.ServiceError
    else {
        Issue.record("舊 anchor 規則必須拒答，實際：\(String(describing: thrown))")
        return
    }
    #expect(indexed == "session-id-as-source")
    #expect(expected == IndexDatabase.anchorSourceRule)
}

@Test("跨 resume 的使用歷史仍解析得到——B3 的端到端回歸鎖")
func usageHistorySurvivesSessionResume() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }

    // 第一階段：只有 session-A，記錄使用歷史。
    let sharedText = "跨越 resume 的同一段內容"
    try workspace.writeSession(file: "session-A.jsonl", texts: [sharedText])
    let service = try workspace.service(withEvents: true)
    try service.build()
    let first = try service.query(
        text: "跨越 resume", limit: 10, scope: .allProjects, recordEvents: true)
    #expect(first.eventsRecorded > 0, "前提：要有歷史可以蒸發")
    let recordedAnchors = Set(first.hits.map(\.anchor))

    // 第二階段：session 被 resume，同一則 turn 出現在新檔案、帶新的 sessionId。
    let dir = workspace.corpus.appendingPathComponent("proj-one")
    let resumed = """
        {"type":"user","uuid":"00000000-aaaa-bbbb-cccc-dddddddddddd",\
        "sessionId":"99999999-9999-9999-9999-999999999999",\
        "timestamp":"2026-08-18T06:00:00.000Z",\
        "message":{"role":"user","content":"\(sharedText)"}}
        """
    try (resumed + "\n").write(
        to: dir.appendingPathComponent("session-B.jsonl"), atomically: true, encoding: .utf8)
    try service.build()

    // 關鍵：resume 之後，先前記錄的 anchor 仍然指向同一段內容。
    let second = try service.query(text: "跨越 resume", limit: 10, scope: .allProjects)
    let nowAnchors = Set(second.hits.map(\.anchor))

    // **先前這裡只有一條 `!isDisjoint`（#28）**——「有交集」。那比要保住的性質弱兩步：
    // 這個 change 要保住的不是「anchor 字串沒變」，是**使用歷史還在**，而中間還有
    //   (a) 那些 anchor 解不解析得回 turn
    //   (b) 事件有沒有被 projection 計入
    // 兩者任一斷掉，`!isDisjoint` 照樣綠。以下把兩步都斷言出來。

    // (0) 從「有交集」收緊成「**全部倖存**」。resume 不刪東西，所以先前記錄的每一個
    //     anchor 都該還在——有交集可能只是碰巧有一筆對上。
    #expect(
        recordedAnchors.isSubset(of: nowAnchors),
        "resume 後有 anchor 消失 —— 使用歷史會安靜蒸發，正是 B3 的病灶")

    // (a) anchor 解析得回 turn：命中帶得出 snippet 與四元組指標，就代表它 dereference
    //     成功了（`QueryHit` 是由 anchor 對照 `scored` 建出來的，見不變式 3）。
    for hit in second.hits where recordedAnchors.contains(hit.anchor) {
        #expect(!hit.snippet.isEmpty, "anchor 解析不回內容 —— 指標還在但指向空的")
        #expect(!hit.uuid.isEmpty)
        #expect(!hit.sessionSources.isEmpty)
    }

    // (b) resume 真的被偵測到：同一則 turn 現在活在**兩份**檔裡，所以它的來源集合
    //     應該有兩個元素。這條同時證明 (0) 的倖存不是因為 resume 沒被看見。
    let shared = second.hits.first { recordedAnchors.contains($0.anchor) }
    guard let shared else {
        Issue.record("前提不成立：沒有任何命中屬於先前記錄的 anchor")
        return
    }
    #expect(
        shared.sessionSources.count == 2,
        "resume 後來源集合仍只有一個元素——那代表新檔案沒被認出來，這條測試的前提沒成立")
}

// MARK: - Task 3.1/3.2：band 語意與策略生效（B1 的回歸鎖）

@Test("band 由命中通道數決定：同通道數共享一帶，通道多者帶較高")
func bandIsDerivedFromChannelCount() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    // 多筆內容，讓不同候選命中不同數量的通道。
    try workspace.writeSession(texts: [
        "記憶策略可插拔的比較軸", "記憶與檢索的關係", "完全不相干的第三段",
        "另一段關於策略的討論", "第五段內容",
    ])
    let service = try workspace.service()
    try service.build()

    let outcome = try service.query(text: "記憶策略", limit: 10, scope: .allProjects)
    #expect(!outcome.hits.isEmpty)

    // **排除法斷言已刪除**（#28）。先前這裡有一條
    // `bands != Array(0..<outcome.hits.count)`——「band 不等於名次」。它剛好抓得到
    // 當時那個 bug（舊實作的 band 就是融合名次），但它是**排除法**：它只說 band
    // 不是某一個特定的錯值，沒說它是什麼。
    //
    // **接手的是下面那條正面斷言**：`band == 3 - channels.count`。它蘊含排除法那條
    // ——通道數 ∈ {1,2,3} 所以 band ∈ {0,1,2}，命中超過三筆時就不可能等於名次序列。
    // 跨帶排序另由 `queryOutputIsBandMajorOnInvertedCorpus` 驗（含前提檢查）。
    //
    // 命中通道數越多，band 越高（數值越小）。
    for hit in outcome.hits {
        let expectedBand = 3 - hit.channels.count
        #expect(hit.band == expectedBand,
                "band 應為 3 減去命中通道數（3 條→0、2 條→1、1 條→2）")
    }
}

@Test("重排策略在有歷史時產出與 archival 不同的順序——B1 的端到端回歸鎖")
func reorderingStrategyDiffersFromArchival() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: [
        "記憶策略可插拔的比較軸", "記憶與檢索的關係", "另一段關於策略的討論",
        "第四段內容", "第五段內容", "第六段內容",
    ])
    let service = try workspace.service(withEvents: true)
    try service.build()

    // 先取得候選，然後給**其中一筆**寫入 deliberate 事件。
    //
    // 刻意不用 `--record` 產生的 `shown`：shown 只計 impressions、不計
    // reinforcement，所以全部候選都被 shown 過等於沒有差異——那是正確行為
    // （被看到不代表有用），但它無法用來驗證重排。
    let baseline = try service.query(text: "記憶", limit: 10, scope: .allProjects)
    #expect(baseline.hits.count >= 2, "前提：同帶內要有多個候選才有得重排")
    let promoted = baseline.hits[baseline.hits.count - 1].anchor  // 給最後一名強歷史
    let store = try FileEventStore(url: workspace.eventsURL)
    for _ in 0..<3 {
        try store.append(
            Event(kind: .cited, anchor: promoted, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                  generation: GenerationID("g-test"), policy: RankingPolicyID("human-like"),
                  noteRef: nil, presentation: nil))
    }

    let archival = try service.query(text: "記憶", limit: 10, scope: .allProjects)
    let humanLike = try service.query(
        text: "記憶", limit: 10, scope: .allProjects, strategy: HumanLikeStrategy())

    #expect(archival.strategyID == "archival")
    #expect(humanLike.strategyID == "human-like")
    // 這是 B1 的核心：兩個策略必須真的能產出不同結果。
    let orderDiffers = archival.hits.map(\.uuid) != humanLike.hits.map(\.uuid)
    let anyDisplaced = humanLike.hits.contains { $0.displacement != 0 }
    #expect(orderDiffers || anyDisplaced,
            "human-like 與 archival 完全相同 ⇒ 策略 seam 是空的（B1）")
    // 被引用的那一筆應該往上移（或至少報出非零位移）。
    #expect(humanLike.hits.first(where: { $0.anchor == promoted })?.displacement ?? 0 != 0
            || orderDiffers)
}

@Test("側車檔被截斷時拒答，不靜默降級成 lexical-only")
func truncatedSidecarRefusesTheQuery() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["第一段內容", "第二段內容", "第三段內容"])
    let service = try workspace.service()
    try service.build()

    // 砍掉側車檔的一半：索引仍宣稱有 N 個向量，檔案只剩 N/2。
    let data = try Data(contentsOf: workspace.derived.vectorsURL)
    try data.prefix(data.count / 2).write(to: workspace.derived.vectorsURL)

    // 這條路徑上先 fire 的是**建置端**的守衛：查詢的增量續讀會先把側車截回索引
    // 宣稱的長度，而截斷只准縮不准長——檔案比宣稱的短就是拒答的理由。
    //
    // （不能靠補零「修好」：零向量與任何查詢的點積都是 0，向量通道會靜默失效
    // 而筆數核對照樣通過。`FileHandle.truncate(atOffset:)` 對較短的檔案正是
    // 補零延長，所以那個名字在這個方向上是騙人的。）
    var thrown: Error?
    do { _ = try service.query(text: "內容", limit: 10, scope: .allProjects) }
    catch { thrown = error }
    guard case .some(IndexBuilder.BuildError.sidecarShorterThanDeclared) =
        thrown as? IndexBuilder.BuildError
    else {
        Issue.record("側車比宣稱的短必須拒答，實際：\(String(describing: thrown))")
        return
    }
}

@Test("另一個寫者持鎖時，側車不一致由 facade 自己的核對擋下")
func truncatedSidecarRefusesEvenWhenRefreshIsSkipped() throws {
    // 上一條測的是建置端的守衛。但拿不到鎖時**增量續讀整段被跳過**，那道守衛
    // 就不會跑——所以 facade 必須有自己的核對，否則同一個損壞在「另一個 build
    // 正在跑」的時候會安靜地降級成 lexical-only。
    //
    // 兩道守衛不是重複：它們守的是不同的執行路徑，而哪一道先 fire 取決於鎖。
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["第一段內容", "第二段內容", "第三段內容"])
    let service = try workspace.service()
    try service.build()

    let data = try Data(contentsOf: workspace.derived.vectorsURL)
    try data.prefix(data.count / 2).write(to: workspace.derived.vectorsURL)

    let lock = try FileLock.acquire(at: workspace.derived.lockURL)
    defer { lock.release() }

    var thrown: Error?
    do { _ = try service.query(text: "內容", limit: 10, scope: .allProjects) }
    catch { thrown = error }
    guard case .some(LTMService.ServiceError.vectorSidecarMismatch) =
        thrown as? LTMService.ServiceError
    else {
        Issue.record("跳過續讀時仍必須拒答，實際：\(String(describing: thrown))")
        return
    }
}

@Test("查詢路徑與建置路徑共用同一把單寫者鎖")
func queryPathHonoursTheBuildLock() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["最初的內容"])
    let service = try workspace.service()
    try service.build()

    // 語料前進，但鎖被別人持有 → 查詢仍應回答（用既有索引），只是不併入新內容。
    try workspace.writeSession(texts: ["最初的內容", "後來補上的內容"])
    let held = try FileLock.acquire(at: workspace.derived.lockURL)
    defer { held.release() }

    let outcome = try service.query(text: "最初", limit: 10, scope: .allProjects)
    #expect(outcome.refresh.sourcesRefreshed == 0, "鎖被持有時不得寫入索引")
    #expect(!outcome.hits.isEmpty, "查詢仍應以既有索引回答，不因為拿不到鎖而失敗")
}

// MARK: - band 分層屬於檢索層，且必須在生產路徑上被鎖住（round-3 verify HIGH）
//
// 上一版把分層做在 facade（`LTMService.layered`），而 retrieval spec 的
// requirement 逐字寫「SHALL NOT reorder outside that seam」——那就是 seam 之外的
// 重排，即使排序規則本身正確。分層現在住在 `RetrievalEngine`。
//
// 上一版的三條測試也全部測在 helper 上：把 `query()` 裡呼叫 `layered` 那一行整個
// 刪掉，293 個測試仍然全綠。**頭號修法可以被整行刪掉而無人察覺。**
// 所以這裡改成鎖生產路徑，並且刻意構造一份「純融合順序確實會出現跨帶反轉」的語料
// ——沒有反轉的語料上，這條測試證明不了任何事。

@Test("band 規則：命中通道數決定帶，0 最相關，通道總數不寫死")
func bandRuleIsChannelCount() {
    #expect(ScoredChunk.band(matching: [.trigram, .segment, .vector]) == 0)
    #expect(ScoredChunk.band(matching: [.trigram, .vector]) == 1)
    #expect(ScoredChunk.band(matching: [.segment]) == 2)
    #expect(
        ScoredChunk.band(matching: Set(ScoredChunk.Channel.allCases)) == 0,
        "全部命中必為最高帶——加第四條通道時這條才不會靜默失效")
}

/// 一份**保證**在純融合順序上出現跨帶反轉的語料。
///
/// RRF 的每條通道貢獻介於 `1/(60+1)` 與 `1/(60+depth)` 之間，所以「兩通道」的上限
/// （2/61 ≈ 0.0328）要壓過「三通道」的下限，三通道那筆必須在**每一條**通道都排得
/// 很深。這需要夠多的競爭者——所以語料是 55 則而不是 6 則。
///
/// 構造：`inversionText` 只有它被 embedder 拒發向量（兩通道 → band 1），而它的文字
/// 最短所以 bm25 名次最前；其餘 54 則長度遞增，最長那幾則在三條通道都墊底。
private enum BandInversionCorpus {
    static let term = "共通詞"
    /// **不可以等於 `term`**：`refusing` 是依文字比對的，而查詢向量也走同一個
    /// embedder——兩者相同的話連查詢都拿不到向量，整條 vector 通道會空掉，
    /// 於是所有候選都變成兩通道、根本沒有跨帶反轉可測。（踩過。）
    static let inversionText = "共通詞 短"

    static func texts() -> [String] {
        var out = [inversionText]
        for i in 0..<54 {
            out.append("共通詞 " + String(repeating: "填充內容\(i % 7) ", count: i + 2))
        }
        return out
    }
}

@Test("生產路徑：查詢輸出的 band 序列非遞減——在確實有跨帶反轉的語料上")
func queryOutputIsBandMajorOnInvertedCorpus() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: BandInversionCorpus.texts())
    let service = try workspace.service(refusingVectorsFor: [BandInversionCorpus.inversionText])
    try service.build()

    let outcome = try service.query(
        text: BandInversionCorpus.term, limit: 60, scope: .allProjects)

    // 前提：這份語料真的產生了跨帶反轉，否則下面的斷言是恆真式。
    let bandOnePositions = outcome.hits.enumerated()
        .filter { $0.element.band > 0 }.map(\.offset)
    let bandZeroPositions = outcome.hits.enumerated()
        .filter { $0.element.band == 0 }.map(\.offset)
    #expect(!bandOnePositions.isEmpty, "前提：語料裡必須有非最高帶的候選")
    #expect(!bandZeroPositions.isEmpty, "前提：語料裡必須有最高帶的候選")

    let bands = outcome.hits.map(\.band)
    #expect(
        zip(bands, bands.dropFirst()).allSatisfy { $0 <= $1 },
        "band 序列遞減了：\(bands)")
}

@Test("生產路徑：截斷與排序用同一個判準——高帶候選不得被低帶候選擠掉")
func truncationFollowsTheSameOrderAsDisplay() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: BandInversionCorpus.texts())
    let service = try workspace.service(refusingVectorsFor: [BandInversionCorpus.inversionText])
    try service.build()

    // 先前是「用融合分數選 top-k、用 band 排顯示」——選集與排序用兩個判準。
    //
    // k 取 36 不是隨便挑的：實測純融合序裡那個 band 1 候選落在第 35 位（把引擎的
    // band-major 排序拿掉，seam 會回 `bandsOutOfOrder(at: 35)`）。k 必須**跨過**
    // 那個位置，否則用哪個判準截斷都選到同一批，測試證明不了任何事。
    let small = try service.query(text: BandInversionCorpus.term, limit: 36, scope: .allProjects)
    #expect(small.hits.count == 36, "前提：k 必須小到真的截斷")
    #expect(
        small.hits.allSatisfy { $0.band == 0 },
        "截斷若走融合分數，低帶候選會擠進來：\(small.hits.map(\.band))")
}

// 這裡曾經有一條 `queryOutputBandsAreNonDecreasing`。它斷言的性質是對的，但它的
// 語料上**不可能**出現跨帶反轉——把引擎的 band-major 排序整個拿掉，它照樣綠。
//
// 刪掉而不是留著，是因為一條不可能失敗的測試比沒有測試更糟：它在覆蓋率與閱讀上
// 都算數，於是那個性質看起來有人守。上面兩條在刻意構造的反轉語料上驗過會紅
// （分別對應「不排」與「用分數截、用 band 排」兩種錯法），由它們接手。


// MARK: - 查詢路徑的診斷資訊與「不得整份重建」（round-3 verify）

@Test("查詢路徑回報讀不到的來源——它跑的是與 build 完全相同的那段掃描")
func queryPathReportsUnreadableSources() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["會變成讀不到的內容", "另一段"])
    let service = try workspace.service()
    try service.build()

    let file = workspace.corpus.appendingPathComponent("proj-one/s.jsonl")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }

    let outcome = try service.query(text: "內容", limit: 10, scope: .allProjects)
    #expect(!outcome.hits.isEmpty, "讀不到不等於消失——既有內容必須還在")
    #expect(
        outcome.refresh.sourcesUnreadable.count == 1,
        "同一段掃描走 build 會說出讀不到哪些檔，走 query 不該一個字都不說")
}

@Test("查詢路徑拒絕整份重建，而不是從查詢裡刪掉 DB 與側車")
func queryPathRefusesFullRebuild() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["內容一", "內容二"])
    let service = try workspace.service()
    try service.build()

    // 模擬 TOCTOU：query 讀完 stamp 之後、build 重讀之前，另一個行程改了 layout。
    // 直接把 layout_version 改成當前值以外的東西，等價於「第二次讀會 mismatch」。
    let database = try IndexDatabase(path: workspace.derived.databaseURL.path)
    try database.setMeta("layout_version", String(IndexDatabase.layoutVersion + 1))
    database.close()

    // query 前段的 layout 檢查會先擋下（那是對的），所以這裡直接驗 IndexBuilder
    // 這一側的前置條件——它才是「從查詢路徑刪掉衍生檔」的實際入口。
    var thrown: Error?
    do {
        _ = try IndexBuilder(
            location: workspace.derived,
            scanner: CorpusScanner(corpusRoot: workspace.corpus), embedder: FixedEmbedder()
        ).build(refusingFullRebuild: true)
    } catch { thrown = error }
    guard case .some(IndexBuilder.BuildError.fullRebuildRequired) = thrown as? IndexBuilder.BuildError
    else {
        Issue.record("必須拒絕而不是重建，實際：\(String(describing: thrown))")
        return
    }
    #expect(
        FileManager.default.fileExists(atPath: workspace.derived.databaseURL.path),
        "拒絕的意思是衍生檔還在——重建會先 discardDerivedArtifacts")
}

/// revision 在**第一次讀取之後**改變的 embedder。
///
/// 用來模擬 TOCTOU：`query` 讀 stamp 時不持鎖，`build` 拿到鎖後會重讀；兩次之間
/// 若有另一個行程完成一次會改版本的建置，第二次讀就會 mismatch。單行程測試裡
/// 造不出真的競態，但**兩次讀取看到不同的值**正是競態對這段程式碼的唯一表現。
final class DriftingRevisionEmbedder: EmbeddingProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private let inner = FixedEmbedder()

    var revision: String {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return reads <= 1 ? "test-rev-1" : "test-rev-drifted"
    }
    var dimension: Int { inner.dimension }
    func vector(for text: String) throws -> [Float]? { try inner.vector(for: text) }
}

@Test("生產接線：查詢路徑傳的是 refusingFullRebuild: true，不是預設值")
func facadeRefusesFullRebuildFromTheQueryPath() throws {
    // 上一版只測 `IndexBuilder` 那一側，於是把 `LTMService` 傳的 `true` 改成
    // `false`，301 個測試全綠——被鎖住的是被呼叫者，不是呼叫點。
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["內容一", "內容二"])
    try workspace.service().build()

    let service = LTMService(
        location: workspace.derived, corpusRoot: workspace.corpus,
        embedder: DriftingRevisionEmbedder(), eventStore: nil)

    var thrown: Error?
    do { _ = try service.query(text: "內容", limit: 10, scope: .allProjects) }
    catch { thrown = error }

    guard case .some(IndexBuilder.BuildError.fullRebuildRequired) =
        thrown as? IndexBuilder.BuildError
    else {
        Issue.record(
            "查詢路徑必須拒絕整份重建，實際：\(String(describing: thrown))")
        return
    }
    // 拒絕的意思是衍生檔還在——`refusingFullRebuild: false` 會走
    // `discardDerivedArtifacts()`，從查詢路徑刪掉 DB、側車與 state。
    #expect(FileManager.default.fileExists(atPath: workspace.derived.databaseURL.path))
    #expect(FileManager.default.fileExists(atPath: workspace.derived.stateURL.path))
}

// MARK: - 呈現識別碼（Task 1.2/1.3，#15）

@Test("兩次獨立查詢各自的 shown 事件共用一個呈現識別碼，兩次之間不共用")
func twoSeparateQueriesProduceTwoSeparatePresentationGroups() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: [
        "第一段關於記憶策略的內容", "第二段關於記憶策略的內容", "第三段關於記憶策略的內容",
    ])
    let service = try workspace.service(withEvents: true)
    try service.build()

    let first = try service.query(
        text: "記憶策略", limit: 10, scope: .allProjects, recordEvents: true)
    let second = try service.query(
        text: "記憶策略", limit: 10, scope: .allProjects, recordEvents: true)

    #expect(!first.hits.isEmpty)
    #expect(!second.hits.isEmpty)

    let firstIDs = Set(first.hits.compactMap(\.presentation))
    let secondIDs = Set(second.hits.compactMap(\.presentation))

    // 同一次查詢的所有 hit 共用同一個識別碼。
    #expect(firstIDs.count == 1, "第一次查詢的所有 hit 應共用一個呈現識別碼")
    #expect(secondIDs.count == 1, "第二次查詢的所有 hit 應共用一個呈現識別碼")
    // 兩次查詢之間不共用。
    #expect(firstIDs.isDisjoint(with: secondIDs), "兩次查詢的呈現識別碼不應重疊")
}

@Test("QueryHit 攜帶的呈現識別碼與事件檔裡實際寫入的一致")
func queryHitExposesTheIdentifierItWasRecordedUnder() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["關於記憶策略的內容"])
    let service = try workspace.service(withEvents: true)
    try service.build()

    let outcome = try service.query(
        text: "記憶策略", limit: 10, scope: .allProjects, recordEvents: true)
    #expect(!outcome.hits.isEmpty)

    let store = try FileEventStore(url: workspace.eventsURL)
    let events = try store.allEvents()
    let shown = events.filter { $0.kind == .shown }
    #expect(!shown.isEmpty)

    for hit in outcome.hits {
        let matching = shown.first { $0.anchor == hit.anchor }
        #expect(matching?.presentation == hit.presentation, "hit.presentation 必須與寫入事件檔的值一致")
    }
}

@Test("不記錄事件時，QueryHit 沒有呈現識別碼")
func noPresentationIdentifierWhenNotRecording() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["關於記憶策略的內容"])
    let service = try workspace.service()
    try service.build()

    let outcome = try service.query(text: "記憶策略", limit: 10, scope: .allProjects)
    #expect(!outcome.hits.isEmpty)
    #expect(outcome.hits.allSatisfy { $0.presentation == nil })
}

// MARK: - 擴散收斂為 human-like 專屬（Task 1.1，add-spreading-activation-fixes）

@Test("conservative 策略不吃到擴散：同框呈現群組裡只有 shown 事件的 anchor，即使組內另一 anchor 被 opened，仍然沒有 reinforcement")
func conservativeStrategyDoesNotReceiveSpreadingActivation() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: [
        "第一段關於記憶策略的內容", "第二段關於記憶策略的內容", "第三段關於記憶策略的內容",
    ])
    let service = try workspace.service(withEvents: true)
    try service.build()

    let outcome = try service.query(
        text: "記憶策略", limit: 10, scope: .allProjects, recordEvents: true)
    #expect(outcome.hits.count >= 2, "需要至少兩筆同框 hit 才能構造擴散情境")
    let presentation = try #require(outcome.hits.first?.presentation)
    let openedAnchor = outcome.hits[0].anchor
    let untouchedAnchor = outcome.hits[1].anchor

    let store = try FileEventStore(url: workspace.eventsURL)
    try store.append(
        .interaction(
            .opened, anchor: openedAnchor, at: Date(), generation: GenerationID("g-test"),
            policy: RankingPolicyID("conservative"), presentation: presentation))

    let reranked = try service.query(
        text: "記憶策略", limit: 10, scope: .allProjects,
        strategy: ConservativeStrategy())
    let untouchedHit = try #require(reranked.hits.first { $0.anchor == untouchedAnchor })
    #expect(
        untouchedHit.historyDescription == "none",
        "conservative 不該吃到擴散：untouched anchor 只有同框 shown，reason.history 應為 .none，實得 \(untouchedHit.historyDescription)"
    )
}

// MARK: - 導航來源集合（#25，`return-all-navigation-sources`）

@Test("facade 每一筆命中都帶來源集合，且 sessionID 是它的成員")
func everyHitCarriesItsSourceSet() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["關於記憶策略的第一段", "關於記憶策略的第二段"])
    let service = try workspace.service()
    try service.build()

    let outcome = try service.query(text: "記憶策略", limit: 10, scope: .allProjects)
    #expect(!outcome.hits.isEmpty)
    for hit in outcome.hits {
        #expect(!hit.sessionSources.isEmpty, "來源集合至少一個元素，單一來源也不例外")
    }
}

@Test("facade：被兩份檔持有的 turn 回報兩個來源，而不是字典序挑出的那一個")
func aResumeDuplicatedTurnReportsEveryHoldingSource() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    let sessionA = "aaaaaaaa-1111-2222-3333-444444444444"
    let sessionB = "bbbbbbbb-1111-2222-3333-444444444444"
    let shared = "被 resume 複製到兩份檔案的同一段內容"

    // 兩份檔含同一則 turn（同 index → 同 uuid、同內容、同時間戳），只有 sessionId 不同
    // ——這正是 session resume 產生的形狀，也是 #25 裡時間戳永遠平手的成因。
    let dir = workspace.corpus.appendingPathComponent("proj-one")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try (turnRecord(index: 0, text: shared, session: sessionA) + "\n")
        .write(to: dir.appendingPathComponent("s-A.jsonl"), atomically: true, encoding: .utf8)
    try (turnRecord(index: 0, text: shared, session: sessionB) + "\n")
        .write(to: dir.appendingPathComponent("s-B.jsonl"), atomically: true, encoding: .utf8)

    let service = try workspace.service()
    try service.build()

    let outcome = try service.query(text: "resume", limit: 10, scope: .allProjects)
    let hit = try #require(outcome.hits.first { $0.snippet.contains("resume") })
    #expect(
        hit.sessionSources.sorted() == [sessionA, sessionB].sorted(),
        "兩個持有者都要回報，實得 \(hit.sessionSources)")
    // 刻意**不**斷言任何「代表值」——沒有代表值可挑就是這次改動的重點（#25）。
    // 集合的順序只是顯示確定性，不得有消費端依賴 [0]。
}

// MARK: - #13：無法歸屬指標的結果被丟棄，而且**數出來**

@Test("正常查詢的無法歸屬計數是零")
func aNormalQueryAttributesEveryResult() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    let service = try workspace.service()
    try service.build()

    let outcome = try service.query(text: "內容", limit: 10, scope: .allProjects)
    #expect(!outcome.hits.isEmpty)
    #expect(outcome.unattributableResults == 0)
}

// **這條測試的效力要說清楚，因為它比看起來弱。**
//
// `unattributableResults` 非零的分支**結構上到不了**：`byAnchor` 由 `scored` 建，
// `ranked` 來自策略，而 seam 的排列性檢查要求 `ranked` 是輸入候選的排列——所以
// 策略**無法**經由 `rerank` 交出一個不在候選集合裡的 anchor。
//
// 也就是說：把計數器改成永遠不增加，這條測試**照樣綠**。它鎖不住那個計數器。
//
// 那為什麼還留著計數器？因為 `guard ... else { continue }` **本來就在那裡**，而它
// 先前是靜默的。改動買到的不是「現在測得到」，是「**如果哪天真的發生，它會被看見**」
// ——那要嘛代表 seam 的排列性檢查破了，要嘛代表 `scored` 與 `ranked` 之間長出了
// 第三個寫者。兩者都是這個 repo 反覆記錄的形狀。
//
// **缺口具名，不假裝有守衛**（同 `PlacementConstraint` 的確定性迭代）：要驅動它，
// 得先有一條繞過 seam 的注入路徑，而那條路徑不存在**正是**設計要的。
