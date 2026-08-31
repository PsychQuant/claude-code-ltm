import CryptoKit
import Foundation
import LTMCore

/// 一則被索引的 turn。
///
/// 這個型別是**掃描層的一筆觀測**：某個來源檔的某一行，在那個檔裡帶著那個
/// `sessionID`。它是逐來源的事實，不是「這則 turn 的 session」——同一則 turn 經
/// resume 複製後會以不同 `sessionID` 出現在多個檔，每一份都是一筆各自為真的觀測。
///
/// 落地時這些觀測進 `chunk_sources`（每個持有者一列）；`chunks` 只留
/// `(project, uuid, timestamp)` 三個純量。不變式 3 的指標因此是
/// `(project, sessions, uuid, timestamp)`，其中 `sessions` 是集合——**沒有代表值**
/// （#25，index layout 5；先前這裡寫「指標四元組…是 chunk 的欄位」，那是 session
/// 還被壓成單值時的敘述）。
///
/// `project` 刻意**不進** anchor：語料的 project 目錄名是路徑轉寫（可能很長、
/// 可能含任意字元），而 `Anchor.source` 受 `OpaqueIdentifier` 約束（ASCII、≤64）。
/// 把它塞進去會讓長路徑的專案整個索引不了。anchor 改用 project 的**指紋**——
/// 一個由目錄名算出的 32 字元雜湊，同時解掉長度與隱私兩個問題。
///
/// （這則註解先前寫著「anchor 用 sessionID + uuid 定址就夠——那兩個是 UUID，
/// 且在語料內唯一」。**後半句是錯的**：session resume 會讓同一則 turn 帶著不同的
/// sessionID 出現在多個檔案裡，於是「唯一」的是 uuid，不是這個組合。錯的理由
/// 撐著一個錯的決定，而註解改起來不會編譯失敗——所以它比程式碼活得更久。）
public struct CorpusChunk: Sendable, Equatable {
    /// 這個 chunk 來自哪個來源檔（state 的鍵）。
    ///
    /// 索引層需要它才能在來源被改寫時精準作廢那一份的 chunk。先前這個值是由
    /// `project` 與 `sessionID` **猜**出檔名的——那假設每個 session 檔都叫
    /// `<sessionId>.jsonl`，語料裡並不保證如此，猜錯的後果是作廢打不中，
    /// 舊文字繼續留在索引裡而且不報錯。
    public let sourceKey: String
    public let project: String
    /// `project` 的穩定指紋。**這是 anchor 的 source，也是 chunk 身分的一半。**
    ///
    /// `project` 本身留著是為了導航（人要看得懂命中來自哪個專案），但它不參與
    /// 定址——理由見 `ProjectFingerprint` 的文件。
    public let projectFingerprint: String
    public let sessionID: String
    public let uuid: String
    public let timestamp: Date
    public let role: String
    public let text: String
    public let anchor: Anchor

    public init(
        sourceKey: String, project: String, sessionID: String, uuid: String, timestamp: Date,
        role: String, text: String, anchor: Anchor
    ) {
        self.sourceKey = sourceKey
        self.project = project
        self.projectFingerprint = ProjectFingerprint.of(project)
        self.sessionID = sessionID
        self.uuid = uuid
        self.timestamp = timestamp
        self.role = role
        self.text = text
        self.anchor = anchor
    }
}

/// 單一來源檔的續讀狀態。
public struct SourceFileState: Codable, Sendable, Equatable {
    /// 已處理那一段（前 `processedBytes` 個 byte）的 SHA-256，十六進位小寫。
    public let prefixHash: String
    public let processedBytes: Int

    public init(prefixHash: String, processedBytes: Int) {
        self.prefixHash = prefixHash
        self.processedBytes = processedBytes
    }
}

/// 整份語料的續讀狀態。鍵是相對於語料根的路徑。
public struct ScanState: Codable, Sendable, Equatable {
    public var files: [String: SourceFileState]
    public init(files: [String: SourceFileState] = [:]) { self.files = files }
}

/// 一個 chunk 連同它在來源檔中的**切點游標**（#47）。
///
/// `(endOffset, prefixHashAtEnd)` 與 `SourceFileState(prefixHash, processedBytes)`
/// 是同一格式——批次層把任何一個 chunk 的切點原樣寫進 `scan_state`，下一輪掃描
/// 的續讀比對就會接受它並從那裡續讀。**來源因此可以在任意 chunk 邊界切開提交**，
/// 而游標永遠可對檔案驗證（重算 `0..<endOffset` 的 SHA-256 必須等於
/// `prefixHashAtEnd`）。
public struct ScannedChunk: Sendable, Equatable {
    public let chunk: CorpusChunk
    /// 該 chunk 那一行在來源檔中的結束位移（含行尾換行，絕對值）。
    public let endOffset: Int
    /// 來源檔 `0..<endOffset` 的 SHA-256（hex 小寫）——與 `prefixHash` 同格式。
    public let prefixHashAtEnd: String
}

