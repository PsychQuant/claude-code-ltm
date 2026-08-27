import CryptoKit
import Foundation
import LTMCore
import SQLite3

/// 讀一個 TEXT 欄位，**用明確的 byte 長度**而不是 C-string 語意。
///
/// `String(cString:)` 在第一個 NUL 停下來，與寫入端 `bind_text(-1)` 是同一個截斷的
/// 兩端。兩邊都改才有意義：只改寫入端，讀出來的仍然是半截。
func columnText(_ statement: OpaquePointer, _ column: Int32) -> String {
    guard let raw = sqlite3_column_text(statement, column) else { return "" }
    let count = Int(sqlite3_column_bytes(statement, column))
    return String(decoding: UnsafeBufferPointer(start: raw, count: count), as: UTF8.self)
}
import LTMEval
import LTMIndex
import LTMMemory
import LTMQuery

/// 索引背書的 `CorpusReader`，**預先載入**成值型別。
///
/// `LTMCore` 宣告了這個 protocol 並註明「實作住在 ingest 層」；這就是它。
/// projection 需要它把 anchor 還原成文字，才能判斷一筆使用歷史指的內容還在不在。
///
/// 為什麼是預載而不是包一個資料庫連線：
///
/// 1. `CorpusReader` 是 `Sendable`，而 SQLite 連線（`SQLITE_OPEN_NOMUTEX`）不是。
///    用 `@unchecked Sendable` 硬繞過去，就是把一個型別系統攔得住的資料競爭
///    改成靠註解自律。
/// 2. projection 會對**每一筆事件**的 anchor 呼叫一次；包連線等於在迴圈裡打
///    N 次資料庫，而需要的 turn 集合在進迴圈前就已經知道了。
///
/// 內容來源仍是索引（純衍生物），只是換成一次撈齊。
struct PreloadedCorpusReader: CorpusReader {
    /// 鍵是 `source` 與 `turnID` 的組合。用 NUL 當分隔字元：它不可能出現在
    /// `OpaqueIdentifier` 允許的字元集裡，所以兩個欄位不會黏成同一個鍵。
    private let turns: [String: Turn]

    init(turns: [String: Turn]) { self.turns = turns }

    static func key(source: String, turnID: String) -> String { "\(source)\u{0}\(turnID)" }

    func turn(id: String, inSource source: String) -> Turn? {
        turns[Self.key(source: source, turnID: id)]
    }

    /// 把指定的 (source, turnID) 一次撈齊。
    static func load(anchors: [Anchor], from database: IndexDatabase) throws -> PreloadedCorpusReader {
        var turns: [String: Turn] = [:]
        for anchor in Set(anchors) {
            try database.query(
                // anchor.source 是 project 指紋，所以這裡用 project_fingerprint 比對，
                // 不是 session_id。
                "SELECT role, timestamp, text FROM chunks WHERE uuid = ? AND project_fingerprint = ?",
                bind: [.text(anchor.turnID), .text(anchor.source)]
            ) { statement in
                let role = columnText(statement, 0)
                let timestamp = sqlite3_column_double(statement, 1)
                let text = columnText(statement, 2)
                turns[key(source: anchor.source, turnID: anchor.turnID)] = Turn(
                    id: anchor.turnID, role: role,
                    timestamp: Date(timeIntervalSince1970: timestamp), text: text)
            }
        }
        return PreloadedCorpusReader(turns: turns)
    }
}

/// LTMMemory 的語料守衛，注入給索引層。
///
/// 依賴反轉的另一端：判定的實作在 LTMMemory（`CorpusLocation`），需求宣告在
/// LTMIndex（`CorpusContainmentPolicy`），而 facade 是唯一同時看得到兩者的地方。
/// 綁定「當下實際使用的語料根」的 containment 判定。
///
/// 先前這個型別只問固定的 `~/.claude/projects`，於是語料根被環境變數覆寫時，
/// 一個指向**正在被掃描的語料**的衍生根照樣通過檢查——而 code 註解當時寫著
/// 「覆寫不會放寬任何守衛」。那句話是假的。
///
/// 現在它同時保護兩者：預設語料根**與**這次實際使用的語料根。少任何一邊都有洞：
/// 只看預設 → 覆寫路徑沒守衛；只看當下 → 有人把 derived 指進預設語料。
extension LTMService {
    /// 由工作目錄推出 project 名。
    ///
    /// Claude Code 把專案路徑的 `/` 換成 `-` 當目錄名。這裡**產生候選之後確認
    /// 目錄真的存在**，而不是相信轉換規則——規則是觀察來的，不是契約，猜錯時
    /// 「查不到東西」與「查錯專案」都不會有錯誤訊息。
    ///
    /// 住在 facade 而不是 CLI（#24）：MCP server 需要同一份推導，而兩份實作的
    /// 漂移方向是「其中一個介面把使用者導到別的專案」——那不會有錯誤訊息。
    public static func projectName(
        forWorkingDirectory cwd: String, corpusRoot: URL = CorpusLocation.readOnlyRoot
    ) -> String? {
        let candidate = cwd.replacingOccurrences(of: "/", with: "-")
        var isDirectory: ObjCBool = false
        let path = corpusRoot.appendingPathComponent(candidate).path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return candidate
    }
}

/// 語料圍籬。**實作在 `LTMMemory.CorpusPolicy`**，這裡只是既有名字的別名（#27）。
///
/// 先前這裡是第二份實作。它與 `FileEventStore` 用的那份是同一件事的兩個寫者，
/// 而記憶層那份只認固定預設根——於是 facade 有雙重保護、library 層沒有，兩者
/// 在 `LTM_CORPUS_ROOT` 被覆寫時給出不同答案。
public typealias MemoryCorpusPolicy = CorpusPolicy

/// 一筆回傳給呼叫端的結果。
///
/// 指標四欄 + 位移 + 理由。**檢索負責導航，不負責當答案**（不變式 3 的推論），
/// 所以 `snippet` 是原文片段而不是摘要——摘要會讓呼叫端以為它可以直接用。
public struct QueryHit: Sendable, Equatable {
    public let project: String
    /// 持有這則 turn 的**全部**來源各自的 session 識別碼，依 `source_key` 字典序。
    ///
    /// 至少一個元素。這是導航資訊的本體：resume 複製讓同一則 turn 活在多份檔裡，
    /// 使用者要知道的是「可以去哪幾份檔看上下文」，而不是一個由檔名字典序碰巧
    /// 選出的單一值（#25）。
    public let sessionSources: [String]
    public let uuid: String
    public let timestamp: Date
    public let snippet: String
    public let score: Double
    public let band: Int
    /// 相對於純檢索順序的位移（正數代表上移）。
    public let displacement: Int
    /// 這一筆自己的使用歷史狀態。
    public let historyDescription: String
    /// 實際發生的位移方向與幅度。
    public let movementDescription: String
    public let anchor: Anchor
    /// 這一筆是被哪幾條檢索通道找到的。
    ///
    /// 它同時是**解釋**（為什麼這筆會出現）與 **band 的來源**（見 retrieval spec
    /// 的 "A candidate's relevance band is the number of retrieval channels it
    /// matched"）。暴露它讓「band 從哪來」在輸出上看得見，而不是只能讀 code 推斷。
    public let channels: [String]
    /// 這次查詢的呈現識別碼——同一次 `query()` 呼叫的所有 hit 共用同一個值。
    ///
    /// 只在 `recordEvents` 為真且有 `eventStore` 時才非 nil（沒有事件檔可寫，
    /// 就沒有指標可以指）。存在的理由是讓未來的 deliberate 事件寫入者（例如
    /// Stage 2 MCP，見 #24）能把「使用者稍後點開了這個結果」記在跟這次呈現
    /// 一樣的群組底下——`EventStore.append` 已經接受 `presentation` 參數，
    /// 不需要新的記錄 API，只是先前這條路徑一律傳 nil（見 #15 的 diagnosis）。
    public let presentation: PresentationID?
}

