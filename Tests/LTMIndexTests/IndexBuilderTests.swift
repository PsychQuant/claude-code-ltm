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
    // **內容也要寫。** 先前這裡只呼叫 `upsertScanState`，於是它證明的是「一個
    // 只寫游標的交易會回滾游標」——那是 SQLite 的性質，不是本次改動的性質。
    // 要釘的是**兩者一起**回滾，所以交易裡必須同時有 chunk 與游標。
    // （#45 R2 verify，codex lens：「rollback 測試釘的是別的東西」。）
    let chunk = makeRollbackChunk(
        uuid: "11111111-1111-1111-1111-111111111111", text: "批次 3 的內容",
        sourceKey: "proj/s.jsonl")
    #expect(throws: Boom.self) {
        try database.transaction {
            _ = try database.insert(chunks: [chunk], sourceKey: "proj/s.jsonl")
            try database.upsertScanState(
                sourceKey: "proj/s.jsonl", prefixHash: "deadbeef", processedBytes: 4_096)
            throw Boom()
        }
    }

    // 兩個斷言缺一不可：只斷言游標，測試對「內容其實沒回滾」是瞎的；
    // 只斷言內容，對「游標超前」是瞎的。而超前正是那個安靜漏語料的窗口。
    #expect(try database.chunkCount() == 0, "內容沒有跟著回滾")
    #expect(try database.scanState().files["proj/s.jsonl"] == nil,
            "游標超前於內容，就是那個安靜漏語料的窗口")
}

/// `upsertScanState` / `deleteScanState` 在交易外被呼叫必須丟出來。
///
/// **這條測試存在，是因為那兩個守衛先前沒有任何測試在扛**——跨模型盲驗的
/// devil's advocate 自己跑變異：把 `IndexDatabase` 的兩個
/// `guard sqlite3_get_autocommit(handle) == 0` 整段刪掉，481 條測試全綠
/// （#45 R2 verify）。CLAUDE.md 對這個形狀的處置是「驅動不了的守衛要拆掉，
/// 不是留著加註解」，所以要嘛拆、要嘛給它一條會紅的測試。這裡選後者，因為
/// 那個守衛擋的是一類真實的呼叫端錯誤。
///
/// **它保證的比它的名字聽起來小，這一點要寫清楚**：`sqlite3_get_autocommit`
/// 只回答「在**某個**交易裡嗎」，不回答「與內容在**同一個**交易裡嗎」。上面那條
/// 回滾測試扛的才是後者。兩條一起才涵蓋 `scan_state` 註解論證的那件事。
@Test("游標寫入在交易外被拒絕——具名，不是靜默寫進去")
func aCursorWriteOutsideATransactionIsRefused() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try derived.createRootIfNeeded()
    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    try database.createSchema()

    #expect(throws: IndexDatabase.DatabaseError.self) {
        try database.upsertScanState(
            sourceKey: "proj/s.jsonl", prefixHash: "deadbeef", processedBytes: 4_096)
    }
    #expect(throws: IndexDatabase.DatabaseError.self) {
        try database.deleteScanState(sourceKey: "proj/s.jsonl")
    }
    // 被拒絕就是**沒有寫進去**——不是「寫了但也丟了錯」。
    #expect(try database.scanState().files.isEmpty)
}

/// 批次上界的公式只有一份，而這條測試釘住它**取得到**。
///
/// 先前公式是 `max(target, largestSource)`，錯的，而且被複製到六處散文——含
/// spec 的 SHALL 文字（#46 R2 verify，codex lens）。所以現在它是一個可執行的
/// 函式，散文只指名不複述，而漂移由這條測試變紅。
@Test("批次上界等於宣告的公式，而且那個上界取得到")
func batchUpperBoundMatchesTheDeclaredFormula() throws {
    // 舊公式在這組值上報 4,322；真值是 2_000 − 1 + 4_322 = 6,321，低估 46%。
    #expect(IndexBuilder.batchChunkUpperBound(target: 2_000, largestSource: 4_322) == 6_321)
    // target = 1：每個來源自成一批，上界就是最大來源本身。
    #expect(IndexBuilder.batchChunkUpperBound(target: 1, largestSource: 4_322) == 4_322)
    // 最大來源比 target 小的一般情形——上界仍然嚴格大於 target。
    #expect(IndexBuilder.batchChunkUpperBound(target: 2_000, largestSource: 10) == 2_009)

    #expect(IndexBuilder.batchChunkUpperBound(target: 5, largestSource: 7) == 11,
            "上界必須是可達的——不可達的上界只是一個比較大的數字")
}