/// 一次掃描的產出。
public struct ScanResult: Sendable {
    /// 這次新讀到的 chunk。
    public let chunks: [ScannedChunk]
    /// 需要先清掉既有 chunk 的來源檔（prefix 不符 → 整份重解）。
    ///
    /// 分開回報而不是讓呼叫端自己比對 state：舊 chunk 沒清掉的話，被改寫的
    /// 內容會以兩個版本同時留在索引裡，而檢索不會報錯——只會安靜地回舊文字。
    public let invalidatedSources: Set<String>
    /// 本輪讀不到的來源（列目錄失敗、開檔失敗）。
    ///
    /// **與「消失」嚴格區分**：讀不到可能只是權限暫時失效，把它當成消失會刪掉
    /// 不該刪的東西，而那個刪除無法從索引本身還原。
    public let unreadableSources: Set<String>
    public let state: ScanState
    /// 掃描期間跳過的紀錄數，依原因分類。
    public let skipped: SkipTally
}

/// 跳過的紀錄統計。
///
/// 存在的理由是**不靜默**：語料是外來資料，跳過是正常的，但「跳過了多少、為什麼」
/// 必須說得出來，否則索引少了東西沒有人會發現。
public struct SkipTally: Sendable, Equatable {
    /// 不是對話 turn（queue-operation / attachment / ai-title / last-prompt 等）。
    public var notATurn = 0
    /// 缺 uuid / sessionId / timestamp。
    public var missingPointerField = 0
    /// 識別碼不符 `OpaqueIdentifier` 的形狀（語料給了預期外的值）。
    public var malformedIdentifier = 0
    /// 正規化之後沒有文字可綁（純空白、或只有 tool payload）。
    public var noIndexableText = 0
    /// 這一行不是合法 JSON。
    public var unparseableLine = 0
    /// 檔案結尾的半行（正在被寫入）。**與 malformed 分開記**：把並行寫入報成
    /// 語料損壞會讓真正的損壞淹沒在噪音裡。
    public var incompleteTrailingRecord = 0

    public init() {}

    public var total: Int {
        notATurn + missingPointerField + malformedIdentifier + noIndexableText + unparseableLine
            + incompleteTrailingRecord
    }
}

/// 語料掃描：唯讀地走過 `~/.claude/projects/**/*.jsonl`，產生 chunk。
///
/// 增量策略沿用 CLAUDE.md 的那一句：**不假設 jsonl 是 append-only，但利用它**。
/// 已處理段落的雜湊對得上就從 `processedBytes` 續讀；對不上就整份重解，並要求
/// 呼叫端先清掉那個來源的舊 chunk。

/// 掃描期間實際讀了多少 bytes。**只給測試用，所以是 internal。**
///
/// 存在的理由是「重複讀取」這個性質無法從 `scan()` 的回傳值觀察——兩次讀取與一次
/// 讀取產出的 `ScanState` 逐字相同。要把它釘住就得看**做了多少 I/O**，而那是
/// 實作細節，只有計數器看得到。
///
/// 用 reference type 是因為 `CorpusScanner` 是 `struct` 且 `scan()` 不是 `mutating`。
/// **不是 public。** `LTMIndex` 是 `Package.swift` 匯出的 `.library`，把它公開等於
/// 把一個測試計數器寫進出貨的 API 契約——而且外部消費者拿得到型別卻接不上
/// scanner（唯一的建構子是 internal），只會拿到一個 inert 的可變物件。
/// 測試用 `@testable import LTMIndex` 就看得到，不需要 public。
final class ReadTally: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    init() {}
    var bytesRead: Int { lock.lock(); defer { lock.unlock() }; return total }
    func add(_ n: Int) { lock.lock(); total += n; lock.unlock() }
}

public struct CorpusScanner: Sendable {
    public let corpusRoot: URL
    /// Anchor 內容摘要的密鑰（#12）。與語料根同一個理由：**索引層不自己產生它**
    /// ——密鑰是機器的性質，由 facade 注入。
    public let anchorKey: AnchorKey

    /// 語料根是**必填**的，沒有預設值。
    ///
    /// 索引層不自己假設語料在哪：那個知識屬於 facade（它同時看得到 LTMMemory 的
    /// `CorpusLocation`）。兩個地方各寫一次 `~/.claude/projects` 的話，日後改動
    /// 只會改到其中一個，而不一致的那一邊會安靜地掃描空目錄。

    /// 讀取量計數器。**只有測試會設它**；生產路徑一律 `nil`。
    let readTally: ReadTally?

    public init(corpusRoot: URL, anchorKey: AnchorKey) {
        self.corpusRoot = corpusRoot
        self.anchorKey = anchorKey
        self.readTally = nil
    }

    /// 測試用：帶計數器建構。internal，且 `ReadTally` 本身也是 internal——
    /// 公開介面完全不變。
    init(corpusRoot: URL, anchorKey: AnchorKey, readTally: ReadTally?) {
        self.corpusRoot = corpusRoot
        self.anchorKey = anchorKey
        self.readTally = readTally
    }

    public enum ScanError: Error, Sendable, Equatable {
        case corpusRootUnreadable(path: String)
    }

    /// 一次目錄遍歷的結果：找到的檔案，加上**列不出來的 project**。
    ///
    /// 後者先前不存在——`contentsOfDirectory` 與 `enumerator` 的失敗都被
    /// `(try? …) ?? []` 與 `else { continue }` 吞成「這裡沒有東西」（#26）。
    /// 而「沒有東西」與「上一輪有、這一輪沒看到」在 `scan` 裡是同一件事，於是
    /// **一次權限錯誤會讓那個 project 的全部 chunk 被作廢，而命令回報成功**。
    struct DirectoryWalk {
        var files: [(project: String, url: URL, key: String)] = []
        /// 列不出內容的 project 名。它們底下的既有來源**不得**被當成消失。
        var unreadableProjects: Set<String> = []
    }

