import CryptoKit
import Foundation
import SQLite3
import Testing

@testable import LTMCore
@testable import LTMIndex


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

/// 合成 embedding provider。
///
/// 用它而不是真的 `NLContextualEmbedding`：模型 assets 不一定在（CI、剛裝好的
/// 機器），而「向量從哪來」不是這些測試要驗的東西——要驗的是 revision 變動如何
/// 作廢索引、向量筆數與 chunk 是否對得上。真實 provider 的行為由它自己的
/// 型別負責。
struct StubEmbedder: EmbeddingProvider {
    var revision: String
    var dimension: Int = 4
    /// 產不出向量的文字（測 `vector_row` 為 NULL 的路徑）。
    var refusing: Set<String> = []

    func vector(for text: String) throws -> [Float]? {
        guard !refusing.contains(text) else { return nil }
        // 內容**與 revision** 共同決定向量。
        //
        // 先前只看內容，於是「換 revision → 索引重建」的測試證明不了任何事：
        // 重建前後的向量位元相同，測試就算沒重建也會通過。revision 進 seed 之後，
        // 舊向量若沒被替換，值就會對不上。
        var seed = Float(deterministicSeed(text + revision) % 1000) / 1000
        return (0..<dimension).map { _ in
            seed = (seed * 1.7).truncatingRemainder(dividingBy: 1)
            return seed
        }
    }
}

private struct AllowAllPolicy: CorpusContainmentPolicy {
    func isInsideReadOnlyCorpus(_ url: URL) -> Bool { false }
}

/// 一組臨時的語料根 + 衍生根。
private func makeWorkspace() throws -> (corpus: URL, derived: DerivedLocation) {
    let corpus = try makeFixtureCorpus()
    let derivedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-derived-\(UUID().uuidString)")
    return (corpus, try DerivedLocation(root: derivedRoot, policy: AllowAllPolicy()))
}

private let session = "11111111-2222-3333-4444-555555555555"

private func writeTurns(in corpus: URL, project: String = "proj-one", texts: [String]) throws {
    var lines: [String] = []
    for (index, text) in texts.enumerated() {
        lines.append(
            turnLine(
                uuid: String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", index),
                session: session, role: index.isMultiple(of: 2) ? "user" : "assistant", text: text))
    }
    _ = try writeSession(in: corpus, project: project, file: "session.jsonl", lines: lines)
}

@Test("建置後向量筆數等於有向量的 chunk 數")
func vectorCountMatchesChunkCount() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容", "第二段內容", "第三段內容"])

    let builder = IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
        embedder: StubEmbedder(revision: "rev-A"))
    let report = try builder.build()

    #expect(report.totalChunks == 3)
    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    #expect(try database.meta("vector_count") == "3")

    // 側車檔的長度要與宣稱的筆數一致——不一致代表某一次中止留下了殘骸。
    let sidecar = try VectorSidecar.open(url: derived.vectorsURL, dimension: 4)
    #expect(sidecar.count == 3)
    #expect(sidecar.vector(at: 0)?.count == 4)
    #expect(sidecar.vector(at: 3) == nil)
}

@Test("產不出向量的 chunk 仍然進索引，只是沒有 vector_row")
func chunkWithoutVectorStaysIndexed() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["有向量的內容", "沒有向量的內容"])

    let builder = IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
        embedder: StubEmbedder(revision: "rev-A", refusing: ["沒有向量的內容"]))
    let report = try builder.build()

    #expect(report.totalChunks == 2)
    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    #expect(try database.meta("vector_count") == "1")
    var withoutVector = 0
    try database.query("SELECT COUNT(*) FROM chunks WHERE vector_row IS NULL") { statement in
        withoutVector = Int(sqlite3_column_int64(statement, 0))
    }
    #expect(withoutVector == 1, "沒有向量的 chunk 應該仍在 lexical 通道裡")
}

@Test("embedding revision 變動使整份索引重建，不混用兩代向量")
func revisionChangeForcesFullRebuild() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容", "第二段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)

    let first = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()
    #expect(first.wasFullRebuild)  // 第一次本來就是從零

    // 同一個 revision 再建一次：增量，沒有新內容 → 沒有新 chunk。
    let second = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()
    #expect(!second.wasFullRebuild)
    #expect(second.chunksIndexed == 0)
    #expect(second.totalChunks == 2)

    // 換 revision：必須整份重建，且向量筆數不能疊加成 4。
    let third = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-B")
    ).build()
    #expect(third.wasFullRebuild)
    #expect(third.totalChunks == 2)
    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    #expect(try database.meta("vector_count") == "2", "跨 revision 的向量疊加會讓距離失去意義")
    #expect(try database.stamps().embeddingRevision == "rev-B")
    // 舊向量必須真的被**替換**，不只是筆數對。revision 進了 seed，所以值會不同。
    let sidecar = try VectorSidecar.open(url: derived.vectorsURL, dimension: 4)
    let rebuilt = sidecar.vector(at: 0)
    let underOldRevision = try StubEmbedder(revision: "rev-A").vector(for: "第一段內容")
    #expect(rebuilt != underOldRevision, "側車裡仍是舊 revision 算出的向量 —— 重建沒有真的發生")
}

