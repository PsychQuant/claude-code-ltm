import Foundation
import LTMCore
import LTMIndex
import LTMMemory
import LTMQuery
import LTMService

/// 兩個子命令共用的組裝：embedder、facade、範圍解析。
enum CommandSupport {
    /// 把語料根與 embedding provider 接起來。
    ///
    /// embedding assets 不可用時**明確失敗**：少了向量通道的檢索仍然「能跑」，
    /// 只是 recall 掉一路而且看不出來。
    static func makeService(recordEvents: Bool) throws -> LTMService {
        let embedder = try ContextualEmbeddingProvider()
        let eventStore: (any EventStore)? =
            recordEvents ? try FileEventStore(url: memoryEventsURL()) : nil
        // 路徑可由環境變數覆寫。這**不是**為了測試才加的後門：多語料（另一台
        // 機器的備份、匯出的歷史）本來就需要它，而端到端測試需要的正是同一個
        // 能力——一個只能指向真實 `~/.claude/projects` 的 CLI，它的行為只能在
        // 那份會每天變動的語料上驗證，那不是可重現的驗證。
        //
        // 覆寫**不會**放寬任何守衛：衍生根仍然要通過 `MemoryCorpusPolicy`
        // （不得落在語料內），語料仍然只讀不寫。
        let corpusRoot =
            ProcessInfo.processInfo.environment["LTM_CORPUS_ROOT"].map {
                URL(fileURLWithPath: $0)
            } ?? CorpusLocation.readOnlyRoot
        let derivedRoot =
            ProcessInfo.processInfo.environment["LTM_DERIVED_ROOT"].map {
                URL(fileURLWithPath: $0)
            } ?? DerivedLocation.defaultRoot
        return LTMService(
            location: try DerivedLocation(root: derivedRoot, policy: MemoryCorpusPolicy()),
            corpusRoot: corpusRoot, embedder: embedder, eventStore: eventStore)
    }

    /// 使用歷史的存放位置：`~/.claude-ltm/memory/events.jsonl`。
    ///
    /// 與衍生索引分開（`derived/`）是刻意的：索引可以隨時刪掉重建，記憶層不行
    /// ——它記的是 jsonl 記不得的事（CLAUDE.md 的例外條款）。
    static func memoryEventsURL() throws -> URL {
        let base =
            ProcessInfo.processInfo.environment["LTM_MEMORY_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-ltm")
        let root = base.appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("events.jsonl")
    }

    /// 由工作目錄推出 project 名。
    ///
    /// Claude Code 把專案路徑的 `/` 換成 `-` 當目錄名。這裡**產生候選之後確認
    /// 目錄真的存在**，而不是相信轉換規則——規則是觀察來的，不是契約，猜錯時
    /// 「查不到東西」與「查錯專案」都不會有錯誤訊息。
    static func projectForWorkingDirectory(corpusRoot: URL) -> String? {
        let cwd = FileManager.default.currentDirectoryPath
        let candidate = cwd.replacingOccurrences(of: "/", with: "-")
        var isDirectory: ObjCBool = false
        let path = corpusRoot.appendingPathComponent(candidate).path
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return candidate
    }

    /// 解析查詢範圍。無法決定時**要求明示**，不擴大成全語料。
    static func resolveScope(arguments: Arguments, corpusRoot: URL) throws
        -> RetrievalEngine.Scope
    {
        if arguments.has("all-projects") { return .allProjects }
        if let named = arguments.value("project") { return .project(named) }
        if let inferred = projectForWorkingDirectory(corpusRoot: corpusRoot) {
            return .project(inferred)
        }
        throw LTMService.ServiceError.ambiguousScope(
            detail: "工作目錄對應不到語料裡的任何 project")
    }

    static func strategy(named name: String?) throws -> (any MemoryStrategy)? {
        switch name {
        case nil, "archival": return nil  // nil = facade 用預設的 archival
        case "human-like": return HumanLikeStrategy()
        case "conservative": return ConservativeStrategy()
        case .some(let other):
            Output.error("未知策略：\(other)（可用：archival、human-like、conservative）")
            throw LTMService.ServiceError.ambiguousScope(detail: "unknown strategy \(other)")
        }
    }
}

// MARK: - build

enum BuildCommand {
    static let usage = """
        用法：ltm build [--full]

        選項：
          --full    捨棄既有索引，從零重建
          -h, --help
        """

