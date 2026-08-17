import Foundation
import LTMCore

/// 一次建置的結果。
public struct BuildReport: Sendable, Equatable {
    public let chunksIndexed: Int
    public let sourcesInvalidated: Int
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
        case stateUnreadable(detail: String)
    }

    /// 建置索引。
    ///
    /// - Parameter full: 略過增量、從零重建。
    public func build(full: Bool = false) throws -> BuildReport {
        try location.createRootIfNeeded()
        let lock = try FileLock.acquire(at: location.lockURL)
        defer { lock.release() }

        // 版本／revision 判準先於任何寫入：不符就整份重來，而不是在舊索引上疊。
        // 混一份舊 revision 的向量進去不會報錯，只會讓距離失去意義。
        let existingStamps = try? currentStamps()
        let stampsMismatch =
            existingStamps.map {
                $0.layoutVersion != IndexDatabase.layoutVersion
                    || $0.embeddingRevision != embedder.revision
            } ?? false
        let rebuildFromScratch = full || stampsMismatch

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
            sourcesInvalidated: scan.invalidatedSources.count,
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

    private func truncateSidecar(toRows rows: Int) throws {
        let path = location.vectorsURL.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let handle = try FileHandle(forUpdating: location.vectorsURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(rows * embedder.dimension * MemoryLayout<Float>.size))
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