/// 一次查詢的完整結果。
/// 查詢路徑上那一次增量續讀的結果。
public struct RefreshReport: Sendable {
    /// 有新內容的來源檔數。
    public let sourcesRefreshed: Int
    /// **讀不到**的來源（權限、I/O）。它們不會被作廢，但必須說出來。
    public let sourcesUnreadable: [String]
    /// 因為消失或內容變動而被作廢的來源數。
    public let sourcesInvalidated: Int
    /// 跳過的紀錄分類統計。
    public let skipped: SkipTally
    /// 這一輪**沒有**併入新內容，因為有另一個建置正在跑。
    ///
    /// 查詢照常從既有索引回答——那是對的，拒答會更糟。但**不併入就必須說出來**，
    /// 與 `sourcesUnreadable` 同一條原則：否則使用者看到的是一次成功的查詢，
    /// 而剛剛那段對話不在裡面，他不會知道要再查一次。
    ///
    /// #44 ② 問「查詢路徑撞上 build 的鎖會怎樣」，並列出三種可能：阻塞、逾時、
    /// 具名錯誤。實際答案是**第四種**——靜默降級。跨模型盲驗指出這一點時，
    /// 它既沒有被測試釘住，也沒有任何管道告訴使用者。
    public let mergeDeferredForConcurrentBuild: Bool

    /// 調校參數解析時被拒絕的環境變數，人類可讀。
    ///
    /// **值到得了、錯誤也要到得了。** `BuildTuning.fromEnvironment()` 回傳
    /// `(tuning, rejections)`，而上一版只取 `.tuning`——於是使用者設了
    /// `LTM_BUILD_MEMORY_BUDGET_MB=64x` 之後，預算靜默失效、沒有任何診斷，
    /// 查詢照常運作（#46 R3 verify，codex + regression）。那是 F 那條修法的反面缺口。
    public let tuningRejections: [String]

    public init(
        sourcesRefreshed: Int, sourcesUnreadable: [String], sourcesInvalidated: Int,
        skipped: SkipTally, mergeDeferredForConcurrentBuild: Bool = false,
        tuningRejections: [String] = []
    ) {
        self.tuningRejections = tuningRejections
        self.sourcesRefreshed = sourcesRefreshed
        self.sourcesUnreadable = sourcesUnreadable
        self.sourcesInvalidated = sourcesInvalidated
        self.skipped = skipped
        self.mergeDeferredForConcurrentBuild = mergeDeferredForConcurrentBuild
    }
}

/// 一次查詢的完整結果：命中、用了哪個策略、續讀做了什麼、寫了幾筆事件。
///
/// （這份 doc 曾經因為 `RefreshReport` 被插在它正上方而消失——型別還在，說明沒了。）
public struct QueryOutcome: Sendable {
    public let hits: [QueryHit]
    public let strategyID: String
    /// 這次查詢的增量續讀做了什麼——**含它讀不到什麼**。
    ///
    /// 先前這裡只有一個 `refreshedSources: Int`，其餘（讀不到的來源、跳過的紀錄、
    /// 作廢的來源）在委派給 `IndexBuilder` 之後被原地丟掉。那讓同一段掃描出現兩種
    /// 說法：走 `ltm build` 會說出讀不到哪些檔，走 `ltm query` 一個字都不說——而
    /// `ltm query` 是使用者最常走的那條，也就是那個「看起來成功」的介面。
    public let refresh: RefreshReport
    /// 寫了幾筆 `shown` 事件（未開啟記錄時為 0）。
    public let eventsRecorded: Int
    /// 排序回傳了、但**無法歸屬到指標**因而被丟棄的筆數（#13）。
    ///
    /// 不變式 3 要求每個命中帶 `(project, sessions, uuid, timestamp)`，所以一個
    /// 歸屬不到來源的結果**不能被回傳**——那會是一個沒有導航資訊的命中，而
    /// 「檢索負責導航」正是它唯一的職責。丟棄是對的。
    ///
    /// **但沉默地丟棄不對。** 這個計數非零代表策略回傳了不在候選集合裡的 anchor，
    /// 而 seam 的排列性檢查應該早就擋掉那件事——所以它非零本身就是一個訊號：
    /// 要嘛 seam 有洞，要嘛 `scored` 與 `ranked` 之間有第三個寫者。
    ///
    /// 這與 `KnownItemReport` 的三個跳過計數是同一條紀律：**沉默的跳過等於少了
    /// 東西而沒人會發現**（`CLAUDE.md`）。
    ///
    /// ## 誠實邊界：這個計數目前沒有回歸鎖，而且不可能有
    ///
    /// 那個分支**結構上到不了**：`byAnchor` 由 `scored` 建，`ranked` 來自策略，而
    /// seam 的排列性檢查要求 `ranked` 是輸入候選的排列——所以策略無法經由 `rerank`
    /// 交出一個不在候選集合裡的 anchor。把這個計數器改成永遠不增加，測試全綠。
    ///
    /// **那為什麼留著？** 因為那個 `guard ... else { continue }` 本來就在，而它先前
    /// 是靜默的。這個改動買到的不是「測得到」，是「**如果哪天真的發生，它會被看見**」。
    /// 要驅動它得先有一條繞過 seam 的注入路徑，而那條路徑不存在**正是**設計要的。
    public let unattributableResults: Int
}

/// 唯一同時看得到索引、策略與事件儲存的地方。
///
/// CLI 與（Stage 2 的）MCP server 都只是它的 adapter：adapter 翻譯輸入輸出，
/// 契約住在這裡。判準是刪除測試——刪掉 facade，兩個介面都斷；刪掉 CLI，
/// MCP 照常。
public struct LTMService {
    public let location: DerivedLocation
    public let corpusRoot: URL
    private let embedder: any EmbeddingProvider
    private let eventStore: (any EventStore)?
    /// Anchor 內容摘要的密鑰（#12）。facade 持有它，因為「密鑰在哪」是 facade
    /// 的知識——索引層與記憶層都只宣告需要它。
    private let anchorKey: AnchorKey

