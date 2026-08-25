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

/// 一次掃描的產出。
public struct ScanResult: Sendable {
    /// 這次新讀到的 chunk。
    public let chunks: [CorpusChunk]
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
public struct CorpusScanner: Sendable {
    public let corpusRoot: URL

    /// 語料根是**必填**的，沒有預設值。
    ///
    /// 索引層不自己假設語料在哪：那個知識屬於 facade（它同時看得到 LTMMemory 的
    /// `CorpusLocation`）。兩個地方各寫一次 `~/.claude/projects` 的話，日後改動
    /// 只會改到其中一個，而不一致的那一邊會安靜地掃描空目錄。
    public init(corpusRoot: URL) {
        self.corpusRoot = corpusRoot
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
    public func scan(previous: ScanState = ScanState()) throws -> ScanResult {
        var chunks: [CorpusChunk] = []
        var invalidated: Set<String> = []
        var unreadable: Set<String> = []
        var nextState = ScanState()
        var tally = SkipTally()
        var seenKeys: Set<String> = []

        let walk = try sourceFiles()
        for (project, url, key) in walk.files {
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
            let priorState = previous.files[key]
            // 續讀的三個條件缺一不可：有舊狀態、檔案沒有變短、且已處理段落的
            // 雜湊對得上。檔案變短代表它被改寫過，即使前綴雜湊碰巧相符。
            var startOffset = 0
            if let prior = priorState, prior.processedBytes <= size,
                let prefix = try? readBytes(handle, from: 0, count: prior.processedBytes),
                Self.hexDigest(prefix) == prior.prefixHash
            {
                startOffset = prior.processedBytes
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
            chunks.append(contentsOf: parsed.chunks)

            // offset 只推進到**最後一個完整紀錄**之後；雜湊只涵蓋那一段。
            // 半行留給下一輪從它的起點重讀。
            let processed = startOffset + parsed.consumedBytes
            let whole = (try? readBytes(handle, from: 0, count: processed)) ?? Data()
            nextState.files[key] = SourceFileState(
                prefixHash: Self.hexDigest(whole), processedBytes: processed)
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
        guard count > 0 else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
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
    func parse(
        data: Data, project: String, sourceKey: String, tally: inout SkipTally
    ) -> (chunks: [CorpusChunk], consumedBytes: Int) {
        guard !data.isEmpty else { return ([], 0) }
        var chunks: [CorpusChunk] = []
        // 最後一個換行之後的 bytes 是不完整的一行（除非檔案剛好以換行結尾）。
        let lastNewline = data.lastIndex(of: UInt8(ascii: "\n"))
        let consumed = lastNewline.map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        if consumed < data.count { tally.incompleteTrailingRecord += 1 }
        let complete = consumed > 0 ? data.prefix(consumed) : Data()
        for lineData in complete.split(separator: UInt8(ascii: "\n")) {
            guard !lineData.isEmpty else { continue }
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(lineData))
                    as? [String: Any]
            else {
                tally.unparseableLine += 1
                continue
            }
            if let chunk = Self.chunk(
                from: object, project: project, sourceKey: sourceKey, tally: &tally)
            {
                chunks.append(chunk)
            }
        }
        return (chunks, consumed)
    }

    /// 一筆 jsonl 紀錄 → chunk。任何不合語料預期的紀錄一律**跳過並記帳**，
    /// 絕不中止行程：語料是外來資料，而 `Anchor` 的建構子對非法識別碼是 trap。
    static func chunk(
        from object: [String: Any], project: String, sourceKey: String, tally: inout SkipTally
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
            span: 0..<text.unicodeScalars.count)
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
    static func indexableText(from content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for block in blocks {
            guard let kind = block["type"] as? String, kind == "text",
                let text = block["text"] as? String, !text.isEmpty
            else { continue }
            parts.append(text)
        }
        return parts.joined(separator: "\n")
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