@Test("鎖被持有時第二個建置立刻失敗，不無限等待")
func concurrentBuildIsRefused() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["內容"])
    try derived.createRootIfNeeded()

    // 手動持鎖，模擬另一個正在跑的建置。
    let held = try FileLock.acquire(at: derived.lockURL)
    defer { held.release() }

    let builder = IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
        embedder: StubEmbedder(revision: "rev-A"))
    #expect(throws: IndexBuilder.BuildError.self) {
        _ = try builder.build()
    }
}

/// 這條測試釘的是 `#44` 的**前提**，不是它的效果。
///
/// `#44` 逐字把「Ctrl-C、當機、睡眠、OOM」列為要處理的中斷，而分批提交省下的
/// 計算，在第一版的鎖形狀下**恰好在這幾種中斷後拿不到**：`release()` 只在 Swift
/// 正常 unwind 的 `defer` 裡跑，SIGKILL 之後 `build.lock` 永久留下，
/// 下一次 `open(O_EXCL)` 必然 `EEXIST`。
///
/// 所以「已完成的批次還在磁碟上」與「重跑能續做」是兩件事——第二件先前不成立。
///
/// **為什麼用殘留檔案而不是真的 SIGKILL 一個子行程**：兩者對受測程式是同一個
/// 輸入。核心在行程死亡時做的就是「釋放 flock、保留 inode」，而這裡直接構造
/// 那個狀態。真正的子行程 SIGKILL 測試更忠實但需要另一個可執行檔，成本與這條
/// 要釘的性質不成比例——那條列在 #44 的 follow-up。
@Test("上一個行程被 SIGKILL 留下的鎖檔不擋下一次建置")
func staleLockFileDoesNotBlockNextBuild() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["內容"])
    try derived.createRootIfNeeded()

    // 構造殘留：檔案在、內容是一個早就不存在的 pid、**沒有人持有 flock**。
    // 這正是 SIGKILL 之後磁碟上的狀態。
    try "999999\n".write(to: derived.lockURL, atomically: true, encoding: .utf8)
    #expect(FileManager.default.fileExists(atPath: derived.lockURL.path))

    let report = try IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
        embedder: StubEmbedder(revision: "rev-A")
    ).build()
    #expect(report.chunksIndexed == 1)
}

/// `lockHeld` 與「鎖檔開不起來」是兩件事，補救動作相反：前者該等，後者等再久
/// 也不會好。第一版把兩者混成一個 `lockHeld`，於是磁碟滿或權限不足的使用者
/// 會去等一個不存在的建置。
@Test("開不了鎖檔時給的是 lockUnavailable，不是叫人去等的 lockHeld")
func aBrokenLockPathIsNotReportedAsAnotherBuildInProgress() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try derived.createRootIfNeeded()

    // 把鎖的路徑做成一個**目錄**：`open` 會回 EISDIR，而那顯然不是「別人在建置」。
    try FileManager.default.createDirectory(
        at: derived.lockURL, withIntermediateDirectories: true)

    do {
        _ = try FileLock.acquire(at: derived.lockURL)
        Issue.record("應該拋錯")
    } catch let error as IndexBuilder.BuildError {
        guard case .lockUnavailable(_, let code, _) = error else {
            Issue.record("應該是 lockUnavailable，實際是 \(error)")
            return
        }
        #expect(code == EISDIR)
    }
}

@Test("建置完成後鎖被釋放，下一次建置拿得到")
func lockIsReleasedAfterBuild() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["內容"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)

    _ = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()
    // **不再斷言鎖檔消失。** 鎖現在掛在 `flock` 上，`release()` 刻意不刪檔
    // （刪檔會開一個 race，見 `FileLock` 的型別註解）。所以「檔案不存在」
    // 不再是釋放的證據——「下一次拿得到」才是，而那正是下面那一行。
    // 再跑一次不該因為殘留的鎖而失敗。
    _ = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()
}

