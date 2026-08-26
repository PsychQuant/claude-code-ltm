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
public enum BuildProgress: Sendable, Equatable {
    /// **掃描結束，分母已知。** 在任何 embedding 之前發生，成本近乎零。
    ///
    /// 第一版沒有這一則，於是第一行輸出要等整批 embedding + 側車寫入 + DB commit
    /// 全部完成——而一批的實際上界是最大的那個來源檔（見 #47），所以最壞情況下
    /// 那仍然是數分鐘的沉默。#45 的核心症狀（「慢」與「卡死」外觀相同）原封不動。
    ///
    /// `vectorsNeeded` 在目前的設計裡**恆等於** `chunks`：每個新掃到的 chunk 都要
    /// 算一次向量，沒有可以跳過的。分開列是因為 #45 逐字要了三個數字，而把兩個
    /// 相同的數字合成一個會讓日後真的分岔時沒有地方放。
    case scanCompleted(files: Int, chunks: Int, vectorsNeeded: Int)

    /// 分批算完之後的計畫，含**可以精確算出來**的那一項記憶體上界。
    ///
    /// `estimatedVectorBytes` 是最大那一批的向量累積：
    /// `largestBatchChunks × dimension × 4 B × 2`（×2 是因為 `VectorSidecar.encode`
    /// 產生的 `Data` 與 `batchVectors` 同時存活）。
    ///
    /// **它不是整個 build 的峰值 RSS。** 量測顯示 RSS 隨 chunk 數線性成長，而
    /// 成長的來源尚未被隔離量測定位（`docs/measurements/2026-08-26-build-peak-memory.md`）。
    /// 這裡報的是那條線裡**唯一算得準**的一項——把它印出來，是為了讓「無上限」
    /// 從看不見變成看得見，不是為了假裝整體可預測。
    case batchPlan(batches: Int, largestBatchChunks: Int, estimatedVectorBytes: Int)

    /// 嵌入進行中的心跳。**每 N 個 chunk 或每 T 秒，先到者發。**
    ///
    /// 只有批次邊界的回報不夠：批次可以很大（#47），而使用者要判斷的是「它還活著
    /// 嗎」，那個判斷不能等到一批做完。
    case embedding(chunksDone: Int, chunksTotal: Int, elapsed: TimeInterval)

    /// 一批提交完成。
    case batchCommitted(
        batch: Int, totalBatches: Int, chunksDone: Int, chunksTotal: Int, elapsed: TimeInterval)
}

public struct IndexBuilder: Sendable {
    public let location: DerivedLocation
    public let scanner: CorpusScanner
    private let embedder: any EmbeddingProvider
    /// 進度回報。`nil` = 不回報（既有呼叫端的行為不變）。
    ///
    /// 用 callback 而不是讓 `IndexBuilder` 自己 print：這一層不該決定輸出去哪
    /// （stdout 的 `--json` 形態是給程式讀的），那是 CLI 的決定。
    private let progress: (@Sendable (BuildProgress) -> Void)?
    /// 一批**至少**累積幾個 chunk 才切（#44 分批）。**這不是上界。**
    ///
    /// 名字裡的 `target` 是字面意思。批次以整個來源為單位組裝，切點只在
    /// **加完一整個來源之後**判斷，所以實際上界是
    ///
    /// ```
    /// max(batchChunkTarget, 單一來源的最大 chunk 數)
    /// ```
    ///
    /// 而且**右項隨語料成長**：session 檔會隨 resume 單調變長，所以「最大來源的
    /// chunk 數」本身就是語料規模的遞增函數。
    ///
    /// 為什麼是結構後果而不是疏忽：`ScanState` 的續讀游標 `processedBytes` 是
    /// **per-file** 的，一個來源切一半就沒有地方記「這個檔處理到哪」。要真正以
    /// chunk 為單位分批，得先讓 state 能表達來源內的位置——見 #47。
    ///
    /// **這條註解先前寫的是相反的話**（「以 chunk 數為單位而不是來源數……避免
    /// 上界由最大的那個來源決定」），而實作做的正是它說要避免的事。跨模型盲驗
    /// 在使用者自己的語料上抓到反例：單一 session 檔 4,322 chunk > 2,000，該檔
    /// 整個進同一批。查法：
    ///
    /// ```
    /// wc -l < <最大的 .jsonl>          # 行數
    /// grep -c '"type":"text"' <同檔>    # 可索引 chunk 的下界
    /// ```
    ///
    /// **預設值 2,000 沒有量測支撐**（#46）。選它是為了「明顯安全」，不是為了
    /// 最佳。要調它得先有 `docs/measurements/` 的**批次大小 trade-off** 紀錄
    /// （fsync 次數 vs 中斷代價），而現有的 `2026-08-26-build-peak-memory.md`
    /// 量的是另一個變數。
    ///
    /// 可注入的第一個理由是測試：分批的行為只有在批次小於語料時才觀察得到，
    /// 而寫一個 2,000 chunk 的 fixture 只是為了驗分批，成本與收益不成比例。
    public let batchChunkTarget: Int
    /// 向量累積的預算（bytes）。`nil` = 不設限。
    ///
    /// **沒有預設值是刻意的**，見 `BuildError.memoryBudgetExceeded`。
    public let memoryBudgetBytes: Int?
    /// 嵌入期間每幾個 chunk 發一次心跳。與 `progressTimeInterval` 是 **or**：
    /// 先到者發。兩個都要的理由是它們各自漏掉一種情況——chunk 很慢時只有時間
    /// 觸發得了，chunk 很快時只有計數不會把 stderr 洗版。
    public let progressChunkInterval: Int
    /// 嵌入期間至少每幾秒發一次心跳。
    public let progressTimeInterval: TimeInterval