    /// 服務層的錯誤。**訊息住在這裡，不住在呼叫端**（#44）。
    ///
    /// 先前每一則訊息只存在於 CLI 的 `QueryCommand.report`，而 MCP 路徑構不到它
    /// ——後者走 `"✗ \(error)"`，於是拿到 enum 的預設描述（`indexMissing(path: "…")`）。
    /// 同一個錯誤在 CLI 說得出補救、在 MCP 只倒出 case 名，**而 `indexMissing` 的
    /// doc 逐字寫著「訊息一律指名 `ltm build`」**。
    ///
    /// 「失敗訊息要說出補救命令」是 `ltm-cli` capability 的 requirement，不是禮貌
    /// ——而一個只在其中一條路徑上成立的 requirement 沒有被滿足。
    public enum ServiceError: Error, Sendable, Equatable, CustomStringConvertible {
        /// `mark` 需要事件存放，而這個 service 沒有。
        case markRequiresEventStore
        /// `mark` 需要呈現紀錄存放，而這個 service 沒有。
        case markRequiresRecordStore
        /// `shown` 是曝光不是 deliberate 訊號——它由呈現當下自動寫入。
        case markRequiresDeliberateKind
        case presentationNotFound(PresentationID)
        case rankOutOfRange(rank: Int, presented: Int)
        /// 索引不存在。訊息一律指名 `ltm build`。
        case indexMissing(path: String)
        /// 索引裡的向量與目前的 embedding revision 不同代。
        ///
        /// **拒答而不是降級**：跨 revision 的 cosine 不會報錯，只會安靜地給出
        /// 無意義的距離。一個警告旁邊擺著看起來合理的結果，不會阻止那些結果
        /// 被採用。
        case embeddingRevisionMismatch(indexed: String, runtime: String)
        /// 索引的 layout 版本與這個 binary 不同。
        case layoutVersionMismatch(indexed: Int?, expected: Int)
        /// 索引裡的 anchor 是用另一條 source 規則算的。
        ///
        /// **拒絕而非重新詮釋**：指紋不帶產生它的規則，把舊值拿去跟新規則比對，
        /// 要嘛解析到錯的 turn、要嘛報 orphan，兩者都與正確行為分不出來。
        case anchorSourceRuleMismatch(indexed: String, expected: String)
        /// 無法決定查詢範圍，而且沒有明示要跨 project。
        case ambiguousScope(detail: String)
        /// 側車檔的向量筆數與索引宣稱的不符。
        case vectorSidecarMismatch(declared: Int, found: Int)
        /// 某個要寫入的根落在語料裡。
        case rootInsideCorpus(path: String)

        public var description: String {
            switch self {
            case .markRequiresEventStore, .markRequiresRecordStore:
                return """
                    這條路徑沒有事件／呈現紀錄存放。
                    `ltm mark` 要記的是互動，而互動要記在某個地方——請確認 memory root 可用。
                    """
            case .markRequiresDeliberateKind:
                return """
                    `shown` 是曝光不是 deliberate 訊號，它由呈現當下自動寫入。
                    可記的是：--opened / --cited / --pinned / --dismissed。
                    """
            case .presentationNotFound(let id):
                return """
                    找不到呈現紀錄：\(id)
                    只有 `--compare` 的查詢會寫呈現紀錄，而 id 印在它的 footer 上。
                    （`--record` 只寫 shown 事件、不寫紀錄——名次要翻回 anchor 需要那份紀錄。）
                    """
            case .rankOutOfRange(let rank, let presented):
                return "名次 \(rank) 超出範圍——那次呈現有 \(presented) 筆（名次由 1 起算）。"
            case .indexMissing(let path):
                return """
                    索引不存在（\(path)）。先跑 `ltm build`。
                    首次建索引要掃過整份語料並算 embedding，會跑一段時間；之後每次查詢
                    會自動併入新內容，不必再手動跑。
                    """
            case .embeddingRevisionMismatch(let indexed, let runtime):
                return """
                    索引的 embedding revision 與目前的執行環境不同代
                      索引：\(indexed)
                      目前：\(runtime)
                    跨 revision 的向量距離沒有意義，所以不回答。請跑 `ltm build --full` 重建。
                    """
            case .layoutVersionMismatch(let indexed, let expected):
                return "索引結構版本不符（索引 \(indexed.map(String.init) ?? "未知")、需要 \(expected)）。請跑 `ltm build --full`。"
            case .anchorSourceRuleMismatch(let indexed, let expected):
                return """
                    索引的 anchor 定址規則與這個版本不同
                      索引：\(indexed)
                      需要：\(expected)
                    舊規則算出的指紋不能拿來跟新規則比對——結果會是「解析到錯的 turn」或
                    「報成 orphan」，而兩者都看不出異常。請跑 `ltm build --full` 重建。
                    """
            case .comparisonRequiresStores:
                return """
                    比較模式需要事件與呈現紀錄的存放，但取不到
                    不能記錄的比較不會執行——一份記不下來的交錯結果與一份記下來的
                    在畫面上完全一樣，照做只會讓這次呈現的證據值安靜歸零。
                    請確認 LTM_MEMORY_ROOT 指到可寫、且不在語料內的位置。
                    """
            case .incompatibleComparisonPair(let a, let b):
                return """
                    \(a) 與 \(b) 無法交錯比較：兩者對擴散激發的要求不同
                    交錯器收單一 projection，而擴散的授權是逐策略的——共用一份必然
                    讓其中一邊看到 spec 沒授權它看的統計。這裡拒絕而不是挑一邊。
                    """
            case .unknownStrategy(let name):
                return "未知策略：\(name)（可用：\(StrategyRegistry.known.joined(separator: "、"))）"
            case .rootInsideCorpus(let path):
                return """
                    這個路徑落在唯讀語料裡：\(path)
                    語料是 source of truth，任何寫入都是 bug。請把 LTM_DERIVED_ROOT /
                    LTM_MEMORY_ROOT 指到語料之外的位置。
                    """
            case .vectorSidecarMismatch(let declared, let found):
                return """
                    向量側車檔與索引不一致（索引宣稱 \(declared) 筆、檔案有 \(found) 筆）
                    少一路向量通道的結果看起來完全正常，所以這裡拒答而不是降級。
                    請跑 `ltm build --full` 重建。
                    """
            case .ambiguousScope(let detail):
                return """
                    無法決定查詢範圍：\(detail)
                    CLI 請用 `--project <名稱>` 指定，或 `--all-projects` 明示跨全部 project；
                    MCP 請帶 `all_projects: true`。
                    """
            }
        }
        /// 指名了一個不存在的策略識別碼。
        ///
        /// **不退回預設值**：靜默改用 archival 會讓一個打錯的名字看起來像成功
        /// 執行了使用者要的策略。
        case unknownStrategy(name: String)
        /// 要求比較模式，但沒有地方可以記錄它。
        ///
        /// **不能記錄的比較不執行。** 交錯呈現的價值全部來自事後計分，而計分要
        /// 的是「這次呈現的哪一個位置由誰貢獻」——紀錄掉了，使用者看到的一份
        /// 交錯結果與一份記錄成功的交錯結果完全無法分辨。照做而不記錄等於安靜
        /// 地把這次呈現的證據值歸零。
        case comparisonRequiresStores
        /// 這一對策略無法共用同一份 projection。
        ///
        /// 交錯器收**一份** projection，而 projection 的形狀由
        /// `appliesSpreadingActivation` 決定（擴散激發的 spec 授權只給
        /// `human-like`，#15 verify）。兩個都會消費歷史、卻對擴散有不同要求的
        /// 策略，任何一份共用的 projection 都會讓其中一邊拿到 spec 沒授權它看的
        /// 統計——而那正是 #15 verify 抓到的那個缺陷。
        ///
        /// **不消費任何訊號的策略（`archival`）不構成要求**：它的契約逐字是
        /// 「不論給它什麼 projection 都產出相同輸出」，所以 `archival` 可以跟
        /// 任何一邊配對。判準沿用 `rerank` 已經在用的那條——一個策略只受它能
        /// 消費的資料的約束。
        case incompatibleComparisonPair(a: String, b: String)
    }