/// **公式與生產迴圈的分歧要由生產路徑抓到，不是由測試裡的第二份迴圈。**
///
/// 上一版的「可達性」段自己寫了 `current += size; if current >= target { current = 0 }`
/// ——那是測試內的第二份演算法。改壞 `makeBatches`、helper 不動，它照樣綠
/// （#46 R3 verify，四個 lens 各自命中）。而 `batchChunkUpperBound` 在整個出貨
/// 程式碼裡**零呼叫**，所以「公式只有一份」買到的只是一個沒人用的函式。
///
/// **扛住這條性質的是這條測試自己，不是生產路徑。** 中間有一版讓 `build()` 對照
/// 並丟 `batchBoundViolated`；交叉變異（改壞迴圈 ＋ 同時刪守衛）顯示這條測試
/// 直接接手，所以那道守衛沒有扛任何東西，已移除。
///
/// 這條測試跑**真的 build**，斷言的是生產迴圈算出的最大批次不超過公式——公式與
/// 迴圈分岔時它會紅。
@Test("生產分批的最大批次不超過宣告的上界——由這條測試扛，不是由生產守衛")
func productionBatchingHonoursTheDeclaredBound() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    // 多個來源、每個好幾則 turn，配一個小 target——確保迴圈真的要切好幾批，
    // 而且「累積到 target − 1 再吃進一整個來源」那條路徑走得到。
    for file in 0..<6 {
        let lines = (0..<4).map { turn in
            turnLine(
                uuid: String(format: "%04x%04x-aaaa-bbbb-cccc-dddddddddddd", file, turn),
                session: "1111111\(file)-2222-3333-4444-555555555555",
                role: turn.isMultiple(of: 2) ? "user" : "assistant",
                text: "來源 \(file) 的第 \(turn) 段內容")
        }
        _ = try writeSession(in: corpus, project: "proj-one", file: "s\(file).jsonl", lines: lines)
    }

    final class PlanBox: @unchecked Sendable {
        private let mutex = NSLock()
        private var value: (batches: Int, largest: Int)?
        func set(_ new: (batches: Int, largest: Int)) { mutex.lock(); value = new; mutex.unlock() }
        var current: (batches: Int, largest: Int)? { mutex.lock(); defer { mutex.unlock() }; return value }
    }
    let plan = PlanBox()
    _ = try IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
        embedder: StubEmbedder(revision: "rev-A"),
        progress: { event in
            if case .batchPlan(let batches, let largest, _) = event {
                plan.set((batches, largest))
            }
        },
        batchChunkTarget: 3
    ).build()

    let observed = try #require(plan.current, "沒有收到 batchPlan——這條測試就沒有在驗任何東西")
    #expect(observed.batches > 1, "前提：target 要小到真的切成多批，否則上界無從被違反")
    // **這一行就是那道對照。** 生產路徑不再自己檢查（那道守衛驅動不了，已移除），
    // 所以公式與迴圈的分歧只會在這裡變紅。
    #expect(observed.largest
        <= IndexBuilder.batchChunkUpperBound(target: 3, largestSource: 4))
}

/// 回滾測試要在交易裡寫真的內容——只寫游標的交易證明不了「兩者一起回滾」。
private func makeRollbackChunk(uuid: String, text: String, sourceKey: String) -> CorpusChunk {
    let when = Date(timeIntervalSince1970: 1_760_000_000)
    let turn = Turn(id: uuid, role: "user", timestamp: when, text: text)
    return CorpusChunk(
        sourceKey: sourceKey, project: "proj", sessionID: "11111111-2222-3333-4444-555555555555",
        uuid: uuid, timestamp: when, role: "user", text: text,
        anchor: Anchor(source: ProjectFingerprint.of("proj"), turn: turn,
                       span: 0..<text.unicodeScalars.count, key: .forTesting))
}