@Test("側車檔殘骸在下一次建置被截掉，row 編號不會錯開")
func staleSidecarBytesAreTruncated() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    _ = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()

    // 模擬「上一輪寫到一半被中止」：檔案比 vector_count 記錄的長。
    let handle = try FileHandle(forWritingTo: derived.vectorsURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0xFF, count: 4 * MemoryLayout<Float>.size))
    try handle.close()

    // 加一則新內容後再建置：殘骸該被截掉，新向量接在正確的位置。
    try writeTurns(in: corpus, texts: ["第一段內容", "第二段內容"])
    _ = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()

    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    let declared = try database.meta("vector_count").flatMap(Int.init) ?? -1
    let sidecar = try VectorSidecar.open(url: derived.vectorsURL, dimension: 4)
    #expect(sidecar.count == declared, "側車檔筆數與索引宣稱的筆數必須一致")
}

/// 這條測試釘的是 devil's advocate 在 #44 verify 抓到的那條——其他五個 reviewer
/// 全部漏掉，而它的後果是**不變式 2 安靜失效**。
///
/// 舊形狀：批次內容 COMMIT 進 SQLite，續讀游標寫進 `state.json`。兩者都不 fsync
/// （`PRAGMA synchronous=NORMAL` 下 COMMIT 不 fsync；`Data.write(.atomic)` 是
/// temp+rename 也不 fsync），而 `CorpusScanner` 的續讀**只讀游標、從不回頭問 DB**。
/// 硬重啟可以把 WAL 尾巴回滾到批次 2，而游標存活在批次 5 —— 批次 3/4/5 的 chunk
/// **永遠不再被產出**，`ltm build` 照樣印「✓ 索引完成」。
///
/// 修法不是加 fsync（那只是把窗口縮小），是把游標放進**同一個交易**。於是
/// 「回滾」對兩者是同一件事——這條測試直接釘那個等價關係：交易失敗時，
/// 內容與游標必須**一起**不見。舊形狀下游標會活下來，因為它根本不在交易裡。
@Test("交易回滾時，內容與續讀游標一起消失——不會留下超前的游標")
func aRolledBackBatchLeavesNoCursorAheadOfTheContent() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try derived.createRootIfNeeded()
    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    try database.createSchema()

    struct Boom: Error {}
    // 一個「寫了內容也寫了游標，然後崩掉」的批次。
    #expect(throws: Boom.self) {
        try database.transaction {
            try database.upsertScanState(
                sourceKey: "proj/s.jsonl", prefixHash: "deadbeef", processedBytes: 4_096)
            throw Boom()
        }
    }

    // 游標必須跟著回滾。舊形狀下它寫在交易外的檔案裡，這裡會是 4,096。
    #expect(try database.scanState().files["proj/s.jsonl"] == nil,
            "游標超前於內容，就是那個安靜漏語料的窗口")
}

/// 續讀游標搬進 DB 之後，**刪掉 `state.json` 已經無害**——它是鏡像，不是真相。
///
/// 這條測試取代了先前那條「刪掉 state.json 應該丟 stateUnreadable」。舊測試釘的
/// 不是那條性質本身，是它當時的**載體**；載體換了，測試該跟著換，而不是把載體
/// 留下來只為了讓測試維持綠色。
@Test("刪掉 state.json 不影響續讀——游標在 DB 裡")
func deletingTheStateMirrorIsHarmless() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    _ = try IndexBuilder(location: derived, scanner: scanner,
                         embedder: StubEmbedder(revision: "rev-A")).build()

    try FileManager.default.removeItem(at: derived.stateURL)

    // 增量：沒有新內容，所以不該有任何 chunk 被重新索引。
    let again = try IndexBuilder(location: derived, scanner: scanner,
                                 embedder: StubEmbedder(revision: "rev-A")).build()
    #expect(!again.wasFullRebuild)
    #expect(again.chunksIndexed == 0, "游標還在 DB 裡，不該重掃")
}

/// 而「不在舊索引上安靜疊加」這條性質仍然要守，只是它的條件變了：**兩邊都沒有
/// 游標**才是那個危險狀態。先前刪一個檔就到得了，現在要把 DB 裡的表也清空。
@Test("兩邊都沒有續讀游標而索引有內容時丟出 stateUnreadable")
func anIndexWithContentButNoCursorAnywhereIsRefused() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    _ = try IndexBuilder(location: derived, scanner: scanner,
                         embedder: StubEmbedder(revision: "rev-A")).build()

    try FileManager.default.removeItem(at: derived.stateURL)
    do {
        let database = try IndexDatabase(path: derived.databaseURL.path)
        defer { database.close() }
        try database.execute("DELETE FROM scan_state")
        #expect(try database.chunkCount() > 0, "前提：索引裡確實有內容")
    }

    #expect(throws: IndexBuilder.BuildError.self) {
        _ = try IndexBuilder(location: derived, scanner: scanner,
                             embedder: StubEmbedder(revision: "rev-A")).build()
    }
    // --full 仍然可用（那正是錯誤訊息指引的路）。
    let recovered = try IndexBuilder(location: derived, scanner: scanner,
                                     embedder: StubEmbedder(revision: "rev-A")).build(full: true)
    #expect(recovered.wasFullRebuild)
}

