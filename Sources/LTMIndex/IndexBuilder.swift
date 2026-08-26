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
/// 一次分批提交的進度（#45）。
///
/// **這個型別存在的前提是 #44 的分批提交。** 在那之前沒有可回報的中間狀態——
/// 整個 build 在單一交易內，外部讀取者看到的 `chunks` 是 0，`index.sqlite3` 停在
/// 4 KB。那不是「有進度但沒印」，是**進度在提交之前不存在**。
public struct BuildProgress: Sendable, Equatable {
    /// 已完成的批次（由 1 起算）。
    public let batch: Int
    public let totalBatches: Int
    public let chunksDone: Int
    public let chunksTotal: Int
}

public struct IndexBuilder: Sendable {
    public let location: DerivedLocation
    public let scanner: CorpusScanner
    private let embedder: any EmbeddingProvider
    /// 每批提交後被呼叫。`nil` = 不回報（既有呼叫端的行為不變）。
    ///
    /// 用 callback 而不是讓 `IndexBuilder` 自己 print：這一層不該決定輸出去哪
    /// （stdout 的 `--json` 形態是給程式讀的），那是 CLI 的決定。
    private let progress: (@Sendable (BuildProgress) -> Void)?
    /// 一批最多累積幾個 chunk 的向量再落地（#44 分批、#46 記憶體上界）。
    ///
    /// 以 **chunk 數**為單位而不是來源數：一個來源可能有數千個 chunk，按來源
    /// 分批的話上界仍由最大的那個來源決定。
    ///
    /// **預設值 2,000 沒有量測支撐**（#46）。2,000 × 512 維 × 4 B ≈ 4 MB 的向量
    /// 累積，對任何機器都不算什麼——選它是為了「明顯安全」，不是為了最佳。要調
    /// 它得先有 `docs/measurements/` 的峰值 RSS vs 語料規模紀錄。
    ///
    /// 可注入的第一個理由是測試：分批的行為只有在批次小於語料時才觀察得到，
    /// 而寫一個 2,000 chunk 的 fixture 只是為了驗分批，成本與收益不成比例。
    public let batchChunkTarget: Int