    /// 呈現紀錄的存放。比較模式以外的路徑不碰它。
    private let recordStore: (any PresentationRecordStore)?

    /// 增量併入用的調校參數。
    ///
    /// **注入而不是每次讀 `ProcessInfo`**：測試要能餵值，而讓測試改行程環境會讓
    /// 平行測試互相污染。預設值仍然是環境變數，所以出貨行為不變。
    private let buildTuning: BuildTuning
    /// 解析 `buildTuning` 時被拒絕的環境變數。**不吞掉**——見 `RefreshReport.tuningRejections`。
    private let tuningRejections: [String]

    public init(
        location: DerivedLocation,
        corpusRoot: URL = CorpusLocation.readOnlyRoot,
        embedder: any EmbeddingProvider,
        eventStore: (any EventStore)? = nil,
        anchorKey: AnchorKey,
        recordStore: (any PresentationRecordStore)? = nil,
        buildTuning: BuildTuning? = nil
    ) {
        self.location = location
        self.corpusRoot = corpusRoot
        self.embedder = embedder
        self.eventStore = eventStore
        self.anchorKey = anchorKey
        self.recordStore = recordStore
        // 注入時沒有 rejections 可談（呼叫端自己給了值）；沒注入才解析環境。
        if let buildTuning {
            self.buildTuning = buildTuning
            self.tuningRejections = []
        } else {
            let resolved = BuildTuning.fromEnvironment()
            self.buildTuning = resolved.tuning
            self.tuningRejections = resolved.rejections.map(Self.describe)
        }
    }

    /// 把一個 `BuildTuning.Rejection` 變成一句人話。
    ///
    /// 放在這裡而不是 `Rejection` 上：訊息是呈現層的事，而 `BuildTuning` 活在
    /// 索引層。同一個 rejection 在 `ltm build` 是致命的、在查詢路徑是警告，
    /// 兩邊的措辭本來就不同。
    private static func describe(_ rejection: BuildTuning.Rejection) -> String {
        switch rejection {
        case .notAPositiveInteger(let variable, let value):
            return "\(variable)=\(value) 不是正整數，已忽略"
        case .megabytesOverflow(let variable, let value):
            return "\(variable)=\(value) 換算成 bytes 會溢位，已忽略"
        }
    }

    /// 由 roots 參數化組出 facade。**CLI 與測試共用這一條路徑。**
    ///
    /// 先前有一個只有 production 走的 `standard()`，而 CLI 為了支援環境變數覆寫
    /// 自己另建一條——於是出貨的守衛零測試覆蓋（測試全都注入 stub policy），
    /// 而兩條路徑各自長出自己的 containment 缺陷。一條路徑，兩個呼叫端。
    public static func make(
        corpusRoot: URL,
        derivedRoot: URL,
        embedder: any EmbeddingProvider,
        eventStore: (any EventStore)? = nil,
        anchorKey: AnchorKey,
        recordStore: (any PresentationRecordStore)? = nil,
        memoryRoot: URL? = nil
    ) throws -> LTMService {
        let policy = MemoryCorpusPolicy(corpusRoots: [corpusRoot])
        // **建立任何東西之前**先驗 memory root。`FileEventStore` 事後會拒絕語料內的
        // 路徑，但目錄那時已經建好了——違反不變式 1 的是那個 mkdir，不是 append。
        if let memoryRoot, policy.isInsideReadOnlyCorpus(memoryRoot) {
            throw ServiceError.rootInsideCorpus(path: memoryRoot.path)
        }
        return LTMService(
            location: try DerivedLocation(root: derivedRoot, policy: policy),
            corpusRoot: corpusRoot, embedder: embedder, eventStore: eventStore,
            anchorKey: anchorKey, recordStore: recordStore)
    }

    // MARK: - 建置

    @discardableResult
    /// - Parameter progress: 每批提交後被呼叫（#45）。`nil` = 不回報。
    ///
    ///   由呼叫端決定輸出去哪：CLI 寫 stderr（stdout 的 `--json` 形態是給程式
    ///   讀的），MCP server 不回報（它的 client 讀的是 JSON-RPC，不是終端機）。
    /// - Parameter memoryBudgetBytes: 向量累積的預算。`nil` = 不設限（預設）。
    ///   **沒有預設值是刻意的**——本 repo 沒有任何量測支撐得起一個門檻，憑感覺挑
    ///   一個只是把「OS 決定後果」換成「一個編出來的數字決定後果」。見 #46 與
    ///   `docs/measurements/2026-08-26-build-peak-memory.md`。
    /// - Parameter batchChunkTarget: 批次切點的**下限**，不是上界（見 #47）。
    public func build(
        full: Bool = false, batchChunkTarget: Int = 2_000, memoryBudgetBytes: Int? = nil,
        progress: (@Sendable (BuildProgress) -> Void)? = nil
    ) throws -> BuildReport {
        try IndexBuilder(
            location: location, scanner: CorpusScanner(corpusRoot: corpusRoot, anchorKey: anchorKey),
            embedder: embedder, progress: progress, batchChunkTarget: batchChunkTarget,
            memoryBudgetBytes: memoryBudgetBytes
        ).build(full: full)
    }

    // MARK: - 查詢