    static func run(arguments raw: [String]) -> Int32 {
        let arguments = Arguments(raw, valueOptions: [])
        if arguments.has("help") || arguments.has("h") {
            print(usage)
            return LTMCommandLine.ExitCode.success.rawValue
        }
        let unknown = arguments.unknown(known: ["full", "help", "h"])
        guard unknown.isEmpty else {
            Output.error("未知選項：\(unknown.joined(separator: ", "))\n\n\(usage)")
            return LTMCommandLine.ExitCode.usageError.rawValue
        }

        do {
            let service = try CommandSupport.makeService(recordEvents: false)
            let report = try service.build(full: arguments.has("full"))
            print(
                """
                ✓ 索引完成（\(report.wasFullRebuild ? "全量重建" : "增量")）
                  新增 chunk：\(report.chunksIndexed)　索引總計：\(report.totalChunks)
                  作廢來源：\(report.sourcesInvalidated)　embedding revision：\(report.embeddingRevision)
                """)
            if report.skipped.total > 0 {
                // 跳過是正常的，但必須說得出跳了多少、為什麼——否則索引少了東西
                // 沒有人會發現。
                print(
                    "  跳過 \(report.skipped.total) 筆紀錄"
                        + "（非對話 \(report.skipped.notATurn)、缺欄位 \(report.skipped.missingPointerField)、"
                        + "識別碼異常 \(report.skipped.malformedIdentifier)、"
                        + "無可索引文字 \(report.skipped.noIndexableText)、"
                        + "無法解析 \(report.skipped.unparseableLine)）")
            }
            return LTMCommandLine.ExitCode.success.rawValue
        } catch let error as IndexBuilder.BuildError {
            switch error {
            case .lockHeld(let path):
                Output.error("✗ 另一個建置正在進行（鎖：\(path)）。等它結束，或確認沒有殘留的鎖檔後再試。")
                return LTMCommandLine.ExitCode.lockHeld.rawValue
            case .stateUnreadable(let detail):
                Output.error("✗ 續讀狀態無法讀取：\(detail)。用 `ltm build --full` 從零重建。")
                return LTMCommandLine.ExitCode.indexStateError.rawValue
            }
        } catch let error as CorpusScanner.ScanError {
            if case .corpusRootUnreadable(let path) = error {
                Output.error("✗ 讀不到語料根：\(path)")
            }
            return LTMCommandLine.ExitCode.corpusError.rawValue
        } catch let error as ContextualEmbeddingProvider.EmbeddingError {
            Output.error("✗ embedding 模型不可用：\(error)")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        } catch let error as IndexDatabase.DatabaseError {
            if case .tokenizerUnavailable(let version, let detail) = error {
                Output.error("✗ FTS5 tokenizer 不可用（SQLite \(version)）：\(detail)")
            } else {
                Output.error("✗ 索引資料庫錯誤：\(error)")
            }
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        } catch {
            Output.error("✗ 建置失敗：\(error)")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        }
    }
}

// MARK: - query

enum QueryCommand {
    static let usage = """
        用法：ltm query <查詢文字> [選項]

        選項：
          --k <N>              最多回幾筆（預設 20）
          --project <名稱>      限定單一 project
          --all-projects       跨全部 project（預設只搜當前 project）
          --strategy <名稱>     archival（預設）／human-like／conservative
          --record             把這次呈現寫成 shown 事件（預設不寫）
          --json               輸出 JSON
          -h, --help
        """

    static let knownOptions: Set<String> = [
        "k", "project", "all-projects", "strategy", "record", "json", "help", "h",
    ]

    static func run(arguments raw: [String]) -> Int32 {
        let arguments = Arguments(raw, valueOptions: ["k", "project", "strategy"])
        if arguments.has("help") || arguments.has("h") {
            print(usage)
            return LTMCommandLine.ExitCode.success.rawValue
        }
        let unknown = arguments.unknown(known: knownOptions)
        guard unknown.isEmpty else {
            Output.error("未知選項：\(unknown.joined(separator: ", "))\n\n\(usage)")
            return LTMCommandLine.ExitCode.usageError.rawValue
        }
        let queryText = arguments.positional.joined(separator: " ")
        guard !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Output.error("缺少查詢文字。\n\n\(usage)")
            return LTMCommandLine.ExitCode.usageError.rawValue
        }
        if arguments.has("all-projects"), arguments.value("project") != nil {
            Output.error("--project 與 --all-projects 互斥：一個限定單一 project，一個是全語料。")
            return LTMCommandLine.ExitCode.usageError.rawValue
        }