/// 舊版本建的索引升級上來時，游標還在 `state.json` 裡而 DB 的表是空的。
/// 那必須被當成**遷移**，不是「沒有游標」——否則升級一次就要重掃全語料。
@Test("舊索引的 state.json 被遷移進 DB，不觸發重掃")
func aLegacyStateFileIsMigratedIntoTheDatabase() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    _ = try IndexBuilder(location: derived, scanner: scanner,
                         embedder: StubEmbedder(revision: "rev-A")).build()

    // 構造「舊版本留下的索引」：DB 有內容、表是空的、鏡像檔還在。
    do {
        let database = try IndexDatabase(path: derived.databaseURL.path)
        defer { database.close() }
        try database.execute("DELETE FROM scan_state")
    }
    #expect(FileManager.default.fileExists(atPath: derived.stateURL.path))

    let migrated = try IndexBuilder(location: derived, scanner: scanner,
                                    embedder: StubEmbedder(revision: "rev-A")).build()
    #expect(!migrated.wasFullRebuild)
    #expect(migrated.chunksIndexed == 0, "遷移過來的游標應該讓這一輪沒有新內容")

    // 遷移之後游標要真的在 DB 裡，否則下一次又要靠鏡像檔。
    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    #expect(!(try database.scanState().files.isEmpty))
}

// MARK: - 刪檔作廢 × 去重的交互作用（round-2 verify HIGH）
//
// 去重把「同一則 turn 出現在多個檔」收斂成一列，而作廢的粒度是 `source_key`
// ——一列只記得住一個。兩個機制各自正確，交互作用不正確。

@Test("刪掉重複來源之一，不得刪掉另一個來源仍然持有的 turn")
func deletingOneResumeCopyKeepsTheTurn() throws {
    let workspace = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: workspace.corpus)
        try? FileManager.default.removeItem(at: workspace.derived.root)
    }
    // 同一則 turn（同 uuid、同內容）出現在兩個檔——這正是 session resume
    // 在真實語料裡的樣子（全語料 8,324 檔 12,488 筆，見
    // `docs/measurements/2026-08-18-resume-duplication.md`）。
    let uuid = "0000ffff-aaaa-bbbb-cccc-dddddddddddd"
    let text = "這一則會出現在兩個 session 檔裡"
    _ = try writeSession(
        in: workspace.corpus, project: "proj-one", file: "a.jsonl",
        lines: [turnLine(uuid: uuid, session: "aaaaaaaa-1111-1111-1111-111111111111",
                         role: "user", text: text)])
    let laterFile = try writeSession(
        in: workspace.corpus, project: "proj-one", file: "b.jsonl",
        lines: [turnLine(uuid: uuid, session: "bbbbbbbb-2222-2222-2222-222222222222",
                         role: "user", text: text)])

    let embedder = StubEmbedder(revision: "r1")
    func builder() -> IndexBuilder {
        IndexBuilder(
            location: workspace.derived,
            scanner: CorpusScanner(corpusRoot: workspace.corpus, anchorKey: .forTesting), embedder: embedder)
    }
    #expect(try builder().build().totalChunks == 1, "去重之後只該有一列")

    // 刪掉勝出的那個來源檔。另一個檔**沒有變動**，所以增量掃描不會重新產出它。
    try FileManager.default.removeItem(at: laterFile)
    let report = try builder().build()

    #expect(
        report.totalChunks == 1,
        "turn 仍然存在於 a.jsonl；把它從索引刪掉會讓增量結果與全量重建不同（不變式 2）")
}

