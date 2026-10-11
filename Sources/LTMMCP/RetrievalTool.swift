import Foundation
import LTMCore
import LTMIndex
import LTMService

/// 把檢索暴露成 MCP tool（#24）。
///
/// ## 三條不變式在這一層的樣子
///
/// 1. **語料唯讀**——這一層只讀。寫入只發生在記憶層，而那走既有的守衛。
/// 2. **索引純衍生**——這一層不建索引，只查。查詢前的增量併入由 facade 負責。
/// 3. **回傳一律附指標**——每一筆命中都帶 `(project, sessions, uuid, timestamp)`。
///    `sessions` 是**集合**，且**不得挑一個當代表**（#25）。
///
/// ## 為什麼輸出是文字而不是結構化 JSON
///
/// MCP 的 `content` 可以是多種型別，而這裡刻意只用 `text`：讀它的是一個模型，
/// 而**指標必須和內容在同一段文字裡**才不會被拆散。一個把指標放進 metadata
/// 欄位的設計，會讓「檢索負責導航」在模型只讀 content 時失效。
public enum RetrievalTool {
    /// 與 CLI 共用同一句標記（#4）。
    ///
    /// 兩處各寫一份會漂移，而漂移的方向是「其中一個介面不再標記」。
    /// 措辭的 source of truth 在 LTMService 的 `RetrievalBanner`（與 `--format recall` 共用）。
    public static let untrustedBanner = RetrievalBanner.untrusted
    public static let authorityRule = RetrievalBanner.authorityRule

    /// MCP 查詢前併入的預設上限（秒，#71）。**這是起始值，不是量測值**：#76 定的 MCP 端到端預算是 30 秒，
    /// 要扣掉檢索本身的時間，而那段在今天的索引規模上沒有量過——20 秒留給併入、約 10 秒留給檢索是猜的。
    /// 上限只在批次開頭檢查，所以它不是端到端的上界。要改它，先照 `docs/latency-budget.md` 量。
    public static let defaultRefreshBudgetSeconds = 20

    /// 由環境決定 MCP 查詢前併入的上限（server 啟動時讀一次，#71）。
    ///
    /// `LTM_MCP_REFRESH_SECONDS` 是正整數就用它；沒設用預設；其他值（含空字串、0）也用預設，並回傳一則
    /// 指名變數與值的拒絕，讓這個 server 的每個回應都帶著它。不讓呼叫失敗：幾天前設錯的一個環境變數不該讓
    /// 工具壞掉，`BuildTuning` 對查詢路徑也是同一個取捨。
    public static func resolveRefreshBudget(environment: [String: String]) -> (seconds: Int, rejections: [String]) {
        // 字面鍵：`BaselineQueryFileTests` 只認「以字串字面量當鍵」的讀法，收集 ltm 讀的環境變數、與量測腳本的白名單對帳。
        guard let raw = environment["LTM_MCP_REFRESH_SECONDS"] else { return (defaultRefreshBudgetSeconds, []) }
        switch BuildTuning.parsePositive(raw, variable: "LTM_MCP_REFRESH_SECONDS") {
        case .success(let seconds):
            return (seconds, [])
        case .failure(let rejection):
            return (
                defaultRefreshBudgetSeconds,
                [LTMService.describe(rejection) + "（MCP 查詢前併入改用預設的 \(defaultRefreshBudgetSeconds) 秒）"]
            )
        }
    }