        let record = arguments.has("record")
        do {
            let service = try CommandSupport.makeService(recordEvents: record)
            let scope = try CommandSupport.resolveScope(
                arguments: arguments, corpusRoot: service.corpusRoot)
            let strategy = try CommandSupport.strategy(named: arguments.value("strategy"))
            let outcome = try service.query(
                text: queryText, limit: arguments.integer("k") ?? 20, scope: scope,
                strategy: strategy, recordEvents: record)

            if arguments.has("json") {
                try printJSON(outcome)
            } else {
                printHuman(outcome)
            }
            return LTMCommandLine.ExitCode.success.rawValue
        } catch let error as LTMService.ServiceError {
            return report(error)
        } catch let error as ContextualEmbeddingProvider.EmbeddingError {
            Output.error("✗ embedding 模型不可用：\(error)")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        } catch {
            Output.error("✗ 查詢失敗：\(error)")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        }
    }

    /// 失敗一律指名補救命令。
    static func report(_ error: LTMService.ServiceError) -> Int32 {
        switch error {
        case .indexMissing(let path):
            Output.error("✗ 索引不存在（\(path)）。先跑 `ltm build`。")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        case .embeddingRevisionMismatch(let indexed, let runtime):
            Output.error(
                """
                ✗ 索引的 embedding revision 與目前的執行環境不同代
                  索引：\(indexed)
                  目前：\(runtime)
                跨 revision 的向量距離沒有意義，所以不回答。請跑 `ltm build --full` 重建。
                """)
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        case .layoutVersionMismatch(let indexed, let expected):
            Output.error(
                "✗ 索引結構版本不符（索引 \(indexed.map(String.init) ?? "未知")、需要 \(expected)）。請跑 `ltm build --full`。")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        case .ambiguousScope(let detail):
            Output.error(
                """
                ✗ 無法決定查詢範圍：\(detail)
                請用 `--project <名稱>` 指定，或用 `--all-projects` 明示要跨全部 project。
                """)
            return LTMCommandLine.ExitCode.scopeError.rawValue
        }
    }

    static func printHuman(_ outcome: QueryOutcome) {
        if outcome.hits.isEmpty {
            print("（沒有命中）")
            return
        }
        let formatter = ISO8601DateFormatter()
        for (index, hit) in outcome.hits.enumerated() {
            let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ")
            let clipped = snippet.count > 160 ? String(snippet.prefix(160)) + "…" : snippet
            print("\(index + 1). [\(hit.project)] \(formatter.string(from: hit.timestamp))")
            print("   \(clipped)")
            print("   ↳ session \(hit.sessionID)  turn \(hit.uuid)")
            if hit.displacement != 0 {
                print("   ↳ 位移 \(hit.displacement > 0 ? "+" : "")\(hit.displacement)（\(hit.historyDescription)）")
            }
        }
        var footer = "策略 \(outcome.strategyID)"
        if outcome.refreshedSources > 0 { footer += "　查詢前併入 \(outcome.refreshedSources) 筆新內容" }
        if outcome.eventsRecorded > 0 { footer += "　已記錄 \(outcome.eventsRecorded) 筆 shown 事件" }
        print("— \(footer)")
    }

    static func printJSON(_ outcome: QueryOutcome) throws {
        let formatter = ISO8601DateFormatter()
        let objects: [[String: Any]] = outcome.hits.map { hit in
            var object: [String: Any] = [
                "project": hit.project,
                "sessionId": hit.sessionID,
                "uuid": hit.uuid,
                "timestamp": formatter.string(from: hit.timestamp),
                "snippet": hit.snippet,
                "score": hit.score,
                "band": hit.band,
            ]
            // 位移與理由只在重排策略下才有意義；archival 一律 0，附上去只是噪音。
            if outcome.strategyID != "archival" {
                object["displacement"] = hit.displacement
                object["history"] = hit.historyDescription
                object["movement"] = hit.movementDescription
            }
            return object
        }
        let data = try JSONSerialization.data(
            withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(data: data, encoding: .utf8) ?? "[]")
    }
}