/// `build()` **不再寫 `state.json`**——它曾經是「人類可讀鏡像」，而那讓它成為
/// 第三份真相來源：WAL 回滾同時帶走內容與游標之後，下一次 build 會回頭採信那份
/// 超前的鏡像，印 `✓ 索引完成（增量）` 而索引是空的、語料永遠不再被解析
/// （#44 R2 verify，devil's advocate 實測重現）。
///
/// 這條測試釘的是**不存在**，因為那才是修法。先前它釘的是「刪掉鏡像無害」——
/// 而「無害」不足以擋住上面那條路徑：那條路徑不需要有人刪它。
@Test("build 不寫 state.json——鏡像不存在，就不會被回頭採信")
func buildWritesNoStateMirror() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    _ = try IndexBuilder(location: derived, scanner: scanner,
                         embedder: StubEmbedder(revision: "rev-A")).build()

    #expect(!FileManager.default.fileExists(atPath: derived.stateURL.path),
            "鏡像存在就是第三份真相來源——它會在 scan_state 空的時候被採信")

    // 續讀仍然有效：游標在 DB 裡。
    let again = try IndexBuilder(location: derived, scanner: scanner,
                                 embedder: StubEmbedder(revision: "rev-A")).build()
    #expect(!again.wasFullRebuild)
    #expect(again.chunksIndexed == 0, "游標在 DB 裡，不該重掃")
}

/// **回滾之後一次「成功」的 build 不得產出空索引。**
///
/// 這條是 D 的直接回歸鎖，逐字重演 devil's advocate 的實測：內容與游標一起被
/// 清掉（模擬 WAL 回滾），而一份超前的 `state.json` 留在磁碟上。舊行為：
/// `chunkCount() == 0` → 守衛不 fire → 採信鏡像 → 印 ✓、索引是空的。
@Test("內容為空時不採信 state.json——不得產出「宣稱成功的空索引」")
func anEmptyIndexNeverAdoptsAStaleMirror() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    let first = try IndexBuilder(location: derived, scanner: scanner,
                                 embedder: StubEmbedder(revision: "rev-A")).build()
    #expect(first.chunksIndexed > 0, "前提：第一次確實索引到東西")

    // 手工造出一份「超前的鏡像」——舊版本的 build 每次成功都會寫出這種東西。
    let cursors = try {
        let database = try IndexDatabase(path: derived.databaseURL.path)
        defer { database.close() }
        return try database.scanState()
    }()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(cursors).write(to: derived.stateURL, options: [.atomic])

    // 模擬 WAL 回滾：內容與游標**一起**消失（那正是它們同在一個交易的後果）。
    do {
        let database = try IndexDatabase(path: derived.databaseURL.path)
        defer { database.close() }
        // 真實的 WAL 回滾是原子的：內容與它的來源連結一起消失。只刪 `chunks`
        // 會留下懸空的 `chunk_sources` 列，那是資料庫層的不一致、不是回滾。
        try database.execute("DELETE FROM chunks")
        try database.execute("DELETE FROM chunk_sources")
        try database.execute("DELETE FROM scan_state")
    }

    let after = try IndexBuilder(location: derived, scanner: scanner,
                                 embedder: StubEmbedder(revision: "rev-A")).build()
    #expect(after.chunksIndexed > 0,
            "採信了超前的鏡像——這一次 build 會印 ✓ 而索引是空的，語料永遠不再被解析")
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

    // 鏡像本來就不存在了（`build` 不寫它），所以只要清掉表就到得了那個狀態。
    #expect(!FileManager.default.fileExists(atPath: derived.stateURL.path))
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

