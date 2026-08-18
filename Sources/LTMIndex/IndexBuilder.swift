import Foundation
import LTMCore

/// 一次建置的結果。
public struct BuildReport: Sendable, Equatable {
    public let chunksIndexed: Int
    /// 這一輪有新內容的**來源檔**數（distinct source key），不是 chunk 數。
    ///
    /// 兩者的差別曾經被混用：`QueryOutcome.refreshedSources` 的文件寫「來源檔數」，
    /// 而它拿到的值是 `scan.chunks.count`。名字說一件事、值是另一件事，而型別
    /// 都是 `Int` 所以編譯器不會有意見。
    public let sourcesRefreshed: Int
    public let sourcesInvalidated: Int
    /// 這一輪**讀不到**的來源檔（權限、I/O 錯誤）。
    ///
    /// 與「消失」嚴格區分：消失的來源會被作廢，讀不到的不會——把後者當成前者
    /// 會刪掉還存在的內容。但**不作廢就必須說出來**，否則索引裡少了這些檔的
    /// 新內容，而使用者看到的是一次成功的建置。
    public let sourcesUnreadable: [String]
    public let skipped: SkipTally
    /// 這次是不是從零開始（版本／revision 不符或指定 `--full`）。
    public let wasFullRebuild: Bool
    public let embeddingRevision: String
    public let totalChunks: Int
}

/// 把掃描、索引、向量三件事串起來的建置流程。
public struct IndexBuilder: Sendable {
    public let location: DerivedLocation
    public let scanner: CorpusScanner
    private let embedder: any EmbeddingProvider

    public init(location: DerivedLocation, scanner: CorpusScanner, embedder: any EmbeddingProvider) {
        self.location = location
        self.scanner = scanner
        self.embedder = embedder
    }

    public enum BuildError: Error, Sendable, Equatable {
        /// 另一個建置正在進行。**不等待**：建置可能跑很久，讓第二個行程無限期
        /// 卡住比明確失敗更糟——呼叫端無從得知它是在做事還是在等。
        case lockHeld(path: String)
        /// 側車檔比索引宣稱的短。
        ///
        /// 這**不能**靠 `ftruncate` 修：對較短的檔案指定較大的 offset 是
        /// **補零延長**（POSIX 語意），不是重建缺口。補出來的零向量與任何查詢
        /// 的點積都是 0——向量通道因此靜默失效，而筆數核對會通過。
        case sidecarShorterThanDeclared(declared: Int, found: Int)
        /// 需要整份重建，但呼叫端不允許（查詢路徑）。
        case fullRebuildRequired(detail: String)
        case stateUnreadable(detail: String)
    }