    /// - Parameters:
    ///   - refreshBudget: 查詢前併入的上限（秒）。**刻意沒有預設值**：先前這一層呼叫 `service.query` 時根本
    ///     沒傳上限，每次查詢都要併完整段落後的語料才回答（#71 的根因）。`nil` 是「不設限」，要明寫。
    ///   - rejections: server 啟動時解析上限被拒絕的說明，每個回應都帶。
    public static func make(
        service: @escaping @Sendable () throws -> LTMService, refreshBudget: TimeInterval?,
        rejections: [String] = []
    ) -> MCPTool {
        MCPTool(
            name: "ltm_query",
            description: """
                查詢這台機器上過去的 Claude Code 對話。回傳帶 (project, sessions, \
                uuid, timestamp) 指標的命中，讓你能回去讀原文。預設只搜當前工作\
                目錄對應的 project。
                """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "要查什麼"],
                    "limit": [
                        "type": "integer",
                        "description": "最多回幾筆（預設 10）",
                    ],
                    "all_projects": [
                        "type": "boolean",
                        "description": """
                            跨全部 project 搜尋。**預設 false**——跨 project 檢索\
                            可能把某個專案的內容召回到另一個專案的 session 裡。
                            """,
                    ],
                ],
                "required": ["query"],
            ]
        ) { arguments in
            guard let query = arguments["query"] as? String, !query.isEmpty else {
                throw ToolError.missingQuery
            }
            let limit = (arguments["limit"] as? Int) ?? 10
            let allProjects = (arguments["all_projects"] as? Bool) ?? false

            let service = try service()
            let scope: RetrievalEngine.Scope =
                allProjects ? .allProjects : try currentProjectScope()
            let outcome = try service.query(text: query, limit: limit, scope: scope, refreshBudget: refreshBudget)
            return render(outcome, startupRejections: rejections)
        }
    }

    /// 由工作目錄推導 project（#4：預設只搜當前 project）。
    ///
    /// MCP server 由 client 啟動，工作目錄就是使用者當下的專案目錄——與 CLI 的
    /// 推導同一個依據。推不出來時**拋錯而不是擴大成全語料**。
    static func currentProjectScope() throws -> RetrievalEngine.Scope {
        let cwd = FileManager.default.currentDirectoryPath
        guard let project = LTMService.projectName(forWorkingDirectory: cwd) else {
            throw ToolError.ambiguousScope(cwd: cwd)
        }
        return .project(project)
    }

    static func render(_ outcome: QueryOutcome, startupRejections: [String] = []) -> String {
        // **兩個門面消費同一個旗標**（#51）：CLI 早就把「本輪未併入新內容」說出來
        // 了，而 MCP 的讀者是模型——它更沒有辦法從答案本身看出「使用者剛講的那段
        // 可能不在這次結果裡」。沒有命中時也要說：那個「沒有命中」可能正是因為
        // 新內容還沒併入。
        var warnings: [String] = []
        if outcome.refresh.mergeDeferredForConcurrentBuild {
            warnings.append("⚠ \(AuditMessage.mergeDeferredLine)")
        }
        // #71：有界併入沒併完時說出來，有沒有命中都說——「沒有命中」可能正是因為那些來源還沒併入。
        if outcome.refresh.unmergedSources > 0 {
            warnings.append("⚠ \(ShortfallMessage.line(unmergedSources: outcome.refresh.unmergedSources))")
        }
        // #54：「沒有命中」可能因為來源根本讀不到——模型讀者無法從答案本身看出。
        // 報**數量**不列路徑（路徑清單對模型是雜訊；明細在 `ltm build` 的 stderr）。
        // `skipped`（SkipTally）**刻意不進來**：那是掃描統計不是警告——跳過行在
        // 實際語料中經常出現（一次量測見 46%，樣本是使用者自己的語料、非產品
        // 不變量；空語料或全可索引的一輪它就是零），放進每次回應通常只是
        // 無行動性的噪音。這個排除由 `skippedTallyDoesNotAffectTheResponse` 釘住。
        if !outcome.refresh.sourcesUnreadable.isEmpty {
            warnings.append(
                "⚠ \(outcome.refresh.sourcesUnreadable.count) 個來源檔讀不到，"
                    + "本輪未更新（若有既有索引則保留）——明細見 `ltm build`")
        }
        for rejection in outcome.refresh.tuningRejections + startupRejections {
            warnings.append("⚠ \(rejection)")
        }
        // #61 R2-4：查詢路徑不補跑欠著的稽核；模型讀者是使用者唯一可能聽到這件事的管道。
        if outcome.refresh.auditOwed {
            warnings.append("⚠ \(AuditMessage.owedLine(mergeDeferred: outcome.refresh.mergeDeferredForConcurrentBuild))")
        }
        guard !outcome.hits.isEmpty else {
            return (warnings + ["（沒有命中）"]).joined(separator: "\n")
        }
        let formatter = ISO8601DateFormatter()
        var lines = warnings + [untrustedBanner, authorityRule, ""]
        for (index, hit) in outcome.hits.enumerated() {
            // `project` 是 POSIX 目錄名、`sessionSources` 來自檔名——兩者換行合法。
            // snippet 早就壓平了，而這兩個沒有：banner 之下的 corpus 側通道
            // （batch verify，DA 收窄 S1 時抓到）。同一條規則：外來字串進單行
            // 輸出前壓平。
            let project = hit.project.replacingOccurrences(of: "\n", with: " ")
            lines.append("\(index + 1). [\(project)] \(formatter.string(from: hit.timestamp))")
            lines.append("   \(hit.snippet.replacingOccurrences(of: "\n", with: " "))")
            // **指標與內容在同一段文字裡**，而 `sessions` 是集合（#25）：不挑代表。
            let label = hit.sessionSources.count > 1 ? "sessions" : "session"
            let sources = hit.sessionSources.joined(separator: ", ")
                .replacingOccurrences(of: "\n", with: " ")
            lines.append(
                "   ↳ \(label) \(sources)  turn \(hit.uuid)")
        }
        return lines.joined(separator: "\n")
    }

    public enum ToolError: Error, CustomStringConvertible {
        case missingQuery
        case ambiguousScope(cwd: String)

        public var description: String {
            switch self {
            case .missingQuery:
                return "缺少 query 參數"
            case .ambiguousScope(let cwd):
                return """
                    工作目錄（\(cwd)）對應不到語料裡的任何 project。\
                    要跨全部 project 搜尋請明示 all_projects: true。
                    """
            }
        }
    }
}