/// 舊版本建的索引升上來時（`scan_state` 空、索引有內容）**必須被具名拒絕**，
/// 不得靜默遷移。
///
/// 上一版有一條遷移路徑，把 `state.json` 的游標搬進 `scan_state`。R3 的
/// devil's advocate 用一個可執行的 probe 推翻了它：WAL 回滾**不會**把索引清空，
/// 只丟掉最後那個交易，所以守衛（`chunkCount() == 0`）在真實回滾裡不 fire，
/// 而遷移照單全收一份超前的游標——那則 turn 永遠不會再被索引，build 不報錯。
///
/// 根本問題不是判準挑錯：**「游標涵蓋的內容是否真的在索引裡」這個事實不在磁碟上。**
/// 所以現在不猜，改為具名拒絕並要求 `--full`。
@Test("舊索引（有內容、無游標）被具名拒絕並指向 --full，不靜默遷移")
func aLegacyIndexIsRefusedRatherThanMigrated() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    _ = try IndexBuilder(location: derived, scanner: scanner,
                         embedder: StubEmbedder(revision: "rev-A")).build()

    // 構造「舊版本留下的索引」：DB 有內容、表是空的、游標在 state.json 裡。
    let cursors = try {
        let database = try IndexDatabase(path: derived.databaseURL.path)
        defer { database.close() }
        return try database.scanState()
    }()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(cursors).write(to: derived.stateURL, options: [.atomic])
    do {
        let database = try IndexDatabase(path: derived.databaseURL.path)
        defer { database.close() }
        try database.execute("DELETE FROM scan_state")
    }

    // 具名拒絕——不是靜默採信，也不是 trap。
    #expect(throws: IndexBuilder.BuildError.self) {
        _ = try IndexBuilder(location: derived, scanner: scanner,
                             embedder: StubEmbedder(revision: "rev-A")).build()
    }

    // **不得動那個檔。** 拒絕的意思是「我沒有做任何決定」，而刪掉它會銷毀
    // 使用者事後唯一能看的證據（上一版的 `try? removeItem` 正是這樣）。
    #expect(FileManager.default.fileExists(atPath: derived.stateURL.path))

    // `--full` 是錯誤訊息指的那條路，而且它真的通——一條指向死路的訊息比沒有訊息糟。
    let recovered = try IndexBuilder(location: derived, scanner: scanner,
                                     embedder: StubEmbedder(revision: "rev-A")).build(full: true)
    #expect(recovered.wasFullRebuild)
    #expect(recovered.chunksIndexed > 0)
    // `--full` 順帶清掉殘留的鏡像——那是它「從零開始」契約的一部分。
    #expect(!FileManager.default.fileExists(atPath: derived.stateURL.path))
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

// MARK: - R2 verify 修法的回歸鎖
//
// 這一段的每一條都對應一個「先前沒有任何測試在扛」的機制。CLAUDE.md：驅動不了
// 的守衛要拆掉，不是留著加註解——所以要嘛這裡有一條會紅的測試，要嘛那個守衛
// 不該存在。

/// 鎖檔是 symlink 時必須具名失敗，**不得跟著寫穿到目標檔**。
///
/// 舊的 `O_CREAT | O_EXCL` 對這件事是結構上免疫的（POSIX 要求 symlink → `EEXIST`）。
/// 為了 flock 重設計拿掉 `O_EXCL` 時那個性質被一起換掉了，而沒有任何註解提到。
/// 實測（#45 R2 verify，security lens）：45 bytes 的目標檔變成 6 bytes 的 pid，
/// 而 `ltm build` exit 0。
/// **hard link 走的是另一條路，而 `O_NOFOLLOW` 對它完全不作用。**
///
/// 上一版只補了 symlink，並在註解裡寫「一個旗標關掉整條」——那句話是假的
/// （#44 R3 verify，CRITICAL）。hard link 是一個指向受害者 inode 的**普通目錄項**，
/// `open` 會成功，接著 `ftruncate` 把真正的檔案截成零長度。若那個檔案是語料，
/// 就是**違反不變式 1 且不可回復的遺失**。
///
/// 判準因此從「擋掉 symlink」推廣成「這個 fd 指向的東西，是不是只有我這個名字
/// 指得到」——那要 `fstat`，不是旗標。
@Test("鎖檔是 hard link 時具名失敗，目標檔不被截斷")
func aHardLinkedLockFileDoesNotTruncateItsTarget() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-locktest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let victim = root.appendingPathComponent("victim")
    let payload = Data("IMPORTANT DATA THAT MUST SURVIVE".utf8)
    try payload.write(to: victim)

    let lockPath = root.appendingPathComponent("build.lock")
    // symlink 用 createSymbolicLink，hard link 沒有 FileManager API——用 link(2)。
    #expect(link(victim.path, lockPath.path) == 0, "前提：hard link 要真的建起來")

    #expect(throws: IndexBuilder.BuildError.self) {
        _ = try FileLock.acquire(at: lockPath)
    }
    #expect(try Data(contentsOf: victim) == payload,
            "鎖跟著 hard link 截斷了目標——這條路徑到得了唯讀語料")
}