    /// 執行查詢。
    ///
    /// - Parameters:
    ///   - strategy: 省略時用 `archival`（不重排）。純檢索順序是檢查工具的誠實
    ///     預設；要看使用歷史的影響是明示的選擇。
    ///   - recordEvents: 是否寫 `shown` 事件。**預設不寫**——開發與檢查用的查詢
    ///     會污染策略比較所依據的使用歷史。
    public func query(
        text: String,
        limit: Int = 20,
        scope: RetrievalEngine.Scope,
        strategy: (any MemoryStrategy)? = nil,
        recordEvents: Bool = false,
        now: Date = Date()
    ) throws -> QueryOutcome {
        try withRetrieval(text: text, limit: limit, scope: scope) { database, scored, refreshed in
            let chosen = strategy ?? ArchivalStrategy()

            // 檢索**已經**以 band-major 順序回傳（`RetrievalEngine.search`），所以
            // 這裡逐筆映射、不重排。
            //
            // 「不重排」是字面的：retrieval spec 的 requirement 寫
            // 「SHALL NOT reorder outside that seam」，而它的 scenario 要求
            // 「the emitted order equals the fused retrieval order」。分層曾經在這裡做
            // ——那就是 seam 之外的重排，即使排序規則本身是對的。
            //
            // 分帶與排帶屬於檢索而不是策略，理由不是美學：`MemoryStrategy` 的前置條件
            // `requireBandsInOrder` 要求候選**到達時**已經分好帶。一個 seam 要求它的
            // 輸入具備某個性質，那個性質就是輸入方的職責。
            let candidates = Self.candidates(from: scored)
            let projection = try makeProjection(database: database, strategy: chosen, now: now)
            let ranked = try chosen.rerank(candidates, with: projection)

            // 這次查詢的呈現識別碼：只在真的會寫事件時才產生——沒有事件檔可寫，
            // 就沒有指標可以指（#15）。同一個值套用到這次查詢的所有 hit 與所有
            // 為它們寫入的 `.shown` 事件，讓兩者可以事後對上。
            let presentation: PresentationID? =
                (recordEvents && eventStore != nil) ? .random() : nil

            let byAnchor = Self.index(scored)
            var hits: [QueryHit] = []
            var unattributable = 0
            for result in ranked {
                guard let source = byAnchor[result.candidate.anchor] else {
                    // **數出來，不要靜默 `continue`**（#13）。丟棄是對的——不變式 3
                    // 不允許回傳沒有指標的命中——但沉默的丟棄讓「排序多出了東西」
                    // 這件事沒有任何人會發現。
                    unattributable += 1
                    continue
                }
                hits.append(
                    Self.hit(
                        from: source, candidate: result.candidate,
                        displacement: result.displacement,
                        history: String(describing: result.reason.history),
                        movement: String(describing: result.reason.movement),
                        presentation: presentation))
            }

            var recorded = 0
            if recordEvents, let eventStore {
                recorded = try record(
                    kind: .shown, anchors: hits.map(\.anchor), policy: chosen.id, store: eventStore,
                    now: now, generation: Self.generation(forIndexStamps: try database.stamps()),
                    presentation: presentation)
            }

            return QueryOutcome(
                hits: hits, strategyID: chosen.id.value, refresh: refreshed,
                eventsRecorded: recorded, unattributableResults: unattributable)
        }
    }

    // MARK: - 比較

    /// 一次交錯比較的結果。
    ///
    /// **沒有 `strategyID`**：交錯呈現沒有「用了哪個策略」這回事，兩個都用了。
    /// 誰貢獻了哪個位置寫在 `record.attribution` 裡，而那份資料是給計分用的，
    /// 不是給看結果的人用的——interleaved evaluation 存在的理由就是不讓看的人
    /// 知道。
    public struct ComparisonOutcome: Sendable {
        public let hits: [QueryHit]
        /// 已落地的呈現紀錄。
        public let record: PresentationRecord
        public let refresh: RefreshReport
        /// 寫了幾筆 `shown` 事件。
        public let eventsRecorded: Int
        /// 交錯清單裡有幾筆對不回指標而被丟棄。
        ///
        /// 與 `QueryOutcome.unattributableResults` 同一個理由與同一個誠實邊界：
        /// 丟棄是對的（不變式 3 不允許回傳沒有指標的命中），**沉默的丟棄不是**。
        /// 這條路徑目前一樣受排列守衛保護，所以預期恆為 0——`compare()` 先前只有
        /// 一個裸的 `continue`，於是「這裡也可能丟東西」在型別上不存在（#13 verify）。
        public let unattributableResults: Int

        public var presentation: PresentationID { record.id }
    }

    /// 用兩個策略排同一份候選，交錯呈現，並把紀錄與事件落地。
    ///
    /// ## 一次檢索，兩份排序
    ///
    /// 候選只取一次，兩個策略排的是**同一份清單**。分兩次檢索會讓兩邊因為與
    /// 策略無關的理由而不同（索引在兩次之間被續讀、向量通道的浮點順序），
    /// 於是報告量到的是檢索變異、卻宣稱量的是策略偏好。
    ///
    /// ## 為什麼記錄不是選項
    ///
    /// 沒有事件存放或紀錄存放時直接拒絕（見 `ServiceError.comparisonRequiresStores`），
    /// 不退化成「照做但不記」——一次沒有落地的比較，它的結果無法被任何東西核對。
    ///
    /// 這裡曾經有一個 `persist: Bool = true` 參數（#36 D1 刪除）。它的 doc 寫著
    /// 「存在只是為了讓測試能檢查『不落地時什麼都不寫』這件事本身」，而
    /// `grep -rn "persist: false"` 全 repo **零命中**——那條測試從來不存在。
    /// 它不是一條沒被記到的測試縫，是一個**以不存在的測試為理由**存在的參數，
    /// 而它提供的正是 spec 明說不提供的組合（「比較必然被記錄」）。
    /// 把它寫進 spec 等於把一句假話升格成契約，所以刪掉。
    ///
    /// ## bootstrap 期會是 null comparison，那不是錯誤
    ///
    /// 沒有任何使用歷史時每個 anchor 的淨強度都是 0，`boundedReorderByStrength`
    /// 的交換條件（嚴格大於）恆為假，兩邊產出逐字相同的順序——交錯器把它標成
    /// null comparison，計分整批略過。這是既有的、被表達出來的狀態，呼叫端不得
    /// 把它當成失敗。
    /// 交錯呈現寫進事件的 `policy` 值。
    ///
    /// **刻意不是 `StrategyRegistry.known` 的成員**：它不命名一個策略，它命名
    /// 「這次呈現沒有單一策略」這件事。spec 把它記成保留值
    /// （`memory-events`，#36 D3），而
    /// `theInterleavedPolicyIsReservedAndNotAStrategy` 釘住它不在 `known` 內
    /// ——否則下一個人會拿它去 `StrategyRegistry.make()` 而靜默得到 `nil`。
    public static let interleavedPolicy = RankingPolicyID.interleaved