    public init(
        location: DerivedLocation, scanner: CorpusScanner, embedder: any EmbeddingProvider,
        progress: (@Sendable (BuildProgress) -> Void)? = nil,
        batchChunkTarget: Int = 2_000,
        memoryBudgetBytes: Int? = nil,
        progressChunkInterval: Int = 200,
        progressTimeInterval: TimeInterval = 5
    ) {
        self.location = location
        self.scanner = scanner
        self.embedder = embedder
        self.progress = progress
        self.memoryBudgetBytes = memoryBudgetBytes
        precondition(progressChunkInterval > 0, "心跳間隔必須為正")
        self.progressChunkInterval = progressChunkInterval
        self.progressTimeInterval = progressTimeInterval
        precondition(batchChunkTarget > 0, "批次大小必須為正——0 或負數會讓迴圈永遠不落地")
        self.batchChunkTarget = batchChunkTarget
    }

    public enum BuildError: Error, Sendable, Equatable {
        /// 另一個建置正在進行。**不等待**：建置可能跑很久，讓第二個行程無限期
        /// 卡住比明確失敗更糟——呼叫端無從得知它是在做事還是在等。
        case lockHeld(path: String)
        /// 鎖檔開不起來，而**不是**因為別人持有：權限、磁碟滿、`EMFILE`、
        /// 路徑不是檔案……。
        ///
        /// 與 `lockHeld` 分開的理由是補救動作完全不同：`lockHeld` 該等，
        /// 這個該去看 `code`／`detail` 說的那件事。第一版把兩者混成一個，
        /// 於是磁碟滿的使用者會去等一個不存在的建置。
        case lockUnavailable(path: String, code: Int32, detail: String)
        /// 側車檔比索引宣稱的短。
        ///
        /// 這**不能**靠 `ftruncate` 修：對較短的檔案指定較大的 offset 是
        /// **補零延長**（POSIX 語意），不是重建缺口。補出來的零向量與任何查詢
        /// 的點積都是 0——向量通道因此靜默失效，而筆數核對會通過。
        case sidecarShorterThanDeclared(declared: Int, found: Int)
        /// 需要整份重建，但呼叫端不允許（查詢路徑）。
        case fullRebuildRequired(detail: String)
        case stateUnreadable(detail: String)
        /// 估算的向量累積超過使用者設定的預算。
        ///
        /// **只在使用者顯式設了預算時才可能發生**——沒有預設值，因為本 repo 沒有
        /// 任何量測支撐得起一個門檻（`docs/measurements/2026-08-26-build-peak-memory.md`
        /// 的「不支持」一節逐字寫著這件事）。憑感覺挑一個預設，會把「OS 決定後果」
        /// 換成「一個我編的數字決定後果」，那不是改善。
        ///
        /// 誠實邊界：這個守衛擋的是**向量累積**，不是整個 build 的 RSS。後者的
        /// 成長來源尚未定位，所以擋不了。這一點必須寫在錯誤訊息裡，否則使用者
        /// 會以為設了預算就安全。
        case memoryBudgetExceeded(
            estimatedBytes: Int, budgetBytes: Int, largestBatchChunks: Int,
            largestSourceChunks: Int)
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
        // 續讀游標的真相來源是 DB 的 `scan_state` 表（見該表在 `createSchema()`
        // 裡的註解）。`state.json` 只剩兩個角色：**一次性遷移的來源**，以及
        // build 結束後寫出的**人類可讀鏡像**——它不再被拿來決定從哪裡續讀。
        var previousState = ScanState()
        if !rebuildFromScratch {
            previousState = try database.scanState()
            if previousState.files.isEmpty {
                // 表是空的。兩種可能，後果完全不同：
                //   (a) 舊版本建的索引，游標還在 state.json 裡 → 遷移。
                //   (b) 索引裡有內容但兩邊都沒有游標 → 不知道該從哪續讀。
                //       **不可**當成空 state 繼續：那會在既有索引上重掃全語料
                //       upsert，而使用者不會知道發生過什麼。
                let stateExists = FileManager.default.fileExists(atPath: location.stateURL.path)
                if stateExists {
                    do { previousState = try readState() } catch {
                        throw BuildError.stateUnreadable(detail: "\(location.stateURL.path)：\(error)")
                    }
                } else if try database.chunkCount() > 0 {
                    throw BuildError.stateUnreadable(
                        detail: "索引裡有內容，但續讀游標在 DB 與 "
                            + "\(location.stateURL.lastPathComponent) 都不存在；"
                            + "用 `ltm build --full` 從零重建")
                }
            }
        }
        let scan = try scanner.scan(previous: previousState)
        let refreshedSourceKeys = Set(scan.chunks.map(\.sourceKey))