@Test("讀不到的來源不作廢，但必須出現在報告裡")
func unreadableSourcesAreReportedNotSilentlyKept() throws {
    let workspace = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: workspace.corpus)
        try? FileManager.default.removeItem(at: workspace.derived.root)
    }
    let file = try writeSession(
        in: workspace.corpus, project: "proj-one", file: "s.jsonl",
        lines: [turnLine(uuid: "0000aaaa-aaaa-bbbb-cccc-dddddddddddd",
                         session: "cccccccc-3333-3333-3333-333333333333",
                         role: "user", text: "會變成讀不到的內容")])
    let embedder = StubEmbedder(revision: "r1")
    func builder() -> IndexBuilder {
        IndexBuilder(
            location: workspace.derived,
            scanner: CorpusScanner(corpusRoot: workspace.corpus, anchorKey: .forTesting), embedder: embedder)
    }
    #expect(try builder().build().totalChunks == 1)

    // 拿掉讀取權限：檔案還在，只是讀不到。
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

    let report = try builder().build()
    #expect(report.totalChunks == 1, "讀不到不等於消失——既有內容必須保留")
    #expect(
        report.sourcesUnreadable.count == 1,
        "不作廢就必須說出來；沉默地保留會讓這次建置看起來完整")
}

@Test("側車檔整個不見時拒絕建置，不把 vector_row 接到別人的向量上")
func missingSidecarIsRefusedNotSilentlyRebuilt() throws {
    let workspace = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: workspace.corpus)
        try? FileManager.default.removeItem(at: workspace.derived.root)
    }
    try writeTurns(in: workspace.corpus, texts: ["第一段內容"])
    let embedder = StubEmbedder(revision: "r1")
    func builder() -> IndexBuilder {
        IndexBuilder(
            location: workspace.derived,
            scanner: CorpusScanner(corpusRoot: workspace.corpus, anchorKey: .forTesting), embedder: embedder)
    }
    #expect(try builder().build().totalChunks == 1)

    // 側車檔整個消失——這是「向量真的不見了」的極端情形，不是「沒有向量要處理」。
    try FileManager.default.removeItem(at: workspace.derived.vectorsURL)
    // 語料前進，讓下一輪真的會 append。
    _ = try writeSession(
        in: workspace.corpus, project: "proj-one", file: "session.jsonl",
        lines: [
            turnLine(uuid: "00000000-aaaa-bbbb-cccc-dddddddddddd",
                     session: "11111111-2222-3333-4444-555555555555",
                     role: "user", text: "第一段內容"),
            turnLine(uuid: "00000001-aaaa-bbbb-cccc-dddddddddddd",
                     session: "11111111-2222-3333-4444-555555555555",
                     role: "assistant", text: "第二段內容"),
        ])

    var thrown: Error?
    do { _ = try builder().build() } catch { thrown = error }
    guard case .some(IndexBuilder.BuildError.sidecarShorterThanDeclared(let declared, let found)) =
        thrown as? IndexBuilder.BuildError
    else {
        Issue.record("側車不見必須拒絕，實際：\(String(describing: thrown))")
        return
    }
    #expect(declared > 0 && found == 0, "找到 0 列，不是「沒事可做」")
}

@Test("索引本來就沒有向量時，缺側車檔不算錯")
func absentSidecarIsFineWhenNoVectorsAreDeclared() throws {
    let workspace = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: workspace.corpus)
        try? FileManager.default.removeItem(at: workspace.derived.root)
    }
    // embedder 對所有文字都產不出向量 → vector_count 恆為 0。
    try writeTurns(in: workspace.corpus, texts: ["第一段內容"])
    let embedder = StubEmbedder(revision: "r1", refusing: ["第一段內容"])
    let report = try IndexBuilder(
        location: workspace.derived, scanner: CorpusScanner(corpusRoot: workspace.corpus, anchorKey: .forTesting),
        embedder: embedder
    ).build()
    #expect(report.totalChunks == 1, "沒有向量不影響 lexical 通道")
}

@Test("時間戳相同時，建置後兩個來源都在——沒有被挑掉的那一個")
func identicalTimestampsKeepEverySourceAfterBuild() throws {
    // 這條測試取代了先前的 `navigationTieBreakFollowsTheSpecExample`。
    //
    // 那條鎖的是「平手時指標報 source_key 字典序**最大**者」，理由是當時的
    // corpus-indexing spec Example 逐字要求 `s-B`。#25 把整個「挑一個」的模型
    // 拆掉了：N 份 resume 複製是 N 個等價來源，沒有代表值——挑選規則由檔案路徑
    // （位置）決定，且會隨新檔案出現而改變，違反 `ltm-analogy` 的性質 1。
    //
    // 所以要鎖的性質換了：**建置之後兩個來源都必須在**。這是 end-to-end（走
    // 真正的 IndexBuilder 掃描路徑），與 IndexDatabaseTests 那條直接插入的
    // 互補。
    let workspace = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: workspace.corpus)
        try? FileManager.default.removeItem(at: workspace.derived.root)
    }
    let uuid = "0000ffff-aaaa-bbbb-cccc-dddddddddddd"
    let stamp = "2026-08-17T06:00:00.000Z"
    let sessionA = "aaaaaaaa-1111-1111-1111-111111111111"
    let sessionB = "bbbbbbbb-2222-2222-2222-222222222222"
    for (file, session) in [("s-A.jsonl", sessionA), ("s-B.jsonl", sessionB)] {
        _ = try writeSession(
            in: workspace.corpus, project: "proj-one", file: file,
            lines: [turnLine(uuid: uuid, session: session, role: "user",
                             text: "同一則 turn 出現在兩個 session 檔",
                             timestamp: stamp)])
    }
    _ = try IndexBuilder(
        location: workspace.derived, scanner: CorpusScanner(corpusRoot: workspace.corpus, anchorKey: .forTesting),
        embedder: StubEmbedder(revision: "r1")
    ).build()

    let database = try IndexDatabase(path: workspace.derived.databaseURL.path)
    defer { database.close() }
    var chunkID: Int64 = 0
    try database.query("SELECT id FROM chunks WHERE uuid = ?", bind: [.text(uuid)]) { statement in
        chunkID = sqlite3_column_int64(statement, 0)
    }
    let sources = try database.sessionSources(chunkIDs: [chunkID])[chunkID] ?? []
    #expect(
        sources == [sessionA, sessionB],
        "兩個來源都要留著（依 source_key 字典序），實得 \(sources)")
}