    /// 語料裡所有 `.jsonl`，附其所屬 project（= 語料根下的第一層目錄名）與 state 鍵。
    ///
    /// `key` 在**遍歷當下**由 project 目錄構造，不事後用語料根做字串前綴比對。
    /// 理由是實測（2026-08-17）：macOS 上 `FileManager` 的兩個 API 對同一棵樹給出
    /// 不同形式的路徑——`temporaryDirectory` 與 `resolvingSymlinksInPath()` 都給
    /// `/var/folders/…`，而 `contentsOfDirectory` 給 `/private/var/folders/…`。
    /// 前綴比對因此落空，鍵退化成絕對路徑：state 檔會夾帶本機路徑，換機器就
    /// 整份語料重解，而且沒有任何錯誤訊息。
    func sourceFiles() throws -> DirectoryWalk {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: corpusRoot.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ScanError.corpusRootUnreadable(path: corpusRoot.path)
        }
        // **語料根列不出來就是 fatal，不是「零個 project」**（#26）。上面那個
        // `isDirectory` 檢查已經對「根不是目錄」拋錯；列舉失敗（權限、I/O）是同一
        // 類問題的另一種表現，卻先前被 `(try? …) ?? []` 吞成空陣列——而空陣列會讓
        // `scan` 把**整份索引**作廢並回報成功。
        let projects: [URL]
        do {
            projects = try fm.contentsOfDirectory(
                at: corpusRoot, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            throw ScanError.corpusRootUnreadable(path: corpusRoot.path)
        }
        var walk = DirectoryWalk()
        for projectURL in projects.sorted(by: { $0.path < $1.path }) {
            guard (try? projectURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let project = projectURL.lastPathComponent
            // **必須用帶 `errorHandler` 的多載**（#26）。
            //
            // 先前是 `guard let walker = fm.enumerator(at:includingPropertiesForKeys:
            // options:) else { continue }`，而那個 guard **實測不會 fire**：對一個
            // 權限不足的目錄，`FileManager` 回的**不是 `nil`**，是一個安靜產出零個
            // 項目的 enumerator。所以失敗不是走 `else`，是走「這個 project 是空的」
            // ——比 issue 描述的更安靜。
            //
            // `errorHandler` 是唯一會被告知的管道。回 `true` 繼續遍歷其餘項目
            // （單一子目錄失敗不該讓整個 project 消失），但**把失敗記下來**。
            var enumerationFailed = false
            guard
                let walker = fm.enumerator(
                    at: projectURL, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in
                        enumerationFailed = true
                        return true
                    })
            else {
                walk.unreadableProjects.insert(project)
                continue
            }
            var inProject: [URL] = []
            for case let fileURL as URL in walker where fileURL.pathExtension == "jsonl" {
                inProject.append(fileURL)
            }
            // 遍歷過程中有任何一次失敗 → 這個 project 的檔案清單**不完整**，
            // 而不完整與「這些檔不見了」在下游是同一件事。
            if enumerationFailed { walk.unreadableProjects.insert(project) }
            let projectPrefix = projectURL.path.hasSuffix("/") ? projectURL.path : projectURL.path + "/"
            for url in inProject.sorted(by: { $0.path < $1.path }) {
                // enumerator 給的 URL 一定以它自己的起點為前綴（同一次遍歷、同一種
                // 路徑形式），所以這個 dropFirst 是安全的；跨 API 比對才不是。
                let withinProject =
                    url.path.hasPrefix(projectPrefix)
                    ? String(url.path.dropFirst(projectPrefix.count))
                    : url.lastPathComponent
                walk.files.append(
                    (project: project, url: url, key: "\(project)/\(withinProject)"))
            }
        }
        return walk
    }