        // 分母在這裡就知道了，而 embedding 一個都還沒算。#45 Expected ① 指名的
        // 就是這個時機：「這一步在嵌入開始之前就知道，成本近乎零」。
        //
        // 零 chunk 的增量也要報——「掃完了，沒有新東西」與「還在掃」是兩件事，
        // 而使用者從沉默裡分不出來。
        progress?(
            .scanCompleted(
                files: scan.state.files.count, chunks: scan.chunks.count,
                vectorsNeeded: scan.chunks.count))

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
        // 實測代價（`docs/measurements/2026-08-26-interrupted-full-build.md`）：
        // 一次全量 build 跑到 41 分鐘時，`index.sqlite3` 仍停在 4 KB、WAL 358 MB、
        // **外部讀取者看到的 `chunks` 是 0**——40 分鐘的工作對其他行程還不存在。
        //
        // 查法：build 期間另開終端機跑
        // `sqlite3 ~/.claude-ltm/index.sqlite3 'select count(*) from chunks'`。
        //
        // **推測 code 為何分岔**：`insert(chunks:)` 回傳 rowID，而配對
        // rowID↔vectorRow 最直觀是寫在同一個迴圈，而那迴圈已在交易內（insert
        // 需要）。embedding 是被「順路」拉進去的，不是設計決定。
        //
        // ## 每批的三段順序，以及為什麼不能改
        //
        // ① 交易外算向量 → ② 交易外側車 append+fsync → ③ 單一交易內
        // delete+insert+提交指標+更新 vector_count。
        //
        // row 編號在 ② 就決定（不必先 insert 拿 rowID），所以 delete、insert
        // 與指標更新才能併進同一個交易。
        //
        // **② 必須在 ③ 之前**（原註解已寫，是付過代價的）：`truncateSidecar` 對
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
        // 交易（見下方 ③），把窗口壓到「交易提交 → 寫 state」之間。
        let grouped = Dictionary(grouping: scan.chunks, by: \.sourceKey)

        // 只失效、沒有新 chunk 的來源（檔案被刪／改寫成空）先清掉。
        let deleteOnly = scan.invalidatedSources.subtracting(grouped.keys)
        if !deleteOnly.isEmpty {
            try database.transaction {
                for sourceKey in deleteOnly.sorted() {
                    try database.deleteChunks(sourceKey: sourceKey)
                    // 游標與內容同一個交易：來源消失了，它的續讀點也必須消失，
                    // 而且兩件事要嘛都發生要嘛都不發生。
                    try database.deleteScanState(sourceKey: sourceKey)
                }
            }
        }

        // **批次以整個來源為單位。** `batchChunkTarget` 是切點的下限、不是上界：
        // 這個迴圈把一整個來源 append 進去之後才判斷有沒有越線，所以實際上界是
        // `max(batchChunkTarget, 單一來源的最大 chunk 數)`，且右項隨語料成長。
        //
        // 不是疏忽：`ScanState.processedBytes` 是 per-file 的，來源切一半沒有地方
        // 記進度。要真正以 chunk 分批得先擴充 state——見 #47。在那之前，`batchChunkTarget`
        // 對「語料裡有個超大 session 檔」這個情況不提供任何保護。
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