@Test("鎖檔是 symlink 時具名失敗，目標檔不被截斷")
func aSymlinkedLockFileDoesNotTruncateItsTarget() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-locktest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let victim = root.appendingPathComponent("victim")
    let payload = Data("IMPORTANT DATA THAT MUST SURVIVE".utf8)
    try payload.write(to: victim)

    let lockPath = root.appendingPathComponent("build.lock")
    try FileManager.default.createSymbolicLink(at: lockPath, withDestinationURL: victim)

    #expect(throws: IndexBuilder.BuildError.self) {
        _ = try FileLock.acquire(at: lockPath)
    }
    #expect(try Data(contentsOf: victim) == payload,
            "鎖跟著 symlink 走了——這是一條任意檔案截斷的路徑")
}

/// `release()` 重複呼叫是 no-op，不是「關掉一個已經被重新配給別人的 fd」。
/// `release()` 的冪等性——**單執行緒下確定性地驗，並行下不驗，而且說明為什麼**。
///
/// 我先寫了一條並行版本（50 輪 × 8 個 task 同時 `release()`），然後對它跑變異：
/// 把實作改回 check-then-act 三步，**50 輪一次都沒紅**。那是一條會「偶爾成功」
/// 的測試，而 CLAUDE.md 對這一類的判準很清楚——不可能失敗的測試比沒有測試更糟，
/// 因為它在覆蓋率與閱讀上都算數。所以那條測試不留。
///
/// **並行安全來自 `NSLock` 保護的取出並清空，靠的是構造而不是測試**：拿到非 −1
/// 的那一個 task 是唯一會 `close()` 的，這是一個原子交換。從外部確定性地驅動
/// 那條 race 做不到——能寫的只有機率性偵測器，而那不是驗證。
///
/// 這裡驗的是可以確定性驗的那一半：釋放之後 fd 真的被清掉，所以第二次是 no-op。
@Test("release 之後再 release 是 no-op——確定性的那一半")
func releasingTheLockTwiceIsANoOp() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-locktest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let lockURL = root.appendingPathComponent("build.lock")
    let lock = try FileLock.acquire(at: lockURL)
    lock.release()

    // 鎖真的放掉了——另一個 acquire 拿得到。
    let second = try FileLock.acquire(at: lockURL)
    defer { second.release() }

    // 第二次 release 不得干擾任何人：它若真的又 close 一次，關掉的會是
    // `second` 剛拿到的那個號碼，於是下面這次 acquire 會發現鎖沒被持有。
    lock.release()
    #expect(throws: IndexBuilder.BuildError.self) {
        _ = try FileLock.acquire(at: lockURL)
    }
}



/// **derived 目錄底下的檔案不得跟著任何連結走——symlink 與 hard link 都要驗。**
///
/// 上一版只驗 symlink，而 hard link 版**完全沒關**：實測把一個語料 turn 檔
/// hard link 成 `vectors.bin`，`ltm query` 把它從 1,391 bytes 截成 32，而 build
/// 回報「✓ 索引完成」（#44 R5 verify，devil's advocate）。
///
/// 上一版還有一個沒寫下來的前提，讓它**在三分之二的 fixture 上是假綠**：
/// `truncateSidecar` 的 target = `vector_count × dimension × 4`，而
/// `StubEmbedder.dimension == 4`，所以 target = `rows × 16`；受害者 32 bytes 時
/// 只有 `rows == 1`（target 16 < 32）會真的截短。`rows == 2` 時 truncate 是 no-op，
/// `rows == 3` 時先丟 `sidecarShorterThanDeclared`——**兩種都綠，而 symlink 照樣
/// 被跟隨**。那兩個數字沒有任何一個被寫在測試裡。
///
/// 所以這一版把它**寫成斷言**：受害者必須嚴格大於側車的 target，否則測試自己
/// 報前提不成立。語料多一行、或 `StubEmbedder.dimension` 改個值，會讓這條前提
/// 變紅，而不是讓回歸鎖靜默消失。
@Test(
    "derived 檔案是 symlink 或 hard link 時具名失敗，目標檔不被截斷或覆寫",
    arguments: [
        // 五個入口 × 兩種連結。`-wal` / `-shm` 是**既有的**第四、第五個，而上一版
        // 的註解正好寫著「下一個新增的 derived 檔案會是第四個漏網的」。
        ("vectors.bin", true), ("vectors.bin", false),
        ("index.sqlite3", true), ("index.sqlite3", false),
        ("index.sqlite3-wal", true), ("index.sqlite3-wal", false),
        ("index.sqlite3-shm", true), ("index.sqlite3-shm", false),
        ("build.lock", true), ("build.lock", false),
    ])