    /// 建置索引。
    ///
    /// - Parameter full: 略過增量、從零重建。
    /// - Parameter refusingFullRebuild: `true` 時，若判定需要整份重建就**拋錯而不是
    ///   重建**。查詢路徑用它。
    ///
    ///   `refreshIncrementally` 的註解曾經宣稱「查詢路徑不可能觸發整份重建」，理由是
    ///   `query` 前段已檢查過三個 stamp。那個推理有個洞：`query` 讀 stamp 時**不持鎖**，
    ///   而這裡拿到鎖之後會**重讀**一次。兩次讀之間若有另一個行程完成一次會改
    ///   `layout_version` 的建置（升級後的 `ltm` 與還在跑的舊 `ltm query` 併存就夠），
    ///   第二次讀就會 mismatch ⇒ `discardDerivedArtifacts()` 從**查詢路徑**刪掉
    ///   DB、側車與 state。
    ///
    ///   規則叫呼叫端別走某條路，遠弱於把那條路拆掉。所以這裡不是把註解寫清楚，
    ///   是讓那個前提變成呼叫端可以強制的東西。
    public func build(full: Bool = false, refusingFullRebuild: Bool = false) throws -> BuildReport {
        try location.createRootIfNeeded()
        let lock = try FileLock.acquire(at: location.lockURL)
        defer { lock.release() }

        // 版本／revision 判準先於任何寫入：不符就整份重來，而不是在舊索引上疊。
        // 混一份舊 revision 的向量進去不會報錯，只會讓距離失去意義。
        //
        // **注意這裡沒有檢查 `anchorSourceRule`。** 目前不會出事，但那是因為
        // 定址規則換代時 `layoutVersion` 剛好也跟著升——換句話說，這個守衛的
        // 完整性靠的是兩個常數碰巧一起改，不是靠這段程式碼。日後若有人只換
        // 定址規則而沒動 layout，新舊規則的 anchor 會被疊進同一份索引，而
        // 唯一的症狀是使用歷史對不上（全部報成 orphan）。
        //
        // 沒有現在就補進去，是因為補了會讓「同一件事有兩個真相來源」——
        // 正確的修法是讓規則換代**必然**帶動 layout 升版，而那需要一個
        // 目前不存在的機制。留這則註解，是為了讓下一個改定址規則的人看見。
        let existingStamps = try? currentStamps()
        let stampsMismatch =
            existingStamps.map {
                $0.layoutVersion != IndexDatabase.layoutVersion
                    || $0.embeddingRevision != embedder.revision
            } ?? false
        let rebuildFromScratch = full || stampsMismatch
        if rebuildFromScratch && refusingFullRebuild {
            throw BuildError.fullRebuildRequired(
                detail: full
                    ? "呼叫端要求整份重建，但這條路徑不允許"
                    : "索引的版本戳記與執行期不符（可能是另一個行程剛完成一次會改版本的建置）")
        }

        if rebuildFromScratch { try discardDerivedArtifacts() }

        let database = try IndexDatabase(path: location.databaseURL.path)
        defer { database.close() }
        try database.probeTokenizers()
        try database.createSchema()

        // state 讀不到而 DB 存在 → **不可**當成空 state 繼續。
        //
        // 那會在既有索引上重掃全語料 upsert（見 FTS 重複索引那條），而且使用者不會
        // 知道發生過什麼。`stateUnreadable` 先前宣告了卻從未被丟出——那條錯誤路徑
        // 是死的，CLI 的處理分支也因此永遠到不了。
        var previousState = ScanState()
        if !rebuildFromScratch {
            let stateExists = FileManager.default.fileExists(atPath: location.stateURL.path)
            let databaseExists = FileManager.default.fileExists(atPath: location.databaseURL.path)
            if stateExists {
                do { previousState = try readState() } catch {
                    throw BuildError.stateUnreadable(detail: "\(location.stateURL.path)：\(error)")
                }
            } else if databaseExists {
                throw BuildError.stateUnreadable(
                    detail: "索引存在但 \(location.stateURL.lastPathComponent) 不見了；"
                        + "用 `ltm build --full` 從零重建")
            }
        }
        let scan = try scanner.scan(previous: previousState)
        let refreshedSourceKeys = Set(scan.chunks.map(\.sourceKey))

        var vectorRow = rebuildFromScratch ? 0 : (try database.meta("vector_count").flatMap(Int.init) ?? 0)
        // 上一輪若在寫側車檔途中中止，檔案會比 `vector_count` 記錄的長。先截回
        // 已知長度再 append——多出來的那段沒有任何 chunk 指向它，留著只會讓
        // row 編號與實際內容錯開。
        try truncateSidecar(toRows: vectorRow)

        var newVectors: [[Float]] = []
        var pendingRowUpdates: [(chunkRowID: Int64, vectorRow: Int)] = []
        var indexed = 0

        // 第一階段（交易外）：算向量、決定 row 編號，但**還不提交任何指標**。
        // 第二階段：側車落地並 fsync。第三階段：交易內一次提交 chunk 與指標。
        //
        // 順序是刻意的，而且先前寫反了：舊實作在交易內就提交了 `vector_count`，
        // 交易外才 append 側車。崩潰落在兩者之間會留下「DB 宣稱 N 個向量、檔案只有
        // N−k 個」，而下一輪的 `truncateSidecar` 對**較短**的檔案呼叫 ftruncate 會
        // **補零延長**（POSIX 語意）而不是重建缺口，接著從較大的 row 繼續 append
        // ——永久且靜默的 row 錯位：A 的向量被算到 B 身上。
        try database.transaction {
            for sourceKey in scan.invalidatedSources {
                try database.deleteChunks(sourceKey: sourceKey)
            }
            let grouped = Dictionary(grouping: scan.chunks, by: \.sourceKey)
            for (sourceKey, chunks) in grouped.sorted(by: { $0.key < $1.key }) {
                let rowIDs = try database.insert(chunks: chunks, sourceKey: sourceKey)
                for (offset, chunk) in chunks.enumerated() {
                    // 產不出向量的 chunk 仍然留在 lexical 通道裡——少一路比整段
                    // 不可檢索好，而且 `vector_row` 為 NULL 讓「這一筆沒有向量」
                    // 是可查詢的事實，不是猜測。
                    guard let vector = try embedder.vector(for: chunk.text) else { continue }
                    newVectors.append(vector)
                    pendingRowUpdates.append((chunkRowID: rowIDs[offset], vectorRow: vectorRow))
                    vectorRow += 1
                }
                indexed += chunks.count
            }
        }

        // 側車先完整落地並 fsync，**之後**才提交指向它的指標。這樣崩潰最多留下
        // 多餘的 bytes（下一輪 truncate 得掉），而不會留下指向不存在向量的指標。
        try appendVectors(newVectors)

        try database.transaction {
            for update in pendingRowUpdates {
                try database.execute(
                    "UPDATE chunks SET vector_row = ? WHERE id = ?",
                    bind: [.integer(Int64(update.vectorRow)), .integer(update.chunkRowID)])
            }
            try database.setMeta("vector_count", String(vectorRow))
            try database.setMeta("vector_dimension", String(embedder.dimension))
            try database.writeStamps(embeddingRevision: embedder.revision)
        }

        try writeState(scan.state)

        return BuildReport(
            chunksIndexed: indexed,
            sourcesRefreshed: refreshedSourceKeys.count,
            sourcesInvalidated: scan.invalidatedSources.count,
            sourcesUnreadable: scan.unreadableSources.sorted(),
            skipped: scan.skipped,
            wasFullRebuild: rebuildFromScratch,
            embeddingRevision: embedder.revision,
            totalChunks: try database.chunkCount())
    }