// MARK: - #44：中斷的代價必須是「最後一批」，不是「全部」

/// 在第 N 次呼叫時拋錯的 embedder，用來製造「build 跑到一半死掉」。
///
/// 計數與 `refusing` 不同：後者測「這段文字產不出向量」（正常路徑），這個測
/// 「向量算到一半整個爆掉」（異常路徑）。兩者的正確行為相反——前者跳過該 chunk
/// 繼續，後者必須讓已完成的部分留下來。
/// `writeStamps` 被移到批次迴圈**之前**（為了讓崩掉的 build 不會因為「版本未知」
/// 而觸發全量重建）。regression lens 指出那個前移新開了另一個窗口：崩在
/// 「DB 已建立、還沒有任何批次提交」之間時，索引存在而續讀游標不存在，於是下一次
/// build 硬失敗在 `stateUnreadable`，補救只剩 `--full`——正是 #44 存在要消除的
/// 「中斷全丟」。
///
/// 續讀游標搬進 DB 之後這個窗口關掉了，但**關掉的理由必須被釘住**：判準從
/// 「state.json 在不在」換成「索引裡到底有沒有內容」。沒有內容就沒有東西可疊，
/// 當成空 state 從頭掃是對的；有內容而沒有游標才是那個危險狀態。
@Test("崩在第一批之前，下一次仍可增量續做，不會被逼去 --full")
func crashingBeforeTheFirstBatchDoesNotBrickTheIndex() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["甲", "乙", "丙"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)

    // failAfter: 0 —— 第一個 embedding 就炸，所以沒有任何批次提交得了。
    let doomed = FailingAfterNEmbedder(revision: "rev-A", failAfter: 0)
    #expect(throws: FailingAfterNEmbedder.Boom.self) {
        _ = try IndexBuilder(location: derived, scanner: scanner, embedder: doomed,
                             batchChunkTarget: 1).build()
    }

    // DB 檔已經在了（stamps 也寫過），而索引裡沒有內容。
    #expect(FileManager.default.fileExists(atPath: derived.databaseURL.path))

    // 這一次不該丟 stateUnreadable，也不該被迫走 --full。
    let recovered = try IndexBuilder(
        location: derived, scanner: scanner, embedder: StubEmbedder(revision: "rev-A")
    ).build()
    #expect(!recovered.wasFullRebuild, "被迫全量重建就等於中斷全丟")
    #expect(recovered.chunksIndexed == 3)
}

// MARK: - 記憶體預算與具名拒絕（#46 Expected ②③）

/// #46 ③ 逐字要的是「到達上限時**具名拒絕**，而不是讓 OS 決定」。
///
/// 「具名」有兩個要求，兩個都測：訊息說得出**補救**，而且拒絕發生在**做事之前**
/// ——跑了四十分鐘才說「我不該開始」不是拒絕，是浪費。
@Test("超過預算時在算任何向量之前就具名拒絕")
func exceedingTheMemoryBudgetRefusesBeforeEmbeddingAnything() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["甲", "乙", "丙", "丁"])

    let counting = FailingAfterNEmbedder(revision: "rev-A", failAfter: .max)
    // 4 chunk × 4 維 × 4 B × 2 = 128 B。預算設 64 B 必然超過。
    let builder = IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
        embedder: counting, batchChunkTarget: 100, memoryBudgetBytes: 64)

    do {
        _ = try builder.build()
        Issue.record("應該拒絕")
        return
    } catch let error as IndexBuilder.BuildError {
        guard case .memoryBudgetExceeded(let estimated, let budget, let batch, let source) = error
        else {
            Issue.record("應該是 memoryBudgetExceeded，實際是 \(error)")
            return
        }
        #expect(estimated == 128)
        #expect(budget == 64)
        #expect(batch == 4)
        #expect(source == 4)
    }

    // **一個向量都不該算過。** 拒絕要發生在花掉時間之前。
    #expect(counting.callCount == 0, "拒絕之前就開始 embedding，等於沒有拒絕")
    // 也不該留下半份索引。
    #expect(try IndexDatabase(path: derived.databaseURL.path).chunkCount() == 0)
}

