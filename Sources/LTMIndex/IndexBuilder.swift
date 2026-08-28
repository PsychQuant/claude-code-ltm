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
    /// 全部完成——而一批的實際上界隨最大的那個來源檔成長（見 #47 與
    /// `batchChunkUpperBound(target:largestSource:)`），所以最壞情況下
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
    /// **加完一整個來源之後**判斷，所以實際上界比它大——**公式只有一份，在
    /// `batchChunkUpperBound(target:largestSource:)`**，並由
    /// `batchUpperBoundMatchesTheDeclaredFormula` 釘住。這裡刻意不複述它。
    ///
    /// 上界的**右項隨語料成長**：session 檔會隨 resume 單調變長，所以「最大來源的
    /// chunk 數」本身就是語料規模的遞增函數。
    ///
    /// 一批 chunk 數的**上界**——這個公式在整個 repo 只有這一份。
    ///
    /// ```
    /// target − 1 + largestSource
    /// ```
    ///
    /// 推導（`makeBatches` 的迴圈，逐行可查）：切點在 append **之後**判斷，所以
    /// 進入最後一次 append 前 `currentCount ≤ target − 1`；那次 append 最多加進
    /// `largestSource` 個。兩者相加就是上界，而且它**取得到**（見
    /// `batchUpperBoundMatchesTheDeclaredFormula`）。
    ///
    /// **先前這裡寫的是 `max(target, largestSource)`，那是錯的**，而且被複製到
    /// 六處——含 `openspec/specs/ltm-cli/spec.md` 的 SHALL 文字。實測：
    /// `target = 2_000`、`largestSource = 4_322` 時真值是 6,321，舊公式報 4,322，
    /// 低估 46%（#46 R2 verify，codex lens）。
    ///
    /// 那次錯誤的形狀值得記：它是**為了修一個錯的上界宣稱而新寫的上界宣稱**，
    /// 而修法（把正確公式寫進六處散文）重犯了 CLAUDE.md 記過的「一個數字被複述
    /// N 次就是 N 份會漂移的規格」。所以現在它是一個**可執行的函式加一條測試**，
    /// 散文一律只指名、不複述。
    public static func batchChunkUpperBound(target: Int, largestSource: Int) -> Int {
        // `target ≤ 0` 由 CLI 擋掉（`--batch-chunks` 要正整數），但這個函式是
        // public，所以自己也不能靠呼叫端。target = 1 時每個來源自成一批，上界
        // 就是 largestSource——公式在該點正好給出 0 + largestSource。
        max(target - 1, 0) + largestSource
    }

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
        /// derived 目錄底下的某個路徑**不是我們的檔案**：它不是一般檔案、不只一個
        /// 名字指向那個 inode（hard link），或它不屬於當前使用者。
        ///
        /// **先前叫 `lockUnsafe`**，而共用的檢查搬進來之後它也管 `vectors.bin` 與
        /// 資料庫——於是 CLI 對每一個 derived 檔案都說「這不是我們的**鎖檔**」
        /// （#45 R6 verify，codex + regression）。名字跟著職責走。
        ///
        /// 與 `lockUnavailable` 分開的理由同上——補救動作完全不同。這個不是
        /// 「等一下再試」也不是「去看 errno」，是**那個名字指的不是我們的鎖檔**，
        /// 而 `ftruncate` 會照著它把別的東西截短。唯一正確的處置是不要動它。
        ///
        /// **框架是 #40 的**（防這個程式自己的 bug 與使用者自己的路徑擺法），
        /// 不是對抗性的——見 `FileLock.acquire` 的註解。
        case derivedPathUnsafe(path: String, detail: String)
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
        // **#44 Expected ② 沒有被實作，而且它與 #44 實際交付的東西相衝突。**
        //
        // 那條要求寫的是「批次邊界上釋放寫鎖，讓查詢路徑的 `refreshIncrementally`
        // 有機會插進來」。實際上這把 `flock` 在 `build()` 的**第一個動作**取得、
        // 全程持有，所以查詢路徑插進來的窗口是 **0%**——分批讓交易變成 per-batch，
        // 但沒有第二個寫者走得到那裡去競爭它（#44 R13 verify，requirements lens）。
        //
        // **為什麼不現在補上**：`refreshIncrementally` 本身也走 `build()`，所以
        // 「讓它插進來」等於讓**兩個寫者**在同一個 derived root 上交錯。批次交易
        // 在 SQLite 層會序列化，但側車 append 與它們不在同一個交易裡——那正是
        // #44 花整個 change 修掉的耦合。**照字面實作 Expected ② 會把它打開。**
        //
        // 所以這是一個**未滿足的要求**，不是一個已完成的項目。追蹤於 #53。
        // CHANGELOG 先前用「並發寫入是具名拒絕（#44 ②）」回答了它——**那回答的是
        // issue 裡另一句話**（Out of scope 段的「撞上寫鎖會怎樣尚未實測」），
        // 兩句不同，而 Expected ② 因此變成沒有實作也沒有紀錄。
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
        // **`--full` 不需要「先清再開 DB」，`try?` 已經涵蓋了。**
        //
        // R6 的 regression lens 報「`cp -al` 備份過的 derived 目錄連 `--full` 都救
        // 不回來」，我照著加了一段「full 先 discard 再開 DB」。**變異證明它買的是
        // 零**：`currentStamps()` 用的是 `try?`，開檔失敗被吞成 `nil`，於是
        // `rebuildFromScratch` 仍為 true、discard 照跑、`--full` 本來就通
        // （回歸鎖：`aHardLinkedDatabaseIsRecoverableWithFull`，退掉那段程式碼
        // 它照樣綠）。
        //
        // 那條 finding 的**前提**因此要修正：`--full` 救不回來的不是資料庫，是
        // **鎖檔**——鎖必須在 discard 之前取得，而讓 `--full` 去 unlink 一個不安全
        // 的鎖檔會打開 `FileLock` 型別註解記載的 race。那一種的復原路徑是刪掉整個
        // derived 目錄（CLI 訊息逐字這樣說，回歸鎖在
        // `aHardLinkedDerivedTreeIsRecoverableWithFull`）。
        //
        // 加一段驅動不了的程式碼去修一個誤述的前提，是這個 cluster 五輪來的同一個
        // 形狀。這裡選擇不加。
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
        // 裡的註解）。`state.json` **既不被寫，也不被讀**。
        //
        // ## 為什麼沒有遷移路徑
        //
        // 上一版有一條：舊索引升上來時把 `state.json` 的游標搬進 `scan_state`。
        // 它被 R3 的 devil's advocate 用一個可執行的 probe 推翻，而推翻的方式
        // 值得完整記下來，因為它同時是「不要加判準」這條的最佳例子。
        //
        // 那條路徑的守衛是 `chunkCount() == 0`，理由寫成「一個沒有內容的索引配上
        // 一份游標，只可能是上一代索引的殘留或一次回滾」。**但 WAL 回滾不會把索引
        // 清空——它只丟掉最後那個沒落地的交易。** 所以 `chunkCount() == 0` 是真實
        // 回滾**最不可能**的結果；典型結果是內容還在、只少了尾巴，而那時守衛不 fire、
        // 遷移照單全收一份超前的游標。實測（v0.2.0 形狀的索引，刪掉最後一則 turn
        // 模擬回滾）：
        //
        //     PROBE-RESULT chunksIndexed=0 wasFullRebuild=false finalChunkCount=1
        //
        // ——那則 turn 永遠不會再被索引，build 不報錯、不重建。
        //
        // **根本問題不是判準挑錯，是那個事實不在磁碟上。** 游標說「這個檔我處理到
        // 第 N 個 byte」，但索引裡是否真的有那 N 個 byte 產出的每一則 turn，沒有
        // 任何地方記著。要驗證就得重新解析——而重新解析的成本等同 `--full`
        // （embedding 發生在去重之前）。
        //
        // 所以這裡採用掃描器對負游標的同一條原則：**拿不到可信的游標就不要猜**。
        // 差別只在處置——負游標可以丟棄後重掃單一來源，而這裡是整份索引，所以
        // 由使用者顯式跑 `--full`（那條路徑順帶會清掉殘留的 `state.json`）。
        //
        // 這一刪同時關掉五件事：遷移的原子性、遷移對負值的消毒、遷移失敗後的
        // 永久卡死、`try? removeItem` 銷毀事證，以及「`ltm query` 會替使用者執行
        // 一次不可逆的遷移」。**沒有那條路徑，就沒有那五個洞。**
        var previousState = ScanState()
        if !rebuildFromScratch {
            previousState = try database.scanState()
            // **判準是「這份游標涵蓋得住索引嗎」，不是「表是不是空的」。**
            //
            // 上一版用 `previousState.files.isEmpty` 當代理，而代理在同一輪的另一個
            // 修法下失效了：負游標改成「修成必然對不上的游標」之後 `files` 不再是空的
            // ——於是「表裡只有壞游標」這個先前會被擋下的狀態改為靜靜走增量，而
            // 已從語料刪除的來源永不作廢（違反不變式 2，#44 R4 verify）。
            //
            // 現在直接問資料庫：有 chunk 卻沒有游標的來源。空集合才放行。
            let orphaned = try database.sourcesWithoutCursor()
            if !orphaned.isEmpty {
                // **不可**當成空 state 繼續：那會在既有索引上重掃全語料 upsert，
                // 而使用者不會知道發生過什麼。
                throw BuildError.stateUnreadable(
                    detail: "索引裡有 \(orphaned.count) 個來源沒有續讀游標"
                        + "（舊版本建立的索引、或一次回滾之後）"
                        + "——例如 \(orphaned.prefix(3).joined(separator: "、"))。"
                        + "續讀點與索引內容是否一致無法從磁碟上驗證，所以這裡不猜："
                        + "請跑 `ltm build --full` 從零重建")
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
        // 這個迴圈把一整個來源 append 進去之後才判斷有沒有越線。上界的公式在
        // `batchChunkUpperBound(target:largestSource:)`——**這裡不複述**。
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

        // **公式與迴圈的對應由 `productionBatchingHonoursTheDeclaredBound` 扛，
        // 這裡不加守衛。**
        //
        // 上一版在這裡加了一道 `guard largestBatchChunks <= declaredBound`，並用
        // 一段註解論證它與 CLAUDE.md 的「驅動不了的守衛要拆掉」不同類。**那三個
        // 論點逐一被可執行證據推翻**（#46 R4 verify，devil's advocate）：
        //
        // 1. 它不是語料相依的性質。迴圈在 `currentCount >= target` 時歸零，所以
        //    append 前 `<= target − 1`、append 後 `<= (target − 1) + largestSource`
        //    = 宣告上界。**對所有輸入恆成立**——唯一能違反它的是有人改那個迴圈，
        //    而那是一次程式碼變更，正是測試的職責。
        // 2. 交叉變異證明測試自己扛得住：把切點改成 `>= target * 10` **並且同時
        //    刪掉守衛**，那條測試 `failed with 2 issues`。我當時只量了兩個單一
        //    變異，而決定「由誰扛」的是交叉——CLAUDE.md 對 #40 寫的正是
        //    「**逐一退掉**每個新增的機制」。
        // 3. 它宣稱的兩個賭注都是假的：記憶體預算用的是 `largestBatchChunks`
        //    （實際最大批次）而不是宣告上界，對分歧結構上免疫；而
        //    `openspec/specs/ltm-cli/spec.md` 自己指名的執行點就是那條測試。
        //
        // 而同一次改動在 40 行外對同一條規則做了**相反**決定（`CorpusScanner`
        // 那處刻意不加守衛），且那一處的賭注遠高於這裡——政策被以風險的反序套用。

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

        // **這裡刻意不寫 `state.json`。** 它曾經是「人類可讀鏡像」，而那讓它成為
        // 第三份真相來源——見本函式上方遷移分支的註解與那次實測。診斷改讀
        // `scan_state` 表。

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
        // **`.tmp` 與 `-journal` 也要清。** 先前沒清 `.tmp`，於是預先擺好的連結
        // 會活過 `--full`——而 `--full` 之後 `vectors.bin` 不存在，`appendVectors`
        // 必走那條分支，所以 `--full` 反而是最可靠的觸發路徑（#45 R6 verify）。
        for url in [
            location.databaseURL, location.vectorsURL, location.stateURL,
            location.vectorsURL.appendingPathExtension("tmp"),
            URL(fileURLWithPath: location.databaseURL.path + "-journal"),
        ] {
            // **`lstat` 而不是 `fileExists`。** 後者**跟隨 symlink**，所以一個目的地
            // 不存在的 dangling symlink 會回 `false`——目錄項還在，卻被跳過。
            // 後果：`IndexDatabase` 的檢查看見那個 symlink 並拒絕開啟，而 `--full`
            // 清不掉它，**純衍生物變成清不掉的垃圾**（違反不變式 2 的 `--full`
            // 契約，#44 R7 verify，codex）。
            //
            // 反諷的對照：緊接在下面的 `-wal` / `-shm` 迴圈**沒有**這個前置判斷，
            // 直接 `try? removeItem`，所以它反而不受影響——同一個函式裡兩種寫法，
            // 被保護到的是那個次要的分支。
            var probe = stat()
            guard lstat(url.path, &probe) == 0 else {
                // `ENOENT` = 真的不存在，跳過。其餘（權限等）要說出來，
                // 因為 `--full` 的契約是「從零開始」。
                if errno == ENOENT { continue }
                throw CocoaError(
                    .fileWriteUnknown,
                    userInfo: [
                        NSFilePathErrorKey: url.path,
                        NSLocalizedDescriptionKey:
                            "無法判斷它是否存在：\(String(cString: strerror(errno)))",
                    ])
            }
            // WRITE-SITE: discard-primary
            try fm.removeItem(at: url)
        }
        // SQLite 的 WAL 與 shared-memory 檔要一起清，否則新開的資料庫會接上
        // 舊索引的未完成交易。
        for suffix in ["-wal", "-shm"] {
            // WRITE-SITE: discard-sqlite-siblings
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
        // WRITE-SITE: sidecar-truncate
        let handle = try openDerivedFileNoFollow(location.vectorsURL, flags: O_RDWR)
        defer { try? handle.close() }
        let current = try handle.seekToEnd()
        guard current >= target else {
            throw BuildError.sidecarShorterThanDeclared(
                declared: rows, found: rowBytes == 0 ? 0 : Int(current) / rowBytes)
        }
        // WRITE-SITE: sidecar-truncate-apply
        try handle.truncate(atOffset: target)
    }

    private func appendVectors(_ vectors: [[Float]]) throws {
        guard !vectors.isEmpty else { return }
        let data = VectorSidecar.encode(vectors)
        if FileManager.default.fileExists(atPath: location.vectorsURL.path) {
            // WRITE-SITE: sidecar-append
            let handle = try openDerivedFileNoFollow(location.vectorsURL, flags: O_WRONLY)
            defer { try? handle.close() }
            try handle.seekToEnd()
            // WRITE-SITE: sidecar-append-write
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } else {
            // 全新的側車檔走 temp + rename：rename 在同一個檔案系統上是原子的，
            // 所以讀者要嘛看到完整的檔案、要嘛看不到檔案，不會看到半份。
            // **這裡刻意用 `.atomic`，不走 `openDerivedFileNoFollow`。**
            //
            // 上一版把它改成自己開檔，理由寫的是「`Data.write` 會跟隨 symlink」
            // ——**那句話是假的**，而那個「修法」造出一條原本不存在的毀資料路徑
            // （#45 R6 verify，六個 lens 全部獨立命中，devil's advocate 判為純退步）。
            //
            // 兩件事，各自量過：
            //
            // 1. `.atomic` 對 symlink 與 hard link **都不寫穿**（它自己寫進同目錄的
            //    暫存檔再 rename，從不對目標路徑開檔）：
            //
            //        symlink : victim 320 → 320 bytes
            //        hardlink: victim 320 → 320 bytes
            //
            // 2. 換成 `O_WRONLY | O_CREAT | O_TRUNC` 之後，**截斷發生在 `open(2)`
            //    裡面**，所以 `ExclusiveFile.verify` 跑到時受害者已經是 0 bytes。
            //    端到端實測（一般的 `ltm build`，不需要 `--full`）：
            //
            //        before: 242 bytes
            //        ✗ …已中止（**沒有寫入任何東西**）：有 2 個名字指向同一個檔案
            //        after : 0 bytes
            //
            //    ——守衛具名丟了錯，而語料檔已經歸零，訊息還逐字宣稱相反的事。
            //
            // 這正是同一次改動在 280 行之外為 `FileLock` 寫下的那條紀律：
            // **順序不可調換，放在截斷之後就只是事後通知**。我在那裡寫下它，
            // 又在這裡違反它。
            //
            // 判準因此不是「所有入口都要走同一個 helper」，是**破壞性動作不得
            // 先於檢查**。`.atomic` 滿足它的方式更強：它根本不對目標路徑做
            // 破壞性動作。
            let temporary = location.vectorsURL.appendingPathExtension("tmp")
            // WRITE-SITE: sidecar-temp-write
            try data.write(to: temporary, options: [.atomic])
            // WRITE-SITE: sidecar-replace
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
            // WRITE-SITE: sidecar-fsync
            let handle = try openDerivedFileNoFollow(location.vectorsURL, flags: O_WRONLY)
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

}



/// # 會改變檔案系統的站點：一份**被檢查守著的清單**，不是一份完整性證明
///
/// **標題先前寫「每一個」，那是一句完整性宣稱，而守著它的檢查明知會漏**
/// （`setAttributes` / `chmod` / `openat` / `writev` 都不在 primitive 清單裡）。
/// 本 repo 的硬規則是「宣稱完整的列舉必須附上證明它完整的檢查」——附不出來，
/// 就不能宣稱。所以標題改成它實際是的東西：**一份被檢查守著的清單**。
///
/// 那條檢查（`WriteSiteTableSyncTests`）買到的是「清單內的手段一定要進表」，
/// 而它的限制逐條寫在那個檔案裡。**它已經被驗證推翻四次，每次都是我把界線
/// 寫小了一級**——所以現在標題不再替它宣稱它做不到的事。
///
/// R6 起有一條 finding 掛著：security lens 數出「約 14 個站點，只有 5 個走共用
/// 開檔器」。實際數過之後那個數字是高估的，但「只有 5 個走共用開檔器」是對的，
/// 而正確的答案不是「把全部改成走它」，是**逐站點說清楚它為什麼安全或不安全**。
///
/// | `WRITE-SITE` 標記 | 動作 | 判定 |
/// |---|---|---|
/// | `derived-root-mkdir` | `createDirectory` | 建目錄，不寫穿任何既有檔案 |
/// | `discard-primary` | `lstat` + `removeItem` | **unlink 一個名字**，不動連結的目標 |
/// | `discard-sqlite-siblings` | `try? removeItem` | 同上 |
/// | `sidecar-truncate` | `openDerivedFileNoFollow(O_RDWR)` + `truncate` | ✅ 檢查在截短之前 |
/// | `sidecar-append` | `openDerivedFileNoFollow(O_WRONLY)` | ✅ |
/// | `sidecar-fsync` | `openDerivedFileNoFollow(O_WRONLY)` | ✅ |
/// | `sidecar-temp-write` | `Data.write(.atomic)` | **不對目標路徑開檔**——比走共用檢查更強 |
/// | `sidecar-replace` | rename | 三種情形全部量過，見下 |
/// | `derived-open-helper` | `open(O_NOFOLLOW\|O_NONBLOCK)` + `ExclusiveFile.verify` | ✅ 共用入口本身 |
/// | `lock-open` | 同上 | ✅ |
/// | `lock-truncate` | `ftruncate` | ✅ 檢查在它之前 |
/// | `sqlite-open` | `lstat` × 4 後綴 + `sqlite3_open_v2` | 主檔與 `-wal`/`-shm`/`-journal` |
/// | `memory-prune-open` | `open(O_NOFOLLOW)` + `ExclusiveFile.verify` | ✅ |
/// | `memory-prune-truncate` | `ftruncate` | ✅ 檢查在它之前 |
/// | `memory-append-open` | `open(O_NOFOLLOW)` + `ExclusiveFile.verify` | ✅ |
/// | `memory-backup-cleanup-a` | `try? removeItem` | 只動我們自己剛建的備份檔 |
/// | `memory-backup-cleanup-b` | 同上 | 同上 |
/// | `sidecar-truncate-apply` | `FileHandle.truncate` | ✅ 在 `sidecar-truncate` 的檢查之後 |
/// | `sidecar-append-write` | `FileHandle.write` | ✅ 在 `sidecar-append` 的檢查之後 |
/// | `lock-write-pid` | `write(2)` | ✅ 在 `lock-open` 的檢查與 `lock-truncate` 之後 |
/// | `memory-backup-create` | `open(O_CREAT\|O_EXCL\|O_NOFOLLOW)` | 最後一段擋住；**父目錄不擋**（TOCTOU 類，#40 既決限度）|
/// | `memory-backup-write` | `write(2)` | ✅ 在上一列建立的 fd 上 |
/// | `memory-prune-write` | `write(2)` | ✅ 在 `memory-prune-open` 的檢查之後 |
/// | `memory-append-write` | `write(2)` | ✅ 在 `memory-append-open` 的檢查之後 |
/// | `memory-append-seal` | `write(2)` | 同上（殘行封口）|
/// | `cli-memory-root-mkdir-a` | `lstat` + `createDirectory` | 最後一段是 symlink 就拒絕；`validatedRoot:` 只是標籤，不是型別保證 |
/// | `cli-memory-root-mkdir-b` | 同上 | 同上 |
///
/// **記憶層在表裡。** 上一版寫「記憶層不在這張表裡：它有自己的守衛與自己的威脅
/// 模型（#40）」——**那句話沒有量過，而且是假的**：`ltm memory --prune --force`
/// 把一個 hard link 成 `events.jsonl` 的語料檔截成 0 並印「✓」，而它寫的備份把
/// 語料逐字內容複製進 `~/.claude-ltm/memory/`（#44 R9 verify，兩個 lens 各自
/// 實測）。理由見 `LTMCore.ExclusiveFile`。
///
/// **一個沒量過的「安全」判定比一個具名的未知更糟**——上一版同時做了這兩件事。
///
/// ## 這張表由什麼守著
///
/// `WriteSiteTableSyncTests`。**機制與它的誠實邊界只寫在那個檔案裡，這裡不複述。**
///
/// 先前這一段自己描述了一次機制，而那段描述在機制被換掉之後留在原地：它說檢查
/// 「比對數量而非身分」（那句話正是上一輪被判為 CRITICAL 的錯誤自我設限），
/// 並援引「建立它的當下就抓到這張表少了兩處」當證據（那個量測重跑不重現，是我
/// 調常數調到綠之後編的）。**我在 CHANGELOG 收回了它們，卻把原文留在原始碼裡
/// ——收回只做了一半**（#44 R11 verify，requirements lens）。
///
/// 這是 CLAUDE.md 記過的「把一份規格收斂到單一位置，不等於它從此不會漂移」的
/// 第三個實例，而這一次漂移的距離是**同一則 doc comment 裡的 35 行**。
///
/// ## `replaceItemAt` 那一格：量完了（先前是具名未知）
///
/// 三種情形，全部隔離量過（探針跑在 repo 之外的 temp 目錄）：
///
/// | dest | `replaceItemAt` | 受害者 | 之後 dest 是 |
/// |---|---|---|---|
/// | hard link → 別的檔案 | **成功** | 320 → 320 | 一般檔案 |
/// | symlink → 存在的檔案 | 丟錯 | 320 → 320 | 仍是 symlink |
/// | **dangling** symlink | 丟錯 | 目標**沒有被建出來** | 仍是 symlink |
///
/// **三種都不寫穿**，但只有第一種是「因為它做對了事」：rename 換掉的是**目錄項**，
/// 不對 inode 寫入——所以受害者完好，而 `vectors.bin` 從此是我們自己的一般檔案。
/// 另外兩種是丟錯，安全但**訊息與事實不符**（它說「檔案不存在」，而檔案存在、
/// 只是一個連結）。
///
/// **dangling 那一格是可達的，而且是唯一可達的**（codex R9 指出）：分支條件是
/// `FileManager.fileExists`，它**跟隨 symlink**，所以 dangling 時回 `false` →
/// 必然走 else 分支 → 必然到達 `replaceItemAt`。非 dangling 的兩種會先被
/// `truncateSidecar` 的檢查擋下。
///
/// **殘留的粗糙面**：dangling 之後 `vectors.bin` 仍是那個 symlink，而增量路徑
/// 每次都會在同一個地方丟同一個誤導的錯——復原只剩 `ltm build --full`
/// （它用 `lstat`，清得掉）。回歸鎖：`aDanglingSidecarSymlinkDoesNotWriteIntoTheCorpus`。
///
/// 開一個 derived 目錄底下的檔案，**且拒絕跟隨符號連結**。
///
/// ## 為什麼需要它，以及它的威脅模型
///
/// `FileHandle(forUpdating:)` / `forWritingTo:` 一律跟隨 symlink。所以
/// `ln -s <語料>.jsonl vectors.bin` 之後，`truncateSidecar` 會把那個語料檔截成
/// 零長度——**違反不變式 1**。實測（#45 R4 verify，security lens）：40 bytes → 0。
///
/// 比 `build.lock` 那條更糟的是**可達性**：`build()` 無條件呼叫 `truncateSidecar`，
/// 而 `LTMService.refreshIncrementally()` 在**每一次查詢之前**呼叫 `build()`。
/// 所以破壞性的呼叫在 `ltm query` 與長駐 `ltm mcp` 的路徑上，不需要跑 `ltm build`。
/// （一個反直覺的不對稱：`--full` 反而是安全的——`removeItem` 只 unlink 那個名字。）
///
/// **威脅模型是 #40 已決的那一份**（見 `LTMMemory/EventStore.swift`）：這道守衛
/// 防的是**這個程式自己的 bug 與使用者自己的路徑擺法**——例如用 symlink 把數 GB
/// 的側車搬到別的磁碟，之後又把它重指到別處。它**不是**對抗邊界，所以
/// hardlink 與 TOCTOU 同樣是**被接受的限度**，理由與 #40 逐字相同。
///
/// ## 為什麼是一個 helper 而不是三處各自加旗標
///
/// R3 指出加固是「點狀的」，R4 量出另外兩處確實還開著。逐處加旗標會讓**下一個
/// 新增的 derived 檔案成為第四個漏網的**——「點狀」這個詞指的就是這件事。
/// 所以入口收斂成這一個。
///
/// - Parameter mode: 只在 `flags` 含 `O_CREAT` 時有意義。**它不是選用的**：
///   `open(2)` 的 `O_CREAT` 需要第三個引數，少給的話 mode 取自堆疊上的垃圾——
///   先前漏了它，於是 `.tmp` 被建成 0 權限，下一次開它 `EACCES`。
func openDerivedFileNoFollow(_ url: URL, flags: Int32, mode: mode_t = 0o644) throws -> FileHandle {
    // **`O_NONBLOCK` 不是選用的。** `open(O_WRONLY)` 對一個 FIFO 會**永久阻塞**
    // 直到有讀者出現——阻塞在 `open(2)` 裡面，所以 `ExclusiveFile.verify` 的
    // `S_IFREG` 檢查永遠跑不到。實測：把 `vectors.bin.tmp` 換成 FIFO，`build()`
    // 無限期掛住而且抱著 build.lock，stderr 零輸出（#45 R6 verify，三個 lens）。
    //
    // 那條檢查的註解原本就寫著它擋的是「對 FIFO 的 open 會永久阻塞」——**而它
    // 在結構上到不了**。這是同一個形狀的又一次：一句寫在守衛旁邊、守衛自己
    // 不滿足的說明。
    //
    // 加上 `O_NONBLOCK` 之後 FIFO 的 open 立刻回 `ENXIO`（無讀者）或成功，兩者
    // 都讓控制流回到我們手上；一般檔案不受這個旗標影響。
    // WRITE-SITE: derived-open-helper
    let descriptor = (flags & O_CREAT) != 0
        ? open(url.path, flags | O_NOFOLLOW | O_NONBLOCK, mode)
        : open(url.path, flags | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
        let code = errno
        // `ELOOP` 就是「它是一個 symlink」。其餘照原樣往上報。
        throw CocoaError(
            code == ELOOP ? .fileWriteUnknown : .fileReadUnknown,
            userInfo: [
                NSFilePathErrorKey: url.path,
                NSLocalizedDescriptionKey: code == ELOOP
                    ? "\(url.lastPathComponent) 是一個符號連結。derived 目錄底下的檔案"
                        + "會被就地截短與覆寫，所以這裡不跟著它走——那會寫到連結指向的"
                        + "地方去。請把它換成真正的檔案，或改設 LTM_DERIVED_ROOT。"
                    : String(cString: strerror(code)),
            ])
    }
    // **symlink 只是兩半當中的一半。** hard link 不是符號連結，`O_NOFOLLOW` 對它
    // 完全不作用——見 `ExclusiveFile.verify` 的註解與那次實測。
    do { try ExclusiveFile.verify(descriptor: descriptor, path: url.path) } catch {
        close(descriptor)
        throw IndexBuilder.BuildError.derivedPathUnsafe(
            path: url.path, detail: (error as? ExclusiveFile.Rejection)?.reason ?? "\(error)")
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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
/// ## 為什麼是 `final class` 而不是 `struct`
///
/// 它獨佔一個**檔案描述子**，而 fd 是行程層的資源、不能被值語意複製。先前它是
/// 可複製的 `public struct`：複製一份、兩份各自 `release()`，第二次 `close()` 的
/// 是同一個號碼——而那個號碼此時可能已經被行程重新配給**別的檔案**。症狀是別處
/// 的讀寫安靜地作用在錯的檔上。（#45 R2 verify，codex / security / regression
/// 三個 lens 各自命中。）
///
/// class 讓「這個鎖只有一份」變成型別層的事實。
///
/// ## `@unchecked Sendable` 由什麼支撐
///
/// 上一版是 `private var descriptor: Int32` 加一句 `guard descriptor >= 0`，
/// **而那個冪等性只在單執行緒成立**：兩個 task 可以都通過 guard，第一個
/// `close()` 之後號碼被重新配給別的檔案，第二個關掉無關的 fd——正是型別註解
/// 聲稱已經消除的後果（#45 R3 verify，codex / logic / security 三個 lens）。
/// 那條「回歸鎖」測試只做同一執行緒的循序呼叫，驅動不了 race。
///
/// 現在 `descriptor` 是 `Mutex`-保護的，`release()` 用**取出並清空**的形式：
/// 拿到非 −1 值的那一個 task 是唯一會 `close()` 的。這是一個原子交換，不是
/// check-then-act，所以 `@unchecked` 有東西支撐而不只是一句宣稱。
public final class FileLock: @unchecked Sendable {
    public let url: URL
    /// 持鎖的檔案描述子。關閉它就是釋放鎖——所以它必須活到 `release()`。
    ///
    /// 用鎖保護而不是裸 `var`：見型別註解。
    ///
    /// `NSLock` 而不是 `Mutex`：後者要 macOS 15，而本套件的部署目標是 14.0
    /// （`Package.swift`）。為了一個三行的臨界區把整個套件的最低版本推上去，
    /// 代價與收穫不成比例。
    private let mutex = NSLock()
    private var descriptorStorage: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptorStorage = descriptor
    }

    public static func acquire(at url: URL) throws -> FileLock {
        // 不用 O_EXCL：檔案存在不代表有人持鎖（見型別註解）。
        //
        // **但一定要 O_NOFOLLOW。** 舊的 `O_CREAT | O_EXCL` 對 symlink 攻擊是
        // **結構上免疫**的：POSIX 要求 `open` 帶 `O_CREAT|O_EXCL` 在路徑是符號連結
        // 時一律 `EEXIST`，不論指向哪。為了 flock 重設計拿掉 `O_EXCL` 時，那個
        // 性質被一起換掉了，而沒有任何註解提到它。
        //
        // 實測（#45 R2 verify，security lens）：
        //     ln -s /tmp/victim $LTM_DERIVED_ROOT/build.lock
        //     ltm build --quiet          # exit 0
        //     /tmp/victim: 45 bytes → 6 bytes（內容是 pid）
        // `LTM_DERIVED_ROOT` 可由環境變數指定，所以共用或可預測的 derived 目錄
        // 就是一條任意檔案截斷的路徑。**而語料根也可以被指到同一棵樹下**——
        // 那會讓它變成一條寫進唯讀語料的路徑（不變式 1）。
        //
        // **威脅模型：#40 已決的那一個，不是對抗邊界。**
        //
        // 上一版的註解與 CLI 訊息採用了對抗性框架（「有人在那個路徑上放了一個
        // 指向別的檔案的名字」、叫使用者去跑 `find ~ -inum`）。而
        // `LTMMemory/EventStore.swift` 對**同一個攻擊類別**早就寫下一份蓋了
        // 「已決」章的規格：守衛的職責是執行不變式 1，而它防的是**這個程式自己的
        // bug**——一條算錯的路徑、一個沒想到的 symlink 擺法；hardlink 與 TOCTOU
        // 是**被接受的限度**，因為一個已經能寫進使用者家目錄的攻擊者有直接得多的
        // 手段。同一個 process 裡有兩份相反的規格，讀者依先讀到哪個檔案得到相反
        // 答案（#45 R4 verify，security lens）。**這裡改採 #40 的那一份。**
        //
        // 所以下面的檢查要這樣讀：它問的不是「有沒有人在攻擊我」，是
        // **「這個名字指的是不是我們自己的鎖檔」**。答案是否的話就不要動它。
        //
        // **一個旗標關不掉整條——這句話上一版就是這樣寫的，而它是錯的。**
        // `O_NOFOLLOW` 只拒絕「路徑最後一段是符號連結」。**hard link 不是符號連結**：
        // 它是一個指向受害者 inode 的普通目錄項，`open` 會成功。所以
        //
        //     ln ~/.claude/projects/<project>/<session>.jsonl $LTM_DERIVED_ROOT/build.lock
        //     ltm build
        //
        // 仍然把真正的語料檔截成零長度——**違反不變式 1，且不可回復**
        // （#44 R3 verify，codex + security 兩個 lens）。macOS/APFS 沒有 Linux
        // `fs.protected_hardlinks` 的等價物。
        //
        // 舊的 `O_CREAT|O_EXCL` 對兩者**都**免疫（任何既存名稱一律 `EEXIST`，
        // 不管它是不是 link），所以這是 flock 重設計時丟掉、而上一版只補回一半
        // 的性質。判準因此要從「擋掉 symlink」推廣成**「這個 fd 指向的東西，是不是
        // 只有我這個名字指得到、而且是我的」**——那要 `fstat`，不是旗標。
        // WRITE-SITE: lock-open
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o644)
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
        // **截短之前先確認這個 inode 只有一個名字，而且是我們的。**
        // 順序不可調換：放在 `ftruncate` 之後就只是事後通知。
        //
        // 檢查與它的誠實邊界都在 `LTMCore.ExclusiveFile`——**索引層與記憶層共用
        // 同一份，不要在任何一層再寫一次**。
        //
        // 上一輪 CHANGELOG 寫「檢查收斂成 `LTMCore.ExclusiveFile`，索引層與記憶層
        // 共用一份」，而**索引層的呼叫端是零**：`verifyExclusivelyOurs` 原樣留著，
        // 三個守衛同樣順序同樣註解。於是 CHANGELOG 有兩則條目各自宣稱收斂到
        // **不同的**單一檢查（#44 R10 verify，requirements lens）。
        //
        // CLAUDE.md 對這個形狀寫得很明白：「同一件事有兩個寫者，就是兩份會漂移的
        // 規格……**修法是刪掉一份，不是把正確順序照抄過去**」——而我上一輪做的
        // 正是抄一份過去然後宣稱刪掉了。這次是真的刪掉。
        //
        // （上一版在這裡寫過「所以中間沒有 TOCTOU 窗口」，並在七行之下自己說那句
        // 是假的，而 CHANGELOG 宣稱它已被收回。**它當時還在原地當作斷言。**
        // #44 R5 verify，codex + requirements。這次是真的刪掉它，不是在它下面補
        // 一段說明。）
        do { try ExclusiveFile.verify(descriptor: descriptor, path: url.path) } catch {
            close(descriptor)
            throw IndexBuilder.BuildError.derivedPathUnsafe(
                path: url.path, detail: (error as? ExclusiveFile.Rejection)?.reason ?? "\(error)")
        }

        // pid 只作診斷用途，不再承載所有權。先截短：舊內容可能比新 pid 長。
        //
        // 這三個回傳值刻意忽略：pid 是診斷資訊，寫不進去不影響鎖的正確性（鎖由
        // `flock` 持有，不由檔案內容持有）。**但截短失敗會讓舊 pid 的殘尾留在後面**，
        // 所以下面讀鎖檔的人要有心理準備——那也是為什麼它只是診斷。
        // WRITE-SITE: lock-truncate
        _ = ftruncate(descriptor, 0)
        _ = lseek(descriptor, 0, SEEK_SET)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        // WRITE-SITE: lock-write-pid
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
        return FileLock(url: url, descriptor: descriptor)
    }

    /// 釋放鎖。`build()` 用 `defer` 呼叫一次。
    ///
    /// **重複呼叫是 no-op。** 先前它不是：第二次 `close()` 關的是同一個號碼，
    /// 而那個號碼可能已經被重新配給別的檔案（見型別註解）。
    ///
    /// 不刪鎖檔——理由見型別註解的 race。
    public func release() {
        // **取出並清空是一個動作。** 拿到非 −1 的那一個 task 是唯一會 close 的；
        // 其餘拿到 −1，直接返回。先前是 guard → close → 設 −1 三步，兩個 task
        // 可以都通過第一步。
        mutex.lock()
        let fd = descriptorStorage
        descriptorStorage = -1
        mutex.unlock()
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    /// 行程結束前沒有人呼叫 `release()` 時的兜底。
    ///
    /// **這不是主要路徑**：`flock` 在行程死亡時由核心釋放，所以漏掉 `release()`
    /// 的後果是 fd 洩漏、不是鎖卡住。留著它是為了長駐行程（`ltm mcp`）——那裡
    /// 一個洩漏的 fd 會一直累積。
    ///
    /// **它改變了語意，這一點要說清楚**：被丟棄的鎖從「洩漏但仍持有」變成
    /// 「靜默解鎖」。對本 repo 是對的方向（`build()` 的 `defer` 一定會呼叫
    /// `release()`，所以走到 `deinit` 就代表那個鎖已經沒有主人），但它不是
    /// 一個純粹的兜底。#45 R3 verify，devil's advocate。
    deinit { release() }
}