    // MARK: - 衍生產物

    private func currentStamps() throws -> IndexDatabase.Stamps {
        guard FileManager.default.fileExists(atPath: location.databaseURL.path) else {
            return IndexDatabase.Stamps(layoutVersion: nil, embeddingRevision: nil)
        }
        let database = try IndexDatabase(path: location.databaseURL.path)
        defer { database.close() }
        return try database.stamps()
    }

    private func discardDerivedArtifacts() throws {
        let fm = FileManager.default
        // **刪除失敗必須終止**：`--full` 的契約是「從零開始」，而 `try?` 會讓一個
        // 刪不掉的舊產物安靜地留下來，之後的建置疊在它上面。
        for url in [location.databaseURL, location.vectorsURL, location.stateURL] {
            guard fm.fileExists(atPath: url.path) else { continue }
            try fm.removeItem(at: url)
        }
        // SQLite 的 WAL 與 shared-memory 檔要一起清，否則新開的資料庫會接上
        // 舊索引的未完成交易。
        for suffix in ["-wal", "-shm"] {
            try? fm.removeItem(atPath: location.databaseURL.path + suffix)
        }
    }

    /// 把側車檔截回索引宣稱的長度。
    ///
    /// **只縮不長。** `FileHandle.truncate(atOffset:)` 對較短的檔案指定較大的
    /// offset 會補零延長而不是報錯，所以「截斷」這個名字在這個方向上是騙人的：
    /// 缺掉的向量會被一堆零取代，與任何查詢的點積都是 0，而 `vector_count` 的
    /// 核對從此永遠通過——向量通道靜默失效，沒有任何訊號。
    ///
    /// 檔案比宣稱的短，代表向量真的不見了。那是拒答的理由，不是修補的機會。
    private func truncateSidecar(toRows rows: Int) throws {
        let path = location.vectorsURL.path
        let rowBytes = embedder.dimension * MemoryLayout<Float>.size
        guard FileManager.default.fileExists(atPath: path) else {
            // **檔案整個不見 = 找到 0 列，不是「沒事可做」。**
            //
            // 這裡先前是無條件早退，於是「向量真的不見了」的最極端情形恰好是唯一
            // 沒被下面那道守衛涵蓋的。後果正是 `build()` 那段順序註解逐字宣稱要防的：
            // `vectorRow` 仍從 `vector_count` 起算、`appendVectors` 重建一個新檔，
            // 舊 chunk 的 `vector_row = 0` 於是指到新檔的第 0 列——**A 的相似度用
            // B 的向量算**，而 `ltm build` 印出「✓ 索引完成」。
            //
            // `rows == 0` 才是真的沒事：索引本來就沒宣稱任何向量。
            guard rows == 0 else {
                throw BuildError.sidecarShorterThanDeclared(declared: rows, found: 0)
            }
            return
        }
        let target = UInt64(rows * rowBytes)
        let handle = try FileHandle(forUpdating: location.vectorsURL)
        defer { try? handle.close() }
        let current = try handle.seekToEnd()
        guard current >= target else {
            throw BuildError.sidecarShorterThanDeclared(
                declared: rows, found: rowBytes == 0 ? 0 : Int(current) / rowBytes)
        }
        try handle.truncate(atOffset: target)
    }

