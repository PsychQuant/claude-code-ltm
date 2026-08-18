import Foundation
import Testing

@testable import LTMCore
@testable import LTMIndex
@testable import LTMMemory
@testable import LTMQuery
@testable import LTMService

// 全部走合成語料。真實 `~/.claude/projects/` 在這些測試裡一次都沒被碰到——
// 隱私邊界之外，那樣的測試也不可重現（語料每天都在長）。

struct FixedEmbedder: EmbeddingProvider {
    var revision: String = "test-rev-1"
    var dimension: Int = 8

    func vector(for text: String) throws -> [Float]? {
        // 依內容決定的確定性向量：同文字同向量，方便斷言可重現性。
        var value = Float(abs(text.hashValue % 997)) / 997
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

    func service(embedder: FixedEmbedder = FixedEmbedder(), withEvents: Bool = false) throws
        -> LTMService
    {
        LTMService(
            location: derived, corpusRoot: corpus, embedder: embedder,
            eventStore: withEvents ? try FileEventStore(url: eventsURL) : nil)
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
    // band 是**相關度分層**（命中通道數），不是名次——所以它會有重複值，
    // 而且不隨名次遞增。archival 不重排，所以順序仍等於純檢索順序。
    #expect(outcome.hits.map(\.band).allSatisfy { (0...2).contains($0) })
    #expect(outcome.hits.map(\.band) != Array(0..<outcome.hits.count),
            "band 若等於名次，每筆自成一帶，策略 seam 就是空的（B1）")
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

    #expect(outcome.refreshedSources > 0, "查詢應該先把新內容併進索引")
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
        #expect(!hit.sessionID.isEmpty)
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
    #expect(!recordedAnchors.isDisjoint(with: nowAnchors),
            "resume 後 anchor 對不上 —— 使用歷史會安靜蒸發，正是 B3 的病灶")
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

    // 核心斷言：band 不再等於名次。名次必然 0,1,2,...；band 是分層，會有重複值。
    let bands = outcome.hits.map(\.band)
    #expect(bands != Array(0..<outcome.hits.count),
            "band 等於名次 ⇒ 每筆自成一帶 ⇒ 任何策略都動不了任何東西（B1）")

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
    #expect(outcome.refreshedSources == 0, "鎖被持有時不得寫入索引")
    #expect(!outcome.hits.isEmpty, "查詢仍應以既有索引回答，不因為拿不到鎖而失敗")
}

// MARK: - band 分層必須滿足 seam 的前置條件（round-2 verify CRITICAL）

/// 造一個 ScoredChunk，只控制我們要測的兩個變數：命中通道數與融合名次。
private func scoredChunk(rank: Int, channels: Set<ScoredChunk.Channel>, id: Int) -> ScoredChunk {
    let uuid = String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", id)
    let text = "候選 \(id) 的內容"
    let turn = Turn(id: uuid, role: "user", timestamp: Date(timeIntervalSince1970: 1), text: text)
    return ScoredChunk(
        project: "proj-one", sessionID: "11111111-2222-3333-4444-555555555555", uuid: uuid,
        timestamp: turn.timestamp, text: text,
        anchor: Anchor(source: ProjectFingerprint.of("proj-one"), turn: turn,
                       span: 0..<text.unicodeScalars.count),
        fusedScore: 1.0 - Double(rank) * 0.01, fusedRank: rank, channels: channels)
}

@Test("band 分層後必然非遞減——seam 的前置條件")
func layeringSatisfiesTheSeamPrecondition() throws {
    // 融合順序與通道數**不單調相關**：名次 0 只命中一條，名次 2 命中三條。
    // 這正是真實語料會出現的形狀（2 通道但各通道名次靠前 vs 3 通道但都很深）。
    let unsorted = [
        scoredChunk(rank: 0, channels: [.vector], id: 0),
        scoredChunk(rank: 1, channels: [.trigram, .segment], id: 1),
        scoredChunk(rank: 2, channels: [.trigram, .segment, .vector], id: 2),
        scoredChunk(rank: 3, channels: [.segment], id: 3),
    ]
    // 未排序時 band 是 [2,1,0,2] —— 遞減，會讓 requireBandsInOrder 拋錯。
    let rawBands = unsorted.map { LTMService.band(for: $0) }
    #expect(rawBands == [2, 1, 0, 2])
    #expect(!zip(rawBands, rawBands.dropFirst()).allSatisfy { $0 <= $1 },
            "前提：未排序的輸入確實違反前置條件，否則這條測試證明不了任何事")

    let layered = LTMService.layered(unsorted)
    let bands = layered.map { LTMService.band(for: $0) }

    // 三通道 → band 0；兩通道 → band 1；一通道 → band 2（兩筆）。
    #expect(bands == [0, 1, 2, 2], "band 必須非遞減，且同帶為單一連續區段")
    // 帶內維持融合次序：band 2 的兩筆原名次是 0 與 3，排序後仍是 0 在前。
    let bandTwo = layered.filter { LTMService.band(for: $0) == 2 }.map(\.fusedRank)
    #expect(bandTwo == [0, 3], "帶內必須保持融合順序")

    // 直接把排序後的候選餵給 seam 的前置條件檢查——這才是它真正要滿足的契約。
    let candidates = layered.map {
        Candidate(anchor: $0.anchor, baseScore: $0.fusedScore,
                  band: RelevanceBand(rank: LTMService.band(for: $0)))
    }
    #expect(throws: Never.self) {
        try MemoryStrategySupport.requireBandsInOrder(candidates)
    }
}

@Test("未經分層的候選會被 seam 拒絕——證明上一條測的不是恆真式")
func unlayeredCandidatesAreRejectedBySeam() throws {
    let unsorted = [
        scoredChunk(rank: 0, channels: [.vector], id: 0),
        scoredChunk(rank: 1, channels: [.trigram, .segment, .vector], id: 1),
    ]
    let candidates = unsorted.map {
        Candidate(anchor: $0.anchor, baseScore: $0.fusedScore,
                  band: RelevanceBand(rank: LTMService.band(for: $0)))
    }
    #expect(throws: StrategyViolation.self) {
        try MemoryStrategySupport.requireBandsInOrder(candidates)
    }
}

@Test("查詢輸出的 band 序列非遞減")
func queryOutputBandsAreNonDecreasing() throws {
    let workspace = try Workspace.make()
    defer { workspace.cleanup() }
    try workspace.writeSession(texts: [
        "記憶策略可插拔的比較軸", "記憶與檢索的關係", "完全不相干的第三段",
        "另一段關於策略的討論", "第五段內容", "第六段其他內容",
    ])
    let service = try workspace.service()
    try service.build()

    for query in ["記憶", "策略", "內容", "檢索"] {
        let outcome = try service.query(text: query, limit: 20, scope: .allProjects)
        let bands = outcome.hits.map(\.band)
        #expect(zip(bands, bands.dropFirst()).allSatisfy { $0 <= $1 },
                "查詢 \(query) 的 band 序列遞減了：\(bands)")
    }
}