func derivedFilesDoNotFollowLinks(entry: (name: String, symbolic: Bool)) throws {
    // **每個 case 一個全新的 workspace。** 先前是一個迴圈共用一份，於是前一輪把
    // 受害者寫成 77,824 bytes 的 SQLite 檔之後，後面幾輪的斷言就在一個被污染的
    // 前提上跑——同一條測試裡的跨迭代狀態污染，正是這一輪要消滅的那類問題。
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try derived.createRootIfNeeded()
    try writeTurns(in: corpus, texts: ["第一段內容"])

    // 先建一份真的索引：第一次 build 走全量路徑，而 `discardDerivedArtifacts`
    // 會 `removeItem` 掉連結——`--full` 是安全的，危險的是增量與查詢路徑。
    let stub = StubEmbedder(revision: "rev-A")
    _ = try IndexBuilder(location: derived,
                         scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
                         embedder: stub).build()

    // **把那個沒寫下來的算式寫出來。** 上一版有一個沒被斷言的前提，讓它在
    // 三分之二的 fixture 上是假綠：`truncateSidecar` 的 target =
    // `vector_count × dimension × 4`，受害者不夠大時 truncate 就是 no-op，或
    // 在截短前先丟別的 error 而被 `#expect(throws:)` 錯誤地滿足。
    let rows = try {
        let database = try IndexDatabase(path: derived.databaseURL.path)
        defer { database.close() }
        return try database.meta("vector_count").flatMap(Int.init) ?? 0
    }()
    let sidecarTarget = rows * stub.dimension * MemoryLayout<Float>.size
    #expect(sidecarTarget > 0, "前提：索引要真的有向量，否則側車 target 是 0、truncate 無事可做")

    let dbPath = derived.databaseURL.path
    let target: URL
    let victim: URL
    switch entry.name {
    case "vectors.bin": target = derived.vectorsURL
    case "index.sqlite3": target = derived.databaseURL
    case "index.sqlite3-wal": target = URL(fileURLWithPath: dbPath + "-wal")
    case "index.sqlite3-shm": target = URL(fileURLWithPath: dbPath + "-shm")
    default: target = derived.lockURL
    }
    // 側車與鎖會被 `ftruncate`，所以受害者必須**嚴格大於** target 才驗得到截短。
    // 資料庫那幾個要**零長度**：非空目標倖存只是因為 sqlite 拒絕解析非資料庫檔案
    // ——那是意外、不是有人選的緩解，而它對任何空檔案都不成立。
    let wantsFatVictim = entry.name == "vectors.bin" || entry.name == "build.lock"
    victim = corpus.appendingPathComponent("victim.jsonl")
    let payload = wantsFatVictim ? Data(repeating: 0x41, count: sidecarTarget + 1) : Data()
    try payload.write(to: victim)
    if wantsFatVictim {
        #expect(payload.count > sidecarTarget,
                "受害者必須嚴格大於側車 target（\(sidecarTarget)），否則 truncate 是 no-op 而測試綠得沒有意義")
    }

    try? FileManager.default.removeItem(at: target)
    if entry.symbolic {
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
    } else {
        #expect(link(victim.path, target.path) == 0, "前提：hard link 要建得起來")
    }

    let kind = entry.symbolic ? "symlink" : "hardlink"
    #expect(throws: (any Error).self, "\(entry.name) 沒有拒絕 \(kind)") {
        _ = try IndexBuilder(
            location: derived,
            scanner: CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting),
            embedder: stub
        ).build()
    }
    let after = try Data(contentsOf: victim)
    #expect(after == payload,
            "\(entry.name)/\(kind) 寫穿了語料（\(payload.count) → \(after.count) bytes）")
    for suffix in ["-wal", "-shm"] {
        #expect(!FileManager.default.fileExists(atPath: victim.path + suffix),
                "\(entry.name)/\(kind) 在語料樹裡留下了 \(suffix)")
    }
}