        // 這裡是唯一一個「上界算得準」的時點：批次已經定案，維度已知。
        let largestBatchChunks = batches.map { batch in
            batch.reduce(0) { $0 + (grouped[$1]?.count ?? 0) }
        }.max() ?? 0
        // ×2：`appendVectors` 呼叫 `VectorSidecar.encode`，產生的 `Data` 與
        // `batchVectors` 同時存活。少算這個 2 會讓守衛在最需要的時候放行。
        let estimatedVectorBytes = largestBatchChunks * embedder.dimension * 4 * 2
        progress?(
            .batchPlan(
                batches: batches.count, largestBatchChunks: largestBatchChunks,
                estimatedVectorBytes: estimatedVectorBytes))

        if let budget = memoryBudgetBytes, estimatedVectorBytes > budget {
            let largestSourceChunks = grouped.values.map(\.count).max() ?? 0
            throw BuildError.memoryBudgetExceeded(
                estimatedBytes: estimatedVectorBytes, budgetBytes: budget,
                largestBatchChunks: largestBatchChunks,
                largestSourceChunks: largestSourceChunks)
        }

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
        let totalChunks = scan.chunks.count
        var doneChunks = 0
        let started = Date()
        var lastBeat = started
        var lastBeatChunks = 0

        for (batchIndex, batch) in batches.enumerated() {
            let batchChunks = batch.flatMap { grouped[$0] ?? [] }

            // ① 交易外：算向量。慢、不持鎖、可中斷。
            var vectors: [[Float]?] = []
            vectors.reserveCapacity(batchChunks.count)
            for chunk in batchChunks {
                // 心跳：每 N 個 chunk 或每 T 秒，先到者發。放在迴圈**內**是重點
                // ——批次邊界的回報在一批很大時幫不上忙，而那正是最壞情況。
                let sinceLastBeat = Date().timeIntervalSince(lastBeat)
                if doneChunks - lastBeatChunks >= progressChunkInterval
                    || sinceLastBeat >= progressTimeInterval
                {
                    lastBeat = Date()
                    lastBeatChunks = doneChunks
                    progress?(
                        .embedding(
                            chunksDone: doneChunks, chunksTotal: totalChunks,
                            elapsed: Date().timeIntervalSince(started)))
                }
                doneChunks += 1
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

                // ④ 本批來源的續讀游標——**在同一個交易內**。
                //
                // 這是這段程式碼最重要的一行位置。放到交易外（先前就是）會讓
                // 「已索引到哪」與「索引裡有什麼」落在兩個各自不保證落地的域，
                // 而 `synchronous=NORMAL` 下的 COMMIT 可以被硬重啟回滾。
                // 詳見 `createSchema()` 裡 `scan_state` 的註解。
                for sourceKey in batch {
                    guard let entry = scan.state.files[sourceKey] else { continue }
                    try database.upsertScanState(
                        sourceKey: sourceKey, prefixHash: entry.prefixHash,
                        processedBytes: entry.processedBytes)
                }
            }

            indexed += batchChunks.count
            lastBeat = Date()
            lastBeatChunks = doneChunks
            progress?(
                .batchCommitted(
                    batch: batchIndex + 1, totalBatches: batches.count,
                    chunksDone: doneChunks, chunksTotal: totalChunks,
                    elapsed: Date().timeIntervalSince(started)))
        }

        // 全部批次成功之後補上剩下的來源——沒有新 chunk 但 metadata 有變的那些。
        // 它們沒有內容要提交，所以不屬於任何批次，但游標仍要前進。
        try database.transaction {
            for (sourceKey, entry) in scan.state.files {
                try database.upsertScanState(
                    sourceKey: sourceKey, prefixHash: entry.prefixHash,
                    processedBytes: entry.processedBytes)
            }
        }

        // `state.json` 從此是**鏡像**，不是真相來源：build 成功後寫一次，供人閱讀
        // 與舊版本遷移。它落不落地都不影響正確性——續讀讀的是 DB。
        //
        // 寫失敗**不讓 build 失敗**：索引已經完整且一致，為了一個診斷用的副本
        // 把成功的 build 判成失敗，方向是錯的。
        try? writeState(scan.state)

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