    /// 掃描語料，只讀出上次之後的新內容。
    ///
    /// `previous` 給空狀態即為全量掃描。
    /// ## `nextState.files[key]` 的五個賦值點、四類情境（動它之前先讀這段）
    ///
    /// 查法：`grep -n 'nextState.files\[key\] =' Sources/LTMIndex/CorpusScanner.swift`
    /// —— 應該回**五**行。主路徑是一個 `if`／`else`，兩個賦值點屬於同一類。
    ///
    /// | 情境 | 賦值點 | 寫入什麼 | 前提 |
    /// |---|---|---|---|
    /// | 開檔失敗 | 1 | `prior` | **僅在 `previous` 有該鍵時**——首次見到就讀不到的檔案一個 entry 都不寫 |
    /// | 讀 tail 失敗 | 1 | `prior` | 同上 |
    /// | 主路徑 | **2** | 重用 `prior` ／ 重算 | 見下方 `#49` 的兩個條件 |
    /// | 列目錄失敗的 project | 1 | `prior` | 同上（`previous.files` 迭代而來，必有）|
    ///
    /// ## 沿用 `prior` 的兩個理由（封閉列舉，不得依性質相似類推第三個）
    ///
    /// 1. **讀不到**（開檔／讀 tail／列目錄失敗）。此時不可能重算，沿用是唯一不
    ///    製造「假消失」的選擇。**代價要說清楚**：那份 state 的新鮮度等於**最後
    ///    一次讀得到的那一輪**，不是上一輪——一個連續 N 輪讀不到的來源會把 N 輪
    ///    前的 state 一路搬下去。`unreadable` 分支本來就是為這件事存在的。
    /// 2. **本輪剛驗證過、且沒有消化新 byte**（僅限主路徑）。理由與第 1 條完全
    ///    不同：它靠的是**這一輪**的雜湊比對。
    ///
    /// **讀得到檔案卻沿用 `prior`，一律是 bug。** 一個未來的寫入點若已經讀過檔案、
    /// 發現內容變了，卻援引「沿用是安全的」搬運舊 hash，結果就是索引少掉那段內容
    /// 而沒有任何訊號——正是這張表要防的東西。
    ///
    /// 這則表格是刻意寫的：git 2018 年的 split-index bug 就是「某條路徑沒把 entry
    /// 交給守衛常式」而安靜失去保護，成因看起來完全無辜。
    /// - Parameters:
    ///   - progress: 掃描進度 callback `(已掃檔數, 總檔數)`。**預設 nil**——查詢
    ///     路徑（`refreshIncrementally` → `build` → 這裡）不傳，此時整段心跳邏輯
    ///     （含計數與取時鐘）都不執行（#48）。分母在 `sourceFiles()` 回傳的那一刻
    ///     就是精確的（完全物化的陣列；掃描階段量測見
    ///     `docs/measurements/2026-08-28-scan-phase-silence.md`，9,935 檔的語料），
    ///     所以第一則就是 `0/N`，不必先報「已掃 k 個」再升級成 `k/N`。
    ///   - progressFileInterval: 每幾個檔案發一次心跳。與 `progressTimeInterval`
    ///     是 **or**：先到者發，**發完兩個計數器都重置**——否則慢檔情境下時間側
    ///     每次都觸發、快檔情境下計數側每次都觸發，各自把 stderr 洗版
    ///     （同 `IndexBuilder` 嵌入心跳的既決形狀，#45）。
    ///     **時間側只在檔案邊界檢查**：單一超大或極慢的檔案處理期間仍然沒有心跳
    ///     ——「每 T 秒」對那種形狀不成立（#48 verify，codex）。逐行 checkpoint
    ///     要動解析迴圈，與 #47 相鄰，刻意不在本 issue 做。
    public func scan(
        previous: ScanState = ScanState(),
        progress: ((Int, Int) -> Void)? = nil,
        progressFileInterval: Int = 500,
        progressTimeInterval: TimeInterval = 5
    ) throws -> ScanResult {
        precondition(progressFileInterval > 0, "心跳間隔必須為正（同 IndexBuilder 的既決形狀）")
        precondition(progressTimeInterval > 0, "心跳間隔必須為正")
        var chunks: [ScannedChunk] = []
        var invalidated: Set<String> = []
        var unreadable: Set<String> = []
        var nextState = ScanState()
        var tally = SkipTally()
        var seenKeys: Set<String> = []

        let walk = try sourceFiles()
        // 開工先說一句（0/N）——「完全沉默」與「卡死」外觀相同（#48；空語料也報，
        // 0/0 仍然是「我開工了而且沒有東西要掃」這個有內容的訊息）。
        progress?(0, walk.files.count)
        var scannedFiles = 0
        var filesSinceBeat = 0
        var lastBeat = Date()
        for (project, url, key) in walk.files {
            // 心跳在 defer：迴圈體有 `continue`（現行**兩條**，都是「讀不到」；
            // 上一版這裡列了三類——一份沒對過 code 的列舉，#48 verify），每一條
            // 路都算「掃過一個檔」——insert 站點只有一個才不會漏。
            //
            // 整段包在 `if progress != nil` 裡：查詢路徑（progress 為 nil）連
            // 計數與 `Date()` 都不執行——上一版寫「零回報開銷」而計數照跑，
            // 一句可被 nil 輸入直接推翻的絕對句（#48 verify，codex + security）。
            defer {
                if progress != nil {
                    scannedFiles += 1
                    filesSinceBeat += 1
                    let now = Date()
                    if filesSinceBeat >= progressFileInterval
                        || now.timeIntervalSince(lastBeat) >= progressTimeInterval
                    {
                        progress?(scannedFiles, walk.files.count)
                        filesSinceBeat = 0
                        lastBeat = now
                    }
                }
            }
            seenKeys.insert(key)
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                unreadable.insert(key)
                // 讀不到的來源**保留上一輪的狀態**：既不作廢它的 chunk，也不讓
                // 新 state 少掉這個鍵——否則下一輪會把它誤判成「消失」。
                if let prior = previous.files[key] { nextState.files[key] = prior }
                continue
            }
            defer { try? handle.close() }

            let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
            // **負的游標當成「沒有游標」，不是當成一個位置。**
            //
            // 它到得了這裡：`scan_state` 是外部可 UPDATE 的，而舊索引的列早於
            // `CHECK(processed_bytes >= 0)`。舊行為是讓它一路走到
            // `seek(toOffset: UInt64(-1))` 而 **trap**（#49 R2 verify，security
            // lens，端到端重現：`ltm build` 與 `ltm query` 同時 exit 133、零輸出）。
            //
            // 處置是**丟棄並重掃**，不是丟錯：丟錯會讓這個來源被記成 unreadable
            // 並**永遠保留那個壞游標**——一個修不好的卡住狀態。重掃是慢，但正確。
            //
            // **這一層在出貨路徑上到不了**，而那是刻意的：`IndexDatabase.scanState()`
            // 已經把負值修成一個必然對不上的游標（見該處註解）。留著它是因為
            // `CorpusScanner` 是 public 且 `previous:` 由呼叫端給——一個直接呼叫端
            // 仍然遞得進負值，而語料解析路徑一律不得 trap。驅動它的是
            // `aNegativeCursorIsDiscardedRatherThanTrapping`，那條測試正是直接呼叫端。
            var priorState = previous.files[key]
            if let prior = priorState, prior.processedBytes < 0 {
                priorState = nil
                invalidated.insert(key)
            }
            // 續讀的三個條件缺一不可：有舊狀態、檔案沒有變短、且已處理段落的
            // 雜湊對得上。檔案變短代表它被改寫過，即使前綴雜湊碰巧相符。
            //
            // **雜湊涵蓋整段已處理前綴，不是固定開頭**——所以檔案中段被改而
            // size 未變時會被偵測到（#5 兩難的第一角）。代價是每次都要重讀那一
            // 段；成本量在 `docs/measurements/2026-08-26-resume-prefix-hash-cost.md`
            // （當下語料的上界約 4 秒），該紀錄同時寫了改用分塊 Merkle 的重議觸發。
            var startOffset = 0
            // **顯式旗標，不從 `startOffset` 反推。**
            //
            // 看起來 `startOffset == prior.processedBytes` 就代表「比對通過」——
            // `startOffset` 只在成功分支被賦值。但有一個縫：`prior.processedBytes`
            // 為 0 而 `prior.prefixHash` 不是空資料的雜湊時（state 被手動編輯、或
            // 未來某個 bug 寫出不一致組合），比對會**失敗**、`startOffset` 保持 0，
            // 而 `startOffset == prior.processedBytes` 仍然成立 → 會錯誤地沿用一個
            // 已知不一致的 hash。
            //
            // 判準：**不要從一個值反推另一件事，把那件事記下來。**
            var resumedFromVerifiedPrefix = false
            // **增量雜湊**（#47）：整個檔案每個 byte 恰好被雜湊一次。前綴在比對
            // 時餵進 hasher；比對用**快照**（value type 複製後 finalize），原件
            // 繼續吃 tail——逐 chunk 的切點快照就從同一個 hasher 取。
            // canary：`snapshotOfIncrementalHasherMatchesOneShotDigest`。
            var hasher = SHA256()
            if let prior = priorState, prior.processedBytes <= size,
                let prefix = try? readBytes(handle, from: 0, count: prior.processedBytes)
            {
                var candidate = SHA256()
                candidate.update(data: prefix)
                let digest = candidate.finalize().map { String(format: "%02x", $0) }.joined()
                if digest == prior.prefixHash {
                    startOffset = prior.processedBytes
                    resumedFromVerifiedPrefix = true
                    hasher = candidate
                } else if priorState != nil {
                    invalidated.insert(key)
                }
            } else if priorState != nil {
                invalidated.insert(key)
            }

            guard let tail = try? readBytes(handle, from: startOffset, count: size - startOffset)
            else {
                unreadable.insert(key)
                if let prior = previous.files[key] { nextState.files[key] = prior }
                continue
            }
            let parsed = parse(data: tail, project: project, sourceKey: key, tally: &tally)
            // 逐 chunk 切點：hasher 吃到每個切點、取快照當該 chunk 的游標（#47）。
            var hashedUpTo = 0
            for (chunk, relEnd) in zip(parsed.chunks, parsed.chunkEnds) {
                if relEnd > hashedUpTo {
                    hasher.update(data: tail.subdata(
                        in: tail.startIndex + hashedUpTo..<tail.startIndex + relEnd))
                    hashedUpTo = relEnd
                }
                let snapshot = hasher
                chunks.append(
                    ScannedChunk(
                        chunk: chunk, endOffset: startOffset + relEnd,
                        prefixHashAtEnd: snapshot.finalize()
                            .map { String(format: "%02x", $0) }.joined()))
            }
            // 最後一個切點到 consumed 之間的 skip 行也要進 hasher——最終 digest
            // 就是新的 prefixHash。
            if parsed.consumedBytes > hashedUpTo {
                hasher.update(data: tail.subdata(
                    in: tail.startIndex + hashedUpTo..<tail.startIndex + parsed.consumedBytes))
            }

            // offset 只推進到**最後一個完整紀錄**之後；雜湊只涵蓋那一段。
            // 半行留給下一輪從它的起點重讀。
            let processed = startOffset + parsed.consumedBytes

            // **沒有新內容時不重算**（#49）。
            //
            // 兩個條件缺一不可：
            //   (a) 續讀比對**通過**——上面那一段已經證明 `0..<startOffset` 的雜湊
            //       等於 `prior.prefixHash`；
            //   (b) 這一輪沒有消化任何新 byte——於是 `processed == startOffset`。
            //
            // 兩者同時成立時，`0..<processed` 就是剛剛驗證過的那一段，重讀它並
            // 重算 SHA-256 的輸出**必然**是 `prior.prefixHash`。移除那次冗餘的
            // 代價被直接量到：`build --quiet` 的中位數 6.58 → 3.56 s（**實測差
            // −3.02 s**，`docs/measurements/2026-08-27-query-latency-decomposition.md`）。
            //
            // 這裡刻意不寫「佔掃描的一半」那種分數，也不寫 `2.27` / `4.51`——
            // 那兩個數字曾經寫在這裡並被稱為「實測」，而它們是**模型值**（唯一
            // 量到的是 Python 單次全讀+雜湊的 2.39 s）。#49 R2 verify，
            // devil's advocate。誠實邊界：出貨表面上的數字要能指回一份涵蓋它的
            // 紀錄，而那份紀錄現在只宣稱這個實測差。
            //
            // 條件寫寬的後果是**安靜的**：檔案被改寫時沿用舊 hash，索引少掉那段
            // 內容而沒有任何訊號，症狀只有「以前找得到的東西現在找不到」。這正是
            // `prefixHash` 存在要防的那件事，所以 (a) 不可省成
            // 「`startOffset == prior.processedBytes`」（見上方旗標的註解）。
            //
            // `consumedBytes == 0` 但檔案變長是合法且安全的情況：新增的是**半行**
            // （不完整紀錄），`processed` 不變，而雜湊涵蓋的 `0..<processed` 確實
            // 沒變。半行留給下一輪，語意與重算完全相同。
            //
            // **順帶關掉了一個既有的 TOCTOU 窗口**（審查時才被指出，不是本次的目標）。
            // 舊碼的時序是：T1 驗證前綴 → T2 讀 tail 並解析 → T3 **再讀一次**
            // `0..<processed` 並存下它的雜湊。若檔案在 T1–T3 之間被改寫
            // （`~/.claude/projects/` 正是被活著的 session 持續寫入的目錄，所以這
            // 不是假想），T3 會存下**新內容**的雜湊配上**舊解析**的 offset ——
            // 下一輪比對成功、從 `processed` 續讀，那段改寫**永遠不會被重解**。
            //
            // 新碼在重用分支存的是 T1 驗證過的 `prior`。若前綴真的被改過，下一輪
            // 比對必然失敗 → invalidate → 整份重解 → 收斂。最壞是一次不必要的
            // 重解（貴，但正確），不會安靜錯。
            //
            // **誠實邊界**：只收窄、沒有消除 —— `consumedBytes > 0` 時仍走下面的
            // 重算路徑，同一個窗口還在。
            if resumedFromVerifiedPrefix, parsed.consumedBytes == 0, let prior = priorState {
                // 這裡寫回 `prior` 而不是重造 `SourceFileState`，靠的是上面
                // `resumedFromVerifiedPrefix` 為真時 `startOffset == prior.processedBytes`
                // （那個賦值就在同一個 `if` 裡，約 60 行之上）。兩者一旦分岔，
                // 寫回的 `processedBytes` 就會與 `processed` 不符。
                //
                // **這裡刻意不放 `assert`。** 試過，然後拿掉了：`scan()` 是語料
                // 解析路徑，而 CLAUDE.md 的規則是「語料是外來資料，解析路徑一律
                // 不得 trap」——debug build 下一筆被手改的 `scan_state`（正是
                // `aSelfInconsistentCursorIsRecomputedNotReused` 構造的那種）會把
                // 整個 `ltm` 行程打掉。實測它也讓 `swift test` 收到 signal 5，
                // 後面的測試整批沒跑到：把一個可診斷的失敗變成了行程中止。
                //
                // 扛這條不變式的是測試，不是斷言——見上面那兩條守衛測試。
                nextState.files[key] = prior
            } else {
                // **不再整段重讀**（#47）：hasher 已恰好吃完 `0..<processed`
                // （續讀時前綴在比對時餵入、tail 在逐切點時餵入）。存的是
                // **實際被解析的 bytes** 的雜湊——TOCTOU 的 T3 重讀窗口消失，
                // T1–T2 之間的窗口仍在（誠實邊界，同上一段註解）。
                nextState.files[key] = SourceFileState(
                    prefixHash: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                    processedBytes: processed)
            }
        }