/// **游標涵蓋不住索引時要拒絕——不論 `scan_state` 是不是空的。**
///
/// 上一版的判準是 `previousState.files.isEmpty`，那是一個代理；而它在同一輪的
/// 另一個修法下失效了（負游標從「丟掉整列」改成「修成必然對不上的游標」之後，
/// `files` 不再是空的）。於是「表裡只有壞游標」這個先前被擋下的狀態改為靜靜走
/// 增量路徑，已從語料刪除的來源永不作廢——**違反不變式 2，而且是那一輪引入的**
/// （#44 R4 verify，codex lens）。
@Test("部分游標缺失時同樣拒絕——判準是涵蓋率，不是表空不空")
func aPartiallyCoveredIndexIsRefused() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    for file in 0..<2 {
        _ = try writeSession(
            in: corpus, project: "proj-one", file: "s\(file).jsonl",
            lines: [turnLine(
                uuid: String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", file),
                session: "1111111\(file)-2222-3333-4444-555555555555",
                role: "user", text: "來源 \(file) 的內容")])
    }
    _ = try IndexBuilder(location: derived, scanner: scanner,
                         embedder: StubEmbedder(revision: "rev-A")).build()

    // 只刪掉**其中一個**來源的游標——`scan_state` 仍非空，所以舊的代理判準會放行。
    do {
        let database = try IndexDatabase(path: derived.databaseURL.path)
        defer { database.close() }
        try database.execute("DELETE FROM scan_state WHERE source_key LIKE '%s0.jsonl'")
        #expect(try !database.scanState().files.isEmpty, "前提：表不是空的，代理判準會放行")
        #expect(try database.sourcesWithoutCursor().count == 1)
    }

    #expect(throws: IndexBuilder.BuildError.self) {
        _ = try IndexBuilder(location: derived, scanner: scanner,
                             embedder: StubEmbedder(revision: "rev-A")).build()
    }
}

/// 有 chunk 但**零 source mapping** 的舊索引也要被拒絕。
///
/// `createSchema()` 全用 `CREATE TABLE IF NOT EXISTS`，所以早於 `chunk_sources`
/// 的索引升上來時那張表是空的而 `chunks` 有內容。上一版的 `sourcesWithoutCursor()`
/// 只查「有 mapping 卻無游標」，於是它在這一類輸入上**比它取代的代理更弱**
/// （#44 R5 verify）——而同一次改動還把會暴露這個洞的狀態從另一條測試裡挪開了。
@Test("有 chunk 但零 source mapping 的索引被拒絕")
func anIndexWithChunksButNoSourceMappingIsRefused() throws {
    let (corpus, derived) = try makeWorkspace()
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derived.root)
    }
    try writeTurns(in: corpus, texts: ["第一段內容"])
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    _ = try IndexBuilder(location: derived, scanner: scanner,
                         embedder: StubEmbedder(revision: "rev-A")).build()

    // 構造「早於 chunk_sources 的索引」：chunks 有內容、mapping 表空、游標也空。
    do {
        let database = try IndexDatabase(path: derived.databaseURL.path)
        defer { database.close() }
        try database.execute("DELETE FROM chunk_sources")
        try database.execute("DELETE FROM scan_state")
        #expect(try database.chunkCount() > 0, "前提：chunks 仍有內容")
        #expect(try database.sourcesWithoutCursor().count == 1)
    }

    #expect(throws: IndexBuilder.BuildError.self) {
        _ = try IndexBuilder(location: derived, scanner: scanner,
                             embedder: StubEmbedder(revision: "rev-A")).build()
    }
}