    public func compare(
        text: String,
        limit: Int = 20,
        scope: RetrievalEngine.Scope,
        a aID: RankingPolicyID,
        b bID: RankingPolicyID,
        now: Date = Date()
    ) throws -> ComparisonOutcome {
        guard let eventStore, let recordStore else {
            throw ServiceError.comparisonRequiresStores
        }
        // **收識別碼、在這裡組實例。** 呼叫端（CLI、未來的 MCP）只轉述使用者
        // 打的字；策略由誰組出來只有一個答案。
        guard let a = StrategyRegistry.make(aID) else {
            throw ServiceError.unknownStrategy(name: aID.value)
        }
        guard let b = StrategyRegistry.make(bID) else {
            throw ServiceError.unknownStrategy(name: bID.value)
        }
        // 兩個都消費歷史、卻對擴散有不同要求 → 共用 projection 必然餵錯一邊。
        // 不消費訊號的策略不構成要求（見 `incompatibleComparisonPair`）。
        let demands = [a, b].filter { !$0.consumedSignals.isEmpty }
        guard Set(demands.map(\.appliesSpreadingActivation)).count <= 1 else {
            throw ServiceError.incompatibleComparisonPair(a: a.id.value, b: b.id.value)
        }

        return try withRetrieval(text: text, limit: limit, scope: scope) {
            database, scored, refreshed in
            let candidates = Self.candidates(from: scored)
            // projection 的參數由「有要求的那些策略」決定；都沒有要求時就是空的。
            // guard 已保證有要求的策略彼此一致，所以取第一個即代表全體。
            let projection = try makeProjection(
                database: database, readsHistory: !demands.isEmpty,
                spreading: demands.first?.appliesSpreadingActivation ?? false, now: now)

            let generation = Self.generation(forIndexStamps: try database.stamps())
            let interleaving = try InterleavingHarness(generation: generation).present(
                query: text, candidates: candidates, projection: projection,
                a: a, b: b,
                // 起手方由查詢字串決定，而**只有那一位元被留下**：`balanced` 算完
                // 之後字串沒有任何持有者，紀錄裡存的是 `.a`／`.b`。
                startingSide: InterleavingHarness.Side.balanced(seed: text))

            let byAnchor = Self.index(scored)
            var hits: [QueryHit] = []
            var unattributable = 0
            for candidate in interleaving.presented {
                guard let source = byAnchor[candidate.anchor] else {
                    // 與 `query()` 同形（#13）：數出來，不要靜默 `continue`。
                    unattributable += 1
                    continue
                }
                hits.append(
                    Self.hit(
                        from: source, candidate: candidate,
                        // 交錯之後「位移」沒有定義：一筆結果在交錯清單裡的位置是
                        // 兩份排序輪流取用的產物，不是任何一個策略把它移到那裡。
                        // 回報 0 而不是編一個數字。
                        displacement: 0,
                        history: "interleaved", movement: "interleaved",
                        presentation: interleaving.record.id))
            }

            // **零候選不留紀錄**（#36 階段 3）。沒有候選就沒有位置 0，也就沒有
            // starting side——把這種列計進 `startingSides` 的分母，等於用沒有起始邊
            // 的列去稀釋交錯平衡的統計。這不是拒絕（比較本身沒有失敗），是
            // 「沒有東西被呈現，所以沒有呈現紀錄」。
            var recorded = 0
            if !hits.isEmpty {
                // **紀錄先落地，事件後落地。** 反過來的話，崩在兩者之間會留下一批
                // 指向不存在紀錄的事件——計分端會把它們算成
                // `presentationNotTracked` 而報告照常產出，也就是 #33 要修的
                // 那個症狀的另一種來源。
                try recordStore.append(interleaving.record)
                recorded = try record(
                    kind: .shown, anchors: hits.map(\.anchor),
                    // 交錯呈現的 `shown` 事件**不歸屬任何一邊**——歸屬寫在紀錄的
                    // `attribution` 裡，逐位置各不相同，而事件的 `policy` 是單一值。
                    // 用交錯器自己的識別碼標記它們的來源。
                    //
                    // `"interleaved"` **刻意不是** `StrategyRegistry.known` 的成員：
                    // 它不命名一個策略，它命名「沒有單一策略」這件事。spec 把它
                    // 記成保留值（`memory-events`，#36 D3），而一條測試釘住它不在
                    // `known` 內——否則下一個人會拿它去 `make()` 而得到 `nil`。
                    policy: Self.interleavedPolicy,
                    store: eventStore, now: now, generation: generation,
                    presentation: interleaving.record.id)
            }

            return ComparisonOutcome(
                hits: hits, record: interleaving.record, refresh: refreshed,
                eventsRecorded: recorded, unattributableResults: unattributable)
        }
    }

    /// 世代識別碼：**索引這一代的身分**，不是當下的時間。
    ///
    /// ## 為什麼不是時間（#33 verify，requirements + devil's advocate 各自抓到）
    ///
    /// 先前是 `g-<當下秒數>`。那有兩個後果，第二個是致命的：
    ///
    /// 1. 它與 spec 的定義不符。`strategy-comparison` spec 逐字寫「the generation
    ///    identifier of **the index build**」，而秒數與索引建置無關。
    /// 2. **它讓這整套機制的目的自我否定。** `ComparisonScorer` 對「事件自報的
    ///    generation ≠ 紀錄的 generation」是 `throw`，而且那道 guard 排在
    ///    null-comparison 檢查**之前**。所以任何在呈現之後才寫入的互動事件——
    ///    也就是交錯比較存在的全部理由——必然帶不同的秒數，整份報告一個數字都
    ///    產不出來。當時測不到，是因為所有測試的事件與紀錄都在同一次 `compare`
    ///    呼叫裡用同一個 `now` 寫成。
    ///
    /// 另外它讓 spec 的「跨 generation 要分開報」退化成廢話：每次查詢自成一代，
    /// 報告永遠宣稱 spans generations、每格 n=1。
    ///
    /// ## 現在的定義
    ///
    /// 由索引的三個戳記（layout 版本、embedding revision、anchor 定址規則）雜湊
    /// 而來。這三者**恰好就是「結果可不可比」的判準**——本 facade 在查詢前置段
    /// 對它們三個各有一道拒答守衛，理由都是「不同代的東西放在一起比沒有意義」。
    /// 所以同一份索引上的所有呈現共用一代；索引換代（換模型、改 layout、改定址
    /// 規則）就換一代，而那正是 spec 要求分開報的那條線。
    ///
    /// 用雜湊而不是把三個值串起來：`embedding_revision` 含 `#`，而
    /// `OpaqueIdentifier` 只收 ASCII 英數與 `._-`。
    private static func generation(forIndexStamps stamps: IndexDatabase.Stamps) -> GenerationID {
        let material = [
            stamps.layoutVersion.map(String.init) ?? "-",
            stamps.embeddingRevision ?? "-",
            stamps.anchorSourceRule ?? "-",
        ].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return GenerationID("g-" + hex.prefix(16))
    }