            // `.atomic` 保證的是「讀者不會看到半份」，**不保證 bytes 已經到磁碟**。
            // 所以 rename 之後要 fsync 兩樣東西，而先前只做了第一樣：
            //
            //   1. 檔案本身 —— 內容落地。
            //   2. **父目錄** —— rename 這個「目錄項次的改變」本身落地。
            //
            // 少了第 2 步，硬重啟後可能出現「檔案內容在磁碟上，但那個名字不在」
            // ——側車檔整個消失，而 `vector_count` 宣稱它有 N 筆。
            // 註解先前逐字寫著「再 fsync 一次目錄項次」，而程式碼 fsync 的是檔案。
            // （由跨模型盲驗指出。）
            let handle = try FileHandle(forWritingTo: location.vectorsURL)
            try handle.synchronize()
            try handle.close()
            try Self.synchronizeDirectory(location.vectorsURL.deletingLastPathComponent())
        }
    }

    /// fsync 一個目錄，讓其中的建檔／改名落地。
    ///
    /// 這裡**不是** best-effort。整條四段順序（算向量 → 側車落地 → 提交指標）
    /// 的意義就在於「側車先真的到磁碟」；把它寫成 `try?` 等於在第一批上放棄
    /// 那條不變式，而第一批正是側車檔被建立的那一批。
    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSFilePathErrorKey: url.path,
                    NSLocalizedDescriptionKey:
                        "開不了 derived 目錄做 fsync：\(String(cString: strerror(errno)))",
                ])
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSFilePathErrorKey: url.path,
                    NSLocalizedDescriptionKey:
                        "fsync derived 目錄失敗：\(String(cString: strerror(errno)))",
                ])
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

/// 單寫者鎖。**所有權由 `flock(2)` 表示，不是由鎖檔存在表示。**
///
/// ## 為什麼不是 `O_CREAT | O_EXCL`
///
/// 第一版用建檔的原子性當所有權，`release()` 刪檔。那在**正常結束**時是對的，
/// 在**中斷**時是錯的——而中斷正是 `#44` 存在的理由：
///
/// `release()` 只在 Swift 正常 unwind 的 `defer` 裡執行。SIGKILL、未處理的
/// SIGINT/SIGHUP、kernel panic、OOM kill 都不會跑 `defer`，於是 `build.lock`
/// 永久留下，下一次 `open(O_EXCL)` 必然回 `EEXIST`。**已完成的批次明明在磁碟上，
/// 卻要使用者手動 `rm` 才能續跑**——分批提交省下的計算被鎖檔擋在門外。
///
/// 把 pid 寫進檔案只讓人**看得到**是誰留下的，沒有讓系統**恢復**。
///
/// `flock` 的鎖掛在**開啟的檔案描述子**上，行程死亡時由核心釋放，不需要任何
/// 清理程式碼跑得到。這是唯一在 SIGKILL 下仍然正確的形狀。
///
/// ## 為什麼 `release()` 不刪檔
///
/// 刪檔會開一個 race：A 持有 flock、B 開啟同一個路徑等待、A 刪檔並結束、
/// C 建立一個**新的** inode 並取得它的 flock——此時 B 與 C 各自持有不同 inode
/// 上的鎖，兩個都認為自己是唯一寫者。鎖檔留著不刪就沒有這個問題，代價只是
/// derived 目錄裡多一個 0–8 bytes 的檔案。
///
/// **不等待**：建置可能很久，讓第二個行程無限期等待會讓它看起來像當掉了。
public struct FileLock: Sendable {
    public let url: URL
    /// 持鎖的檔案描述子。關閉它就是釋放鎖——所以它必須活到 `release()`。
    private let descriptor: Int32

    public static func acquire(at url: URL) throws -> FileLock {
        // 不用 O_EXCL：檔案存在不代表有人持鎖（見型別註解）。
        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            // 開不起來的原因不只一種，而把它們全報成「另一個 build 正在進行」
            // 會讓使用者去等一個不存在的行程。權限、磁碟滿、EMFILE 各自要說。
            throw IndexBuilder.BuildError.lockUnavailable(
                path: url.path, code: errno, detail: String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            // EWOULDBLOCK（= EAGAIN）才是「別人正持有」。其餘是別的問題。
            if code == EWOULDBLOCK {
                throw IndexBuilder.BuildError.lockHeld(path: url.path)
            }
            throw IndexBuilder.BuildError.lockUnavailable(
                path: url.path, code: code, detail: String(cString: strerror(code)))
        }
        // pid 只作診斷用途，不再承載所有權。先截短：舊內容可能比新 pid 長。
        ftruncate(descriptor, 0)
        lseek(descriptor, 0, SEEK_SET)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
        return FileLock(url: url, descriptor: descriptor)
    }

    /// 釋放鎖。**必須且只能呼叫一次**（`build()` 用 `defer` 保證這件事）。
    ///
    /// 不刪鎖檔——理由見型別註解的 race。
    public func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