        // **列不出內容的 project 底下的既有來源，一律視為讀不到而非消失**（#26）。
        //
        // 這一步必須在下面的作廢之前：`enumerator` 失敗會讓那個 project 一個檔都沒
        // 被看到，而「沒看到」在下一段就是「消失」。一次權限錯誤因此會作廢那個
        // project 的全部 chunk，**而且回報成功**——這正是 #26 的症狀。
        //
        // 保護的同時也要**說出來**：把它們併進 `unreadable`，那是
        // `ScanResult.unreadableSources` 的 doc 一直宣稱涵蓋（「列目錄失敗、開檔
        // 失敗」）而實際沒有涵蓋的一半。
        for project in walk.unreadableProjects {
            let prefix = "\(project)/"
            for key in previous.files.keys where key.hasPrefix(prefix) {
                unreadable.insert(key)
                if let prior = previous.files[key] { nextState.files[key] = prior }
            }
        }

        // 上一輪有、這一輪沒看到、而且不是「讀不到」的來源 → 它消失了，作廢它的 chunk。
        // 少了這一步，增量索引會保留全量重建不會產生的內容——直接違反不變式 2，
        // 而且那些 chunk 指向已不存在的 turn。
        for key in previous.files.keys where !seenKeys.contains(key) && !unreadable.contains(key) {
            invalidated.insert(key)
        }