    /// 開索引、驗版本、增量續讀、檢索——**`query` 與 `compare` 共用的前置段**。
    ///
    /// 抽成一個閉包收束的函式，而不是讓兩條路徑各寫一份：這一段裡的每一個
    /// 拒答條件（layout 版本、embedding revision、anchor 定址規則、側車筆數）
    /// 都是某次 verify 抓出來的，而複製一份的漂移方向永遠是「新的那份少了
    /// 其中一條」。`defer { database.close() }` 也因此只有一個地方寫。
    private func withRetrieval<R>(
        text: String, limit: Int, scope: RetrievalEngine.Scope,
        body: (IndexDatabase, [ScoredChunk], RefreshReport) throws -> R
    ) throws -> R {
        guard FileManager.default.fileExists(atPath: location.databaseURL.path) else {
            throw ServiceError.indexMissing(path: location.databaseURL.path)
        }
        let database = try IndexDatabase(path: location.databaseURL.path)
        defer { database.close() }

        let stamps = try database.stamps()
        guard stamps.layoutVersion == IndexDatabase.layoutVersion else {
            throw ServiceError.layoutVersionMismatch(
                indexed: stamps.layoutVersion, expected: IndexDatabase.layoutVersion)
        }
        guard let indexedRevision = stamps.embeddingRevision,
            indexedRevision == embedder.revision
        else {
            throw ServiceError.embeddingRevisionMismatch(
                indexed: stamps.embeddingRevision ?? "(無)", runtime: embedder.revision)
        }

        let indexedRule = stamps.anchorSourceRule ?? "(無)"
        guard indexedRule == IndexDatabase.anchorSourceRule else {
            throw ServiceError.anchorSourceRuleMismatch(
                indexed: indexedRule, expected: IndexDatabase.anchorSourceRule)
        }

        // 查詢時的 staleness 檢查：語料前進了就先把尾巴讀進來再回答。
        // 這裡**只做增量**——需要整份重建的情況（版本／revision 不符）在上面
        // 已經拒答了，不會走到這裡。
        let refreshed = try refreshIncrementally()

        let dimension = try database.meta("vector_dimension").flatMap(Int.init) ?? embedder.dimension
        let declaredVectors = try database.meta("vector_count").flatMap(Int.init) ?? 0
        // 側車與索引宣稱的筆數必須對得上。
        //
        // 先前這裡是 `try? VectorSidecar.open(...)`，於是側車遺失或被截斷時 `vectors`
        // 變成 nil、`vectorRanking` 直接回空陣列——檢索**靜默降級成 lexical-only**。
        // 那與這份 code 自己在別處的宣示直接衝突：tokenizer 不可用時大聲中止，
        // 向量不可用時卻無聲。少一路通道的結果看起來完全正常，這正是不能靜默的理由。
        var vectors: VectorSidecar?
        if declaredVectors > 0 {
            guard let opened = try? VectorSidecar.open(url: location.vectorsURL, dimension: dimension),
                opened.count == declaredVectors
            else {
                throw ServiceError.vectorSidecarMismatch(
                    declared: declaredVectors,
                    found: (try? VectorSidecar.open(url: location.vectorsURL, dimension: dimension))?
                        .count ?? 0)
            }
            vectors = opened
        }
        let engine = RetrievalEngine(database: database, vectors: vectors, embedder: embedder)
        let scored = try engine.search(query: text, limit: limit, scope: scope)

        return try body(database, scored, refreshed)
    }

    /// 檢索結果 → seam 的候選。**`query` 與 `compare` 共用**。
    private static func candidates(from scored: [ScoredChunk]) -> [Candidate] {
        scored.map {
            Candidate(
                anchor: $0.anchor, baseScore: $0.fusedScore,
                band: RelevanceBand(rank: $0.band))
        }
    }

