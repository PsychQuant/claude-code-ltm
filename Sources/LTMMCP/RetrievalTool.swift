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

    public static func make(service: @escaping @Sendable () throws -> LTMService) -> MCPTool {
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
            let outcome = try service.query(text: query, limit: limit, scope: scope)
            return render(outcome)
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

    static func render(_ outcome: QueryOutcome) -> String {
        // **兩個門面消費同一個旗標**（#51）：CLI 早就把「本輪未併入新內容」說出來
        // 了，而 MCP 的讀者是模型——它更沒有辦法從答案本身看出「使用者剛講的那段
        // 可能不在這次結果裡」。沒有命中時也要說：那個「沒有命中」可能正是因為
        // 新內容還沒併入。
        var warnings: [String] = []
        if outcome.refresh.mergeDeferredForConcurrentBuild {
            warnings.append("⚠ 有另一個 `ltm build` 正在跑，本輪未併入新內容（答案來自既有索引）")
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
        for rejection in outcome.refresh.tuningRejections {
            warnings.append("⚠ \(rejection)")
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