    public init(
        location: DerivedLocation, scanner: CorpusScanner, embedder: any EmbeddingProvider,
        progress: (@Sendable (BuildProgress) -> Void)? = nil,
        batchChunkTarget: Int = 2_000
    ) {
        self.location = location
        self.scanner = scanner
        self.embedder = embedder
        self.progress = progress
        precondition(batchChunkTarget > 0, "批次大小必須為正——0 或負數會讓迴圈永遠不落地")
        self.batchChunkTarget = batchChunkTarget
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

        var indexed = 0

        // ## 分批提交（#44）
        //
        // **先前整個嵌入迴圈在單一 `database.transaction` 內**——而這個檔案上面
        // 那段註解逐字寫著「第一階段（**交易外**）：算向量」。code 與它自己的
        // 設計說明分岔了，而三個後果全部由此而來：
        //
        // | 後果 | 機制 |
        // |---|---|
        // | 中斷全丟 | 沒有中間 COMMIT |
        // | 寫鎖握滿全程 | `BEGIN IMMEDIATE` 持有到最後 |
        // | 記憶體無上限 | 向量必須撐到交易結束才能寫檔 |
        //
        // 實測代價：一次 1 小時 20 分的全量 build 被中斷後，`index.sqlite3` 停在
        // 4 KB、WAL 751 MB、`chunks` 為 0——全部 rollback。
        //
        // **推測 code 為何分岔**：`insert(chunks:)` 回傳 rowID，而配對
        // rowID↔vectorRow 最直觀是寫在同一個迴圈，而那迴圈已在交易內（insert
        // 需要）。embedding 是被「順路」拉進去的，不是設計決定。
        //
        // ## 每批的四段順序，以及為什麼不能改
        //
        // ① 交易外算向量 → ② 交易內 delete+insert 取 rowID → ③ 交易外側車
        // append+fsync → ④ 交易內提交指標。
        //
        // **③ 必須在 ④ 之前**（原註解已寫，是付過代價的）：`truncateSidecar` 對
        // 較短的檔案呼叫 `ftruncate` 會**補零延長**（POSIX 語意）而非重建缺口，
        // 於是「DB 宣稱 N 個向量、檔案只有 N−k 個」會演變成永久且靜默的 row
        // 錯位——A 的向量被算到 B 身上，而檢索不會報錯。
        //
        // ## 只刪 invalidated 來源——**不可**無條件刪整批
        //
        // 第一版對每批的每個來源都先 `deleteChunks` 再 insert，理由是「崩在
        // insert 與寫 state 之間會重複索引」。**那個修法破壞了 append 語意**：
        // 一個檔案被追加內容時，scanner 只吐出**新增的** chunk（prefix 相符 →
        // 不是 invalidated），無條件刪會把先前已索引的部分一起刪掉。
        //
        // 由不變式 2 的 property test 抓到（seed 47）：`create(f2,[2])` 之後
        // `append(f2,#5)`，增量少了 turn 2 的 chunk 而全量重建有。**那正是那條
        // 測試存在的理由**——它守的是「增量 ≡ 全量」，而這個 bug 只在特定的
        // 變異序列下出現，逐案想不出來。
        //
        // 重複索引的風險改用另一個方式縮小：insert 與指標更新併進**同一個**
        // 交易（見下方 ②④），把窗口壓到「交易提交 → 寫 state」之間。
        let grouped = Dictionary(grouping: scan.chunks, by: \.sourceKey)

        // 只失效、沒有新 chunk 的來源（檔案被刪／改寫成空）先清掉。
        let deleteOnly = scan.invalidatedSources.subtracting(grouped.keys)
        if !deleteOnly.isEmpty {
            try database.transaction {
                for sourceKey in deleteOnly.sorted() { try database.deleteChunks(sourceKey: sourceKey) }
            }
        }

        // 批次以 **chunk 數**為單位而不是來源數：一個來源可能有數千個 chunk，
        // 按來源分批的話記憶體上界仍然由最大的那個來源決定。
        //
        var batches: [[String]] = []
        var current: [String] = []
        var currentCount = 0
        for sourceKey in grouped.keys.sorted() {
            current.append(sourceKey)
            currentCount += grouped[sourceKey]?.count ?? 0
            if currentCount >= batchChunkTarget {
                batches.append(current)
                current = []
                currentCount = 0
            }
        }
        if !current.isEmpty { batches.append(current) }

        // **stamps 與 dimension 在批次開始之前就寫**（#44）。
        //
        // 它們描述的是**這個 builder**（layout 版本、embedding revision、維度），
        // 不是內容——所以不該等內容做完才寫。
        //
        // 分批重構的第一版把它們留在批次內，於是崩掉的 build 從未寫 layout 版本，
        // 第二次跑看到「未知」→ 判定需要**全量重建** → 把已完成的批次全丟掉。
        // 症狀正好與 #44 要修的東西相同（重跑從零開始），但根因在別處——被
        // `rerunAfterCrashDoesNotRecomputeCompletedWork` 抓到。
        //
        // 順帶：批次數為零時（沒有新 chunk 的增量、空語料）這裡仍然會寫，
        // 所以「零批次的 build 讓索引宣稱未知版本」那個 bug 也一併關掉。
        try database.transaction {
            try database.setMeta("vector_dimension", String(embedder.dimension))
            try database.setMeta("vector_count", String(vectorRow))
            try database.writeStamps(embeddingRevision: embedder.revision)
        }

        // state 逐批累積：崩在中途時，已完成來源的 entry 已經在磁碟上，重跑
        // 的 scanner 不會再吐出它們。**沒有這一步，分批提交只降低了「資料丟失」
        // 而沒有降低「重算成本」**——使用者感受到的中斷代價一點都沒變。
        var committedState = previousState
        let totalChunks = scan.chunks.count
        var doneChunks = 0

        for (batchIndex, batch) in batches.enumerated() {
            let batchChunks = batch.flatMap { grouped[$0] ?? [] }

            // ① 交易外：算向量。慢、不持鎖、可中斷。
            var vectors: [[Float]?] = []
            vectors.reserveCapacity(batchChunks.count)
            for chunk in batchChunks {
                // 產不出向量的 chunk 仍然留在 lexical 通道裡——少一路比整段
                // 不可檢索好，而且 `vector_row` 為 NULL 讓「這一筆沒有向量」
                // 是可查詢的事實，不是猜測。
                vectors.append(try embedder.vector(for: chunk.text))
            }

            // ② 交易外：側車落地並 fsync。**必須在寫指標的交易之前**。
            //
            // row 編號在這裡就決定了，所以不需要先 insert 拿 rowID——這讓 insert
            // 與指標更新可以合成同一個交易（下面 ③）。
            var batchVectors: [[Float]] = []
            var rowForChunk: [Int?] = []
            for vector in vectors {
                if let vector {
                    batchVectors.append(vector)
                    rowForChunk.append(vectorRow)
                    vectorRow += 1
                } else {
                    rowForChunk.append(nil)
                }
            }
            try appendVectors(batchVectors)

            // ③ 單一交易：刪失效來源 + insert + 寫指標 + 更新 vector_count。
            //
            // 合成一個交易的理由是**縮小重複索引的窗口**：insert 與指標若分兩個
            // 交易，崩在中間會留下 vector_row 為 NULL 的 chunk，而它們既已提交、
            // state 又沒寫，下一輪會再插一次。
            try database.transaction {
                for sourceKey in batch where scan.invalidatedSources.contains(sourceKey) {
                    try database.deleteChunks(sourceKey: sourceKey)
                }
                var cursor = 0
                for sourceKey in batch {
                    guard let chunks = grouped[sourceKey] else { continue }
                    let ids = try database.insert(chunks: chunks, sourceKey: sourceKey)
                    for id in ids {
                        if let row = rowForChunk[cursor] {
                            try database.execute(
                                "UPDATE chunks SET vector_row = ? WHERE id = ?",
                                bind: [.integer(Int64(row)), .integer(id)])
                        }
                        cursor += 1
                    }
                }
                try database.setMeta("vector_count", String(vectorRow))
            }

            // ⑤ 本批來源的 state 落地。
            for sourceKey in batch {
                if let entry = scan.state.files[sourceKey] { committedState.files[sourceKey] = entry }
            }
            for sourceKey in deleteOnly { committedState.files.removeValue(forKey: sourceKey) }
            try writeState(committedState)

            indexed += batchChunks.count
            doneChunks += batchChunks.count
            progress?(
                BuildProgress(
                    batch: batchIndex + 1, totalBatches: batches.count,
                    chunksDone: doneChunks, chunksTotal: totalChunks))
        }

        // 全部批次成功之後才寫完整 state——涵蓋沒有新 chunk 但 metadata 有變的來源。
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