        return ScanResult(
            chunks: chunks, invalidatedSources: invalidated, unreadableSources: unreadable,
            state: nextState, skipped: tally)
    }

    private func readBytes(_ handle: FileHandle, from offset: Int, count: Int) throws -> Data {
        // **`offset` 為負會 trap**（`UInt64(offset)`），而語料解析路徑一律不得 trap。
        //
        // 這裡刻意**不加守衛**：加了也沒有任何測試驅動得了它，而驅動不了的守衛
        // 要拆掉、不是留著加註解（CLAUDE.md，#40 形狀）。執行點在**上游**——
        // `scan()` 把負的 `prior.processedBytes` 丟棄成「沒有游標」，所以到得了
        // 這裡的 `offset` 只有兩種：0，或一個已驗證過的非負 `processedBytes`。
        //
        // 那條實測（#49 R2 verify，security lens）是：一列 `processed_bytes = -1`
        // 配上 `prefix_hash = sha256("")` 讓 `ltm build` 與 `ltm query` 同時
        // exit 133、零輸出，唯一逃生是以小時計的 `--full`。回歸鎖在
        // `aNegativeCursorIsDiscardedRatherThanTrapping`。
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: count) ?? Data()
        readTally?.add(data.count)
        return data
    }

    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 把一段 jsonl 的 bytes 解析成 chunk。
    ///
    /// 不完整的最後一行（讀到的尾巴切在半行）會因為 JSON 解析失敗被跳過，並在
    /// 下一次掃描時因為 offset 前進而重新讀到——這是刻意的：寧可晚一輪索引到，
    /// 也不要把半行當成一筆內容。
    /// - Returns: 解析出的 chunk，以及**已完整消費的 byte 數**。
    ///
    ///   後者讓呼叫端把 resume offset 停在最後一個完整紀錄之後。先前 offset 一律
    ///   推到檔案結尾、`prefixHash` 也涵蓋那半行，於是下一輪 prefix 仍然吻合、
    ///   只讀「後半段」——那段不含 JSON 前半，仍然解析失敗。**該 turn 就此永久
    ///   從索引消失**，而註解卻宣稱它會被重讀。
    /// `chunkEnds[i]` 是 `chunks[i]` 那一行的結束位移（**相對 `data` 起點**，
    /// 含行尾換行）——#47 的批次層拿它組游標。
    func parse(
        data: Data, project: String, sourceKey: String, tally: inout SkipTally
    ) -> (chunks: [CorpusChunk], chunkEnds: [Int], consumedBytes: Int) {
        guard !data.isEmpty else { return ([], [], 0) }
        var chunks: [CorpusChunk] = []
        var chunkEnds: [Int] = []
        // 最後一個換行之後的 bytes 是不完整的一行（除非檔案剛好以換行結尾）。
        let lastNewline = data.lastIndex(of: UInt8(ascii: "\n"))
        let consumed = lastNewline.map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        if consumed < data.count { tally.incompleteTrailingRecord += 1 }
        // 手動走 newline（不用 `split`）——每個產出 chunk 的行要記它的 end offset。
        // `bytes` 以 0 起算，避開 Data slice 的非零 startIndex 陷阱。
        let bytes = [UInt8](consumed > 0 ? data.prefix(consumed) : Data())
        var lineStart = 0
        while lineStart < bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.count
            defer { lineStart = lineEnd + 1 }
            guard lineEnd > lineStart else { continue }
            let lineData = Data(bytes[lineStart..<lineEnd])
            guard
                let object = try? JSONSerialization.jsonObject(with: lineData)
                    as? [String: Any]
            else {
                tally.unparseableLine += 1
                continue
            }
            if let chunk = Self.chunk(
                from: object, project: project, sourceKey: sourceKey, key: anchorKey,
                tally: &tally)
            {
                chunks.append(chunk)
                // 含換行：`lineEnd` 指到 `\n` 本身（或 bytes.count），切點在其後。
                chunkEnds.append(min(lineEnd + 1, consumed))
            }
        }
        return (chunks, chunkEnds, consumed)
    }

    /// 一筆 jsonl 紀錄 → chunk。任何不合語料預期的紀錄一律**跳過並記帳**，
    /// 絕不中止行程：語料是外來資料，而 `Anchor` 的建構子對非法識別碼是 trap。
    static func chunk(
        from object: [String: Any], project: String, sourceKey: String, key: AnchorKey,
        tally: inout SkipTally
    ) -> CorpusChunk? {
        guard let type = object["type"] as? String, type == "user" || type == "assistant" else {
            tally.notATurn += 1
            return nil
        }
        guard let uuid = object["uuid"] as? String,
            let sessionID = object["sessionId"] as? String,
            let timestampText = object["timestamp"] as? String,
            let timestamp = Self.parseTimestamp(timestampText)
        else {
            tally.missingPointerField += 1
            return nil
        }
        // `uuid` 要先驗形狀再交給 `Anchor`——後者對非法值 `preconditionFailure`，
        // 而語料裡出現預期外的值不是我們的程式錯誤。`sessionID` 不再進 anchor，
        // 但它仍會被原樣存進索引，所以同樣要驗。
        guard (try? OpaqueIdentifier.validate(sessionID)) != nil,
            (try? OpaqueIdentifier.validate(uuid)) != nil
        else {
            tally.malformedIdentifier += 1
            return nil
        }
        guard let message = object["message"] as? [String: Any] else {
            tally.notATurn += 1
            return nil
        }
        let role = (message["role"] as? String) ?? type
        let text = Self.indexableText(from: message["content"])
        // span 不得為空、正規化後不得為空——兩者都是 `Anchor` 的硬約束，違反會 trap。
        guard !text.isEmpty, !Anchor.normalize(text).isEmpty else {
            tally.noIndexableText += 1
            return nil
        }
        let turn = Turn(id: uuid, role: role, timestamp: timestamp, text: text)
        // source 是 **project 指紋**，不是 sessionID。後者在 resume 時會變，
        // 用它定址會讓使用歷史隨著每次 resume 蒸發（見 ProjectFingerprint 的文件）。
        // sessionID 仍然保留在 chunk 上——它是導航資訊，不是身分。
        let anchor = Anchor(
            source: ProjectFingerprint.of(project), turn: turn,
            span: 0..<text.unicodeScalars.count, key: key)
        return CorpusChunk(
            sourceKey: sourceKey, project: project, sessionID: sessionID, uuid: uuid,
            timestamp: timestamp, role: role, text: text, anchor: anchor)
    }

    /// 從 message content 取可索引的文字。
    ///
    /// content 有兩種形狀：純字串，或 block 陣列（`text` / `thinking` / `tool_use` /
    /// `tool_result`）。這裡**只取 `text` block**。
    ///
    /// tool payload 不索引是已知的取捨，不是疏漏：它會切斷決策證據（該不該索引、
    /// 以及索引哪些欄位，追蹤於 issue #6）。`thinking` 同樣不取——它是模型的內部
    /// 推理，不是對話內容。這個決定改變時，anchor 因為內容定址而不需要重建語意，
    /// 但既有 chunk 的 span 會變，所以要走全量重建。
    /// `tool_use.input` 裡**算作 metadata** 的欄位。
    ///
    /// **這是封閉列舉，不得依性質相似類推第八個**（`common-spec-prose-enumeration`）。
    /// 每一個都是「做了什麼」，不是「結果是什麼」：
    ///
    /// | 欄位 | 為什麼算 metadata |
    /// |---|---|
    /// | `command` | 執行了哪一條指令 |
    /// | `file_path` / `path` | 動了哪個檔 |
    /// | `pattern` / `query` | 搜了什麼 |
    /// | `url` | 取了哪個位址 |
    /// | `description` | 呼叫端自己寫的一句話 |
    ///
    /// **刻意不在裡面的**：`content`、`new_string`、`old_string`、`body`、`prompt`
    /// ——它們是 payload，不是 metadata。一個「看起來也像識別資訊」的新欄位要加
    /// 進來，得先說明它為什麼不是 payload，而不是因為它像上面某一個。
    static let toolMetadataFields = [
        "command", "file_path", "path", "pattern", "query", "url", "description",
    ]

    /// 單一 metadata 欄位取多長。
    ///
    /// 上限存在的理由不是省空間，是**指令本身可以夾帶 payload**
    /// （`echo "一整段內容" > f`）。截斷讓「跑了什麼」留得住，而夾帶的東西留不住
    /// 完整。這**不是**一道邊界——一個短的夾帶仍然會進去。
    static let toolMetadataFieldLimit = 200

    /// 可索引的文字。
    ///
    /// ## tool block 只取 metadata，不取 payload（#6）
    ///
    /// 先前只取 `type == "text"`，其餘整個丟掉。實測（
    /// `docs/measurements/2026-08-26-tool-payload-share.md`）：**看得見 21.3% 的
    /// 字元量，看不見 78.7%**，而 `tool_result` 一項就佔 65.7%。
    ///
    /// 現在收 `tool_use` 的**工具名與封閉列舉的識別欄位**，以及 `tool_result` 的
    /// **成敗**。這讓「那次跑 benchmark 的對話在哪」搜得到，而不把 payload 收進來。
    ///
    /// **payload 沒有被收，理由不是它沒價值，是還沒有東西能判斷它有多少價值**
    /// ——那需要一組 `(查詢, 應命中的 turn)` 的評估集（#33）。而它含檔案內容與
    /// 命令輸出，也就是可能含第三方逐字內容，所以在能判斷之前不收是安全的一側。
    static func indexableText(from content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for block in blocks {
            guard let kind = block["type"] as? String else { continue }
            switch kind {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { parts.append(text) }
            case "tool_use":
                parts.append(toolUseMetadata(from: block))
            case "tool_result":
                // **只記成敗，不記內容。** 這一項是丟掉的 65.7%。
                let failed = (block["is_error"] as? Bool) ?? false
                parts.append("⟨tool_result \(failed ? "error" : "ok")⟩")
            default:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }

    /// 一個 `tool_use` block 的 metadata 摘要。
    static func toolUseMetadata(from block: [String: Any]) -> String {
        let name = (block["name"] as? String) ?? "?"
        var pieces = ["⟨tool \(name)"]
        let input = (block["input"] as? [String: Any]) ?? [:]
        for field in toolMetadataFields {
            guard let raw = input[field] as? String, !raw.isEmpty else { continue }
            let flattened = raw.replacingOccurrences(of: "\n", with: " ")
            let clipped =
                flattened.count > toolMetadataFieldLimit
                ? String(flattened.prefix(toolMetadataFieldLimit)) + "…"
                : flattened
            pieces.append("\(field)=\(clipped)")
        }
        return pieces.joined(separator: " ") + "⟩"
    }

    /// ISO-8601，容許有無小數秒兩種寫法。
    static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