/// 預設不設限是**刻意**的：本 repo 沒有任何量測支撐得起一個門檻。這條測試把
/// 那個決定釘住——日後有人「順手加個合理預設」時，它會紅。
@Test("不設預算時同一份語料照跑——預設無上限是刻意的")
func withoutABudgetTheSameCorpusBuildsFine() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["甲", "乙", "丙", "丁"])

    let report = try IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
        embedder: StubEmbedder(revision: "rev-A")
    ).build()
    #expect(report.chunksIndexed == 4)
}

/// 估算式必須把 `VectorSidecar.encode` 產生的那份 `Data` 算進去——它與
/// `batchVectors` 同時存活。少算那個 2 會讓守衛在最需要的時候放行。
@Test("估算值含 encode 的第二份拷貝：chunk × 維度 × 4 B × 2")
func theEstimateAccountsForTheEncodedCopy() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["甲", "乙", "丙", "丁"])

    final class Box: @unchecked Sendable {
        var estimated: Int?
        var largestBatch: Int?
    }
    let box = Box()
    _ = try IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
        embedder: StubEmbedder(revision: "rev-A"),
        progress: { progress in
            if case .batchPlan(_, let largest, let bytes) = progress {
                box.estimated = bytes
                box.largestBatch = largest
            }
        },
        batchChunkTarget: 100
    ).build()

    #expect(box.largestBatch == 4)
    // StubEmbedder 是 4 維：4 chunk × 4 維 × 4 B × 2 = 128。
    #expect(box.estimated == 128, "少算 encode 的那一份會讓守衛在最需要時放行")
}

final class FailingAfterNEmbedder: EmbeddingProvider, @unchecked Sendable {
    let revision: String
    let dimension: Int = 4
    private let failAfter: Int
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

    init(revision: String, failAfter: Int) {
        self.revision = revision
        self.failAfter = failAfter
    }

    struct Boom: Error {}

    func vector(for text: String) throws -> [Float]? {
        lock.lock()
        calls += 1
        let n = calls
        lock.unlock()
        if n > failAfter { throw Boom() }
        var seed = Float(deterministicSeed(text + revision) % 1000) / 1000
        return (0..<dimension).map { _ in
            seed = (seed * 1.7).truncatingRemainder(dividingBy: 1)
            return seed
        }
    }
}

/// 寫多個 project，讓「分批」有邊界可分。
private func writeManyProjects(in corpus: URL, projects: Int, turnsEach: Int) throws {
    for p in 0..<projects {
        var lines: [String] = []
        for i in 0..<turnsEach {
            lines.append(
                turnLine(
                    uuid: String(format: "%08x-aaaa-bbbb-cccc-%012x", i, p),
                    session: session, role: i.isMultiple(of: 2) ? "user" : "assistant",
                    text: "專案 \(p) 的第 \(i) 段內容，長度要夠讓它成為一個 chunk。"))
        }
        _ = try writeSession(in: corpus, project: "proj-\(p)", file: "session.jsonl", lines: lines)
    }
}

/// **中斷之後，已完成的批次必須留在磁碟上。**
///
/// 這是 #44 的核心斷言。實測過現行實作的後果：1 小時 20 分的 build 被中斷後，
/// `index.sqlite3` 停在 4 KB、WAL 751 MB、`chunks` 為 0——整個交易從未提交，
/// 80 分鐘的 on-device embedding 全部作廢。
///
/// 破壞實作確認過會紅：把 `build()` 改回單一交易包住整個 embedding 迴圈，
/// 這條會看到 `vector_count` 為 0（或 meta 讀不到）。
@Test("build 中斷後，已完成的批次是持久的")
func aCrashMidBuildKeepsCompletedBatches() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeManyProjects(in: corpus, projects: 6, turnsEach: 2)

    let flaky = FailingAfterNEmbedder(revision: "rev-A", failAfter: 4)
    // 批次設小，否則 12 個 chunk 全落在同一批，分批的行為觀察不到。
    let builder = IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
        embedder: flaky, batchChunkTarget: 2)

    #expect(throws: (any Error).self) { _ = try builder.build() }

    // 已完成的批次留下來了嗎？
    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    let committed = Int(try database.meta("vector_count") ?? "0") ?? 0
    #expect(committed > 0, "中斷前完成的批次應該已提交，實際 vector_count=\(committed)")
    #expect(committed <= 4, "不該提交超過 embedder 成功產出的數量")

    // 側車與宣稱的筆數一致——這是那條「永久且靜默的 row 錯位」不變式。
    let sidecar = try VectorSidecar.open(url: derived.vectorsURL, dimension: 4)
    #expect(sidecar.count == committed, "側車 \(sidecar.count) 筆 vs 宣稱 \(committed) 筆")
}