    private func appendVectors(_ vectors: [[Float]]) throws {
        guard !vectors.isEmpty else { return }
        let data = VectorSidecar.encode(vectors)
        if FileManager.default.fileExists(atPath: location.vectorsURL.path) {
            let handle = try FileHandle(forWritingTo: location.vectorsURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } else {
            // 全新的側車檔走 temp + rename：rename 在同一個檔案系統上是原子的，
            // 所以讀者要嘛看到完整的檔案、要嘛看不到檔案，不會看到半份。
            let temporary = location.vectorsURL.appendingPathExtension("tmp")
            try data.write(to: temporary, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(location.vectorsURL, withItemAt: temporary)
            // rename 之後再 fsync 一次目錄項次：`.atomic` 保證的是「不會看到半份」，
            // 不保證 bytes 已經到磁碟。
            if let handle = try? FileHandle(forWritingTo: location.vectorsURL) {
                try? handle.synchronize()
                try? handle.close()
            }
        }
    }

    private func readState() throws -> ScanState {
        let data = try Data(contentsOf: location.stateURL)
        return try JSONDecoder().decode(ScanState.self, from: data)
    }

    private func writeState(_ state: ScanState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(state).write(to: location.stateURL, options: [.atomic])
    }
}

/// 單寫者鎖。
///
/// `O_CREAT | O_EXCL` 的建檔在 POSIX 上是原子的，所以「誰建成功誰持有」不需要
/// 額外的協調。**不等待**：建置可能很久，讓第二個行程無限期等待會讓它看起來
/// 像當掉了。
public struct FileLock: Sendable {
    public let url: URL

    public static func acquire(at url: URL) throws -> FileLock {
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else {
            throw IndexBuilder.BuildError.lockHeld(path: url.path)
        }
        // 把 pid 寫進去：鎖檔殘留時（行程被 SIGKILL）使用者看得出是誰留下的。
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
        close(descriptor)
        return FileLock(url: url)
    }

    public func release() {
        try? FileManager.default.removeItem(at: url)
    }
}