    private static func index(_ scored: [ScoredChunk]) -> [Anchor: ScoredChunk] {
        Dictionary(scored.map { ($0.anchor, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 檢索結果 + 排序結果 → 回傳給呼叫端的一筆命中。**兩條路徑共用**。
    private static func hit(
        from source: ScoredChunk, candidate: Candidate, displacement: Int,
        history: String, movement: String, presentation: PresentationID?
    ) -> QueryHit {
        QueryHit(
            project: source.project,
            sessionSources: source.sessionSources, uuid: source.uuid,
            timestamp: source.timestamp, snippet: source.text,
            score: candidate.baseScore, band: candidate.band.rank,
            displacement: displacement,
            historyDescription: history,
            movementDescription: movement,
            anchor: candidate.anchor,
            channels: source.channels.map(\.rawValue).sorted(),
            presentation: presentation)
    }

    /// 把語料的新增內容併進索引（查詢路徑上的增量續讀）。
    ///
    /// 回傳有新內容的來源檔數。
    ///
    /// ## 為什麼是委派而不是自己寫一份
    ///
    /// 這裡曾經有一份**平行的**寫入實作：自己算向量、自己配 row、自己 append
    /// 側車、自己覆寫 state。它與 `IndexBuilder` 做同一件事，卻是兩份程式碼——
    /// 於是修好其中一份不會修好另一份，而且不會有任何訊號。
    ///
    /// 實際發生過：`IndexBuilder` 的寫入順序被改成「側車先落地並 fsync、之後
    /// 才提交指向它的指標」，這一份沒有跟著改，仍然是先提交 `vector_count` 再
    /// append。崩在兩者之間會留下「DB 宣稱 N 個向量、檔案只有 N−k 個」，而
    /// 查詢路徑的側車核對會就此拒答，直到使用者跑 `ltm build --full`。這一份
    /// 也沒有 `truncateSidecar`，所以殘留的多餘 bytes 永遠不會被清掉。
    ///
    /// 兩個寫者就是兩份會漂移的規格。刪掉一份是唯一不會再漂移的修法。
    ///
    /// ## 兩處刻意的差異
    ///
    /// - **拿不到鎖不失敗**：查詢仍可用既有索引回答，只是這一輪不併入新內容。
    ///   `build` 相反——它的工作就是寫入，拿不到鎖必須明確失敗。
    /// - **不可能觸發整份重建**：`query` 在呼叫這裡之前已經檢查過 layout 版本、
    ///   embedding revision 與 anchor 定址規則，三者不符都已拒答。所以
    ///   `build()` 內的 `stampsMismatch` 分支在這條路徑上到不了。
    private func refreshIncrementally() throws -> RefreshReport {
        // **調校參數必須到得了這條路。** 先前這裡兩個參數都沒傳，而這條路正是
        // 增量併入實際發生的地方（每一次查詢前跑一次，含長駐的 `ltm mcp`）——
        // 所以 `--memory-budget-mb` 的環境變數形式從來沒在它最需要生效的地方
        // 生效過。#46 R2 verify（codex lens）。
        //
        // 壞值在這裡**忽略並繼續**，不拒答：一個環境變數的 typo 可能是好幾天前
        // 設的，拿它讓查詢失敗是過度反應。`ltm build` 的處置相反（具名拒絕），
        // 而那個差異寫在 `BuildTuning.Rejection` 的註解裡。
        let builder = IndexBuilder(
            location: location, scanner: CorpusScanner(corpusRoot: corpusRoot, anchorKey: anchorKey),
            embedder: embedder, batchChunkTarget: buildTuning.batchChunkTarget,
            memoryBudgetBytes: buildTuning.memoryBudgetBytes)
        do {
            // `refusingFullRebuild`：這條路徑上「整份重建」永遠是錯的答案——它會
            // 在查詢持有連線時刪掉 DB 與側車。先前這是註解裡的推理，現在是前置條件。
            let report = try builder.build(refusingFullRebuild: true)
            return RefreshReport(
                sourcesRefreshed: report.sourcesRefreshed,
                sourcesUnreadable: report.sourcesUnreadable,
                sourcesInvalidated: report.sourcesInvalidated,
                skipped: report.skipped,
                tuningRejections: tuningRejections)
        } catch IndexBuilder.BuildError.lockHeld {
            // 不拒答：既有索引仍然有效，為了「有人在建置」而讓查詢失敗是過度反應。
            // 但也不靜默：把它記進 report，由呈現層說出來。
            return RefreshReport(
                sourcesRefreshed: 0, sourcesUnreadable: [], sourcesInvalidated: 0,
                skipped: SkipTally(), mergeDeferredForConcurrentBuild: true,
                tuningRejections: tuningRejections)
        }
    }

    /// 把事件投影成策略要看的統計。
    ///
    /// 策略宣告它消費哪些事件種類；不消費任何事件的策略（`archival`）連讀都不讀
    /// ——省下的不只是時間，更是「它真的沒看使用歷史」這件事在程式碼上看得見。
    private func makeProjection(
        database: IndexDatabase, strategy: any MemoryStrategy, now: Date
    ) throws -> Projection {
        try makeProjection(
            database: database, readsHistory: !strategy.consumedSignals.isEmpty,
            spreading: strategy.appliesSpreadingActivation, now: now)
    }

    /// 上面那個的實作。參數是**兩個布林**而不是一個策略，因為比較模式要的
    /// projection 是由一對策略共同決定的，而不是任何單一策略的屬性——先前只有
    /// 單策略版本，比較模式若自己再算一次就是同一件事的第二個寫者。
    private func makeProjection(
        database: IndexDatabase, readsHistory: Bool, spreading: Bool, now: Date
    ) throws -> Projection {
        guard readsHistory, let eventStore else {
            // 不消費任何事件的策略（archival）連讀都不讀——省下的不只是時間，
            // 更是「它真的沒看使用歷史」這件事在程式碼上看得見。
            return project([], at: now, resolvedBy: PreloadedCorpusReader(turns: [:]), key: anchorKey)
        }
        let events = try eventStore.events(from: .distantPast, to: now)
        let reader = try PreloadedCorpusReader.load(anchors: events.map(\.anchor), from: database)
        // 擴散只授權給宣告 `appliesSpreadingActivation` 的策略（目前只有
        // human-like）。不套用的策略拿 `spreadingActivationFactor: 0`——沿用
        // `Projection.swift` 既有文件語意「0 等於關閉擴散」，不是另開一條路徑。
        // 先前這裡永遠用 `.default`（非零係數），`conservative` 因此意外吃到
        // 擴散（#15 verify HIGH finding；add-spreading-activation-fixes Decision 2）。
        let parameters =
            spreading
            ? ProjectionParameters.default
            : ProjectionParameters(spreadingActivationFactor: 0)
        return project(events, at: now, resolvedBy: reader, key: anchorKey, parameters: parameters)
    }

    /// 寫入一批事件。
    ///
    /// `presentation` 預設 nil：呼叫端沒有群組可指時（或未來其他不代表單一
    /// 呈現的批次寫入）維持原行為。`query()` 是目前唯一會傳非 nil 值的呼叫點
    /// ——見該處生成 `PresentationID` 的理由（#15）。
    /// `generation` 由呼叫端傳入（索引戳記導出）——**不在這裡自己算**：紀錄與
    /// 事件必須帶同一個值，而只有呼叫端同時握著兩者。
    /// 對一次呈現裡的某個名次記一則 deliberate 事件（#35，經 #24 落地）。
    ///
    /// ## 為什麼這個方法非有不可
    ///
    /// 在它之前，**全 repo 只有一個事件寫入端，而它固定寫 `shown`**。於是：
    ///
    /// - `Projection` 的淨強度只由 deliberate 事件推動（`shown` 被明確排除、
    ///   只計 impressions），所以每個 anchor 的淨強度恆為 0。
    /// - 擴散由 `opened`／`cited`／`pinned` 驅動，所以那個迴圈**一次都沒跑過**。
    /// - 交錯比較的每一次都是 null comparison，跑一萬次也一樣。
    ///
    /// 缺的從來不是時間，是一個把互動記成 deliberate 事件的產生端。
    ///
    /// ## 為什麼是「呈現 + 名次」而不是「anchor」
    ///
    /// 呼叫端（人或模型）手上有的是一份輸出，而輸出上有名次。要它自己把名次翻回
    /// anchor，等於把「哪一筆是第 3 名」這個知識複製到呼叫端——而那份知識已經
    /// 在紀錄裡了。名次翻譯留在這裡，呼叫端只說「第 3 筆我開了」。
    ///
    /// - Parameter rank: **1-based**，與輸出上印的編號一致。用 0-based 會讓
    ///   「第 3 筆」與 `rank: 3` 指到不同的東西，而那不會有錯誤訊息。
    @discardableResult
    public func mark(
        presentation: PresentationID, rank: Int, kind: EventKind, now: Date = Date()
    ) throws -> Anchor {
        guard kind != .shown else { throw ServiceError.markRequiresDeliberateKind }
        guard let eventStore else { throw ServiceError.markRequiresEventStore }
        guard let recordStore else { throw ServiceError.markRequiresRecordStore }

        guard let record = try recordStore.allRecords().first(where: { $0.id == presentation })
        else { throw ServiceError.presentationNotFound(presentation) }

        let presented = record.attribution.map(\.anchor)
        guard rank >= 1, rank <= presented.count else {
            throw ServiceError.rankOutOfRange(rank: rank, presented: presented.count)
        }
        let anchor = presented[rank - 1]

        // policy 用**紀錄自己的歸屬**，不是呼叫端說的——呼叫端不知道那個位置是
        // 哪個策略貢獻的，而那正是比較實驗要問的事。null comparison 沒有歸屬，
        // 那時用保留值（`interleaved`），與呈現當下寫 `shown` 的那一則一致。
        let policy = record.credit(for: anchor) ?? .interleaved

        try eventStore.append(
            Event(
                kind: kind, anchor: anchor, timestamp: now, generation: record.generation,
                policy: policy, noteRef: nil, presentation: presentation))
        return anchor
    }

    private func record(
        kind: EventKind, anchors: [Anchor], policy: RankingPolicyID, store: any EventStore,
        now: Date, generation: GenerationID, presentation: PresentationID? = nil
    ) throws -> Int {
        var written = 0
        for anchor in anchors {
            try store.append(
                Event(
                    kind: kind, anchor: anchor, timestamp: now, generation: generation,
                    policy: policy, noteRef: nil, presentation: presentation))
            written += 1
        }
        return written
    }
}