/// **重跑只做剩下的，不從零開始。**
///
/// 沒有這條，上一條可以被「提交了但 state 沒寫」滿足——那樣重跑仍會重算全部，
/// 而使用者感受到的「中斷代價」一點都沒降低。
@Test("中斷後重跑不重算已完成的部分")
func rerunAfterCrashDoesNotRecomputeCompletedWork() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeManyProjects(in: corpus, projects: 6, turnsEach: 2)
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)

    let flaky = FailingAfterNEmbedder(revision: "rev-A", failAfter: 4)
    #expect(throws: (any Error).self) {
        _ = try IndexBuilder(
            location: derived, scanner: scanner, embedder: flaky, batchChunkTarget: 2).build()
    }
    let doneBeforeCrash = Int(
        try IndexDatabase(path: derived.databaseURL.path).meta("vector_count") ?? "0") ?? 0

    // 第二次用正常 embedder，數它算了幾次。
    let counting = FailingAfterNEmbedder(revision: "rev-A", failAfter: .max)
    _ = try IndexBuilder(
        location: derived, scanner: scanner, embedder: counting, batchChunkTarget: 2).build()

    let total = Int(try IndexDatabase(path: derived.databaseURL.path).meta("vector_count") ?? "0") ?? 0
    #expect(total > doneBeforeCrash, "重跑應該把剩下的做完")
    #expect(
        counting.callCount < total,
        "重跑算了 \(counting.callCount) 次而總共 \(total) 筆——已完成的 \(doneBeforeCrash) 筆不該重算")
}

/// **#44 ②：build 進行中，另一個寫入者撞上寫鎖會怎樣。**
///
/// 這一條在 #44 開單時被列為「仍未實測」——而它決定 ② 的嚴重度：具名失敗是可
/// 接受的（使用者看得懂），靜默阻塞或誤報索引損壞高一級。
///
/// 分批之後，寫鎖只在每批的那個交易內持有（不再是全程），所以撞上的窗口小得多。
/// 但「小」不是「沒有」，而這條測試釘的是**撞上時的行為**，不是機率。
@Test(.timeLimit(.minutes(1)))
func aSecondWriterMeetsANamedFailureNotASilentHang() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["內容一", "內容二"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    _ = try IndexBuilder(location: derived, scanner: scanner, embedder: StubEmbedder(revision: "r")).build()

    // 另一個行程持有 build lock 時，第二個 build 必須**具名拒絕**而不是等。
    // `BuildError.locked` 的 doc 逐字寫著「不等待：建置可能跑很久，讓第二個
    // 行程無限期等下去比失敗更糟」——這條就是那句話的執行點。
    let lockPath = derived.root.appendingPathComponent("build.lock").path
    let holder = open(lockPath, O_RDWR | O_CREAT, 0o600)
    #expect(holder >= 0)
    defer { close(holder) }
    #expect(flock(holder, LOCK_EX | LOCK_NB) == 0, "沒拿到鎖的話這條測試什麼都沒測")

    do {
        _ = try IndexBuilder(location: derived, scanner: scanner, embedder: StubEmbedder(revision: "r")).build()
        Issue.record("第二個 build 應該被拒絕")
    } catch let error as IndexBuilder.BuildError {
        // **具名為「鎖被持有」**，不是逾時、不是「索引損壞」、不是掛住。
        //
        // 這個區分是重點：一個回報「索引損壞」的並發衝突會讓使用者去跑
        // `--full` 重建（丟掉正確的索引），而 `lockHeld` 讓他知道該做的是等。
        guard case .lockHeld(let path) = error else {
            Issue.record("應該是 lockHeld，實際是 \(error)")
            return
        }
        #expect(path.hasSuffix("build.lock"), "錯誤要指名是哪個鎖：\(path)")
    }
}
