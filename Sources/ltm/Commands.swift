import Foundation
import LTMCore
import LTMEval
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
    /// - Parameter needsEventStore: 這次呼叫是否需要事件存放。
    ///
    ///   **讀歷史與寫歷史是兩件事**。先前這個參數叫 `recordEvents`，於是
    ///   `--strategy human-like` 不帶 `--record` 時 `eventStore` 是 nil，策略拿到
    ///   空投影、輸出卻照樣宣稱跑了那個策略——靜默失效。現在只要「要用策略」或
    ///   「要記錄」任一成立就開存放，`--record` 只決定事後要不要 append。
    /// - Parameter needsRecordStore: 這次呼叫是否需要呈現紀錄存放（只有比較模式要）。
    static func makeService(needsEventStore: Bool, needsRecordStore: Bool = false) throws
        -> LTMService
    {
        let embedder = try ContextualEmbeddingProvider()
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
        let memoryRoot = memoryRootURL()
        // 先驗 root（不建立任何東西），通過後才開事件存放。
        let probe = try LTMService.make(
            corpusRoot: corpusRoot, derivedRoot: derivedRoot,
            embedder: embedder, eventStore: nil, memoryRoot: memoryRoot)
        guard needsEventStore else { return probe }
        let store = try FileEventStore(url: memoryEventsURL(validatedRoot: memoryRoot))
        let records =
            needsRecordStore
            ? try FilePresentationRecordStore(
                url: memoryRecordsURL(validatedRoot: memoryRoot))
            : nil
        return try LTMService.make(
            corpusRoot: corpusRoot, derivedRoot: derivedRoot,
            embedder: embedder, eventStore: store, recordStore: records,
            memoryRoot: memoryRoot)
    }

    /// 記憶層根，**經過語料 containment 驗證**。
    ///
    /// `ltm memory` 需要它：那條路徑會寫入（備份與就地覆寫），但它不建 `LTMService`，
    /// 所以拿不到 `make()` 內那道守衛。先前它直接用 `memoryRootURL()`，於是
    /// `LTM_MEMORY_ROOT` 指進語料時，備份與改寫後的 canonical 檔會落在唯讀語料裡
    /// ——直接違反不變式 1，而且是寫入。
    ///
    /// 判定沿用 `MemoryCorpusPolicy`（inode 身分、symlink、firmlink），不自己重寫
    /// 一份：複製那份判定會漂移，而漂移的方向是「放行了不該放行的路徑」且不報錯。
    static func validatedMemoryRoot() throws -> URL {
        let corpusRoot =
            ProcessInfo.processInfo.environment["LTM_CORPUS_ROOT"].map {
                URL(fileURLWithPath: $0)
            } ?? CorpusLocation.readOnlyRoot
        let root = memoryRootURL()
        let policy = MemoryCorpusPolicy(corpusRoots: [corpusRoot])
        guard !policy.isInsideReadOnlyCorpus(root) else {
            throw LTMService.ServiceError.rootInsideCorpus(path: root.path)
        }
        return root
    }

    /// 事件根（尚未建立任何目錄）。**未驗證**——寫入路徑一律用
    /// `validatedMemoryRoot()`。
    static func memoryRootURL() -> URL {
        let base =
            ProcessInfo.processInfo.environment["LTM_MEMORY_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-ltm")
        return base.appendingPathComponent("memory")
    }

    /// 使用歷史的存放位置：`~/.claude-ltm/memory/events.jsonl`。
    ///
    /// 與衍生索引分開（`derived/`）是刻意的：索引可以隨時刪掉重建，記憶層不行
    /// ——它記的是 jsonl 記不得的事（CLAUDE.md 的例外條款）。
    /// 事件檔路徑。**呼叫端必須先確認 root 不在語料裡**（見 `LTMService.make`）。
    static func memoryEventsURL(validatedRoot root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("events.jsonl")
    }

    /// 交錯呈現紀錄的存放位置：`~/.claude-ltm/memory/presentations.jsonl`。
    ///
    /// 與事件檔**分開**而不是共用一個檔案：兩者的形狀不同（一筆事件對一個
    /// anchor，一筆紀錄對整次呈現），混在同一份 JSON Lines 裡會逼讀取端先猜
    /// 這一行是哪一種。同一個目錄、同一條落地紀律（見 `CanonicalStore`）。
    static func memoryRecordsURL(validatedRoot root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("presentations.jsonl")
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

    /// 由使用者打的字組出策略。**對照表在 `StrategyRegistry`，不在這裡**——
    /// 比較模式也要組策略，而那條路徑住在服務層；兩份表會漂移。
    static func strategy(named name: String?) throws -> (any MemoryStrategy)? {
        // nil 或 archival 都回 nil：facade 的預設就是 archival，讓它自己決定。
        guard let name, name != "archival" else { return nil }
        guard let strategy = StrategyRegistry.make(RankingPolicyID(name)) else {
            throw LTMService.ServiceError.unknownStrategy(name: name)
        }
        return strategy
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
            let service = try CommandSupport.makeService(needsEventStore: false)
            let report = try service.build(full: arguments.has("full"))
            print(
                """
                ✓ 索引完成（\(report.wasFullRebuild ? "全量重建" : "增量")）
                  新增 chunk：\(report.chunksIndexed)　索引總計：\(report.totalChunks)
                  作廢來源：\(report.sourcesInvalidated)　embedding revision：\(report.embeddingRevision)
                """)
            if !report.sourcesUnreadable.isEmpty {
                // 讀不到的來源**沒有**被作廢（那會刪掉還存在的內容），所以它們的
                // 內容仍在索引裡、只是不會更新。沉默地繼續會讓這次建置看起來完整。
                Output.error(
                    "  ⚠ \(report.sourcesUnreadable.count) 個來源檔讀不到，本輪未更新（既有內容保留）：")
                for key in report.sourcesUnreadable.prefix(5) { Output.error("      \(key)") }
                if report.sourcesUnreadable.count > 5 {
                    Output.error("      …另 \(report.sourcesUnreadable.count - 5) 個")
                }
            }
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
            case .sidecarShorterThanDeclared(let declared, let found):
                Output.error(
                    """
                    ✗ 向量側車檔比索引宣稱的短（宣稱 \(declared) 筆、檔案有 \(found) 筆）
                    缺掉的向量無法補——補零會讓向量通道靜默失效而筆數核對照樣通過。
                    請跑 `ltm build --full` 從零重建。
                    """)
                return LTMCommandLine.ExitCode.indexStateError.rawValue
            case .fullRebuildRequired(let detail):
                Output.error("✗ 需要整份重建但這條路徑不允許：\(detail)。請跑 `ltm build --full`。")
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
          --compare            兩個策略交錯呈現並記錄（隱含 --record，與 --strategy 互斥）
          --json               輸出 JSON
          -h, --help

        比較模式（--compare）用 \(ComparisonPair.aName) 與 \(ComparisonPair.bName) 排同一份
        候選、交錯後呈現，並把逐位置的歸屬寫進 presentations.jsonl。輸出**不標示**
        哪個位置來自哪一邊——那正是交錯評估存在的理由。
        """

    static let knownOptions: Set<String> = [
        "k", "project", "all-projects", "strategy", "record", "compare", "json", "help", "h",
    ]

    /// 比較模式用哪一對策略。
    ///
    /// ## 為什麼是固定的一對，而不是讓使用者挑
    ///
    /// `--compare` 在 spec 裡是一個**旗標**（沒有值），所以這一對必須寫死。
    ///
    /// ## 為什麼是這一對
    ///
    /// `archival` 是「記憶不存在」的對照組（它的契約逐字是不論給什麼 projection
    /// 都產出相同輸出），`human-like` 是模仿人類記憶動力學的那一檔。兩者對打
    /// 問的是本專案的核心問題：**讓使用歷史影響順序，到底有沒有幫助**。
    ///
    /// `conservative` 沒有進來，是因為它與 `human-like` 在
    /// `appliesSpreadingActivation` 上不一致，而交錯器收單一 projection——服務層
    /// 會拒絕那一對（`incompatibleComparisonPair`）。要比那兩個，得先讓交錯器
    /// 能持有兩份 projection，那是另一次改動。
    ///
    /// **這個選擇沒有量測支撐**，也不宣稱哪一對比較有價值；它是在 spec 允許的
    /// 形狀（單一旗標）下唯一可行的一對之中挑的。
    enum ComparisonPair {
        static let a = RankingPolicyID("archival")
        static let b = RankingPolicyID("human-like")
        static var aName: String { a.value }
        static var bName: String { b.value }
    }

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
        // **在跑任何查詢之前**就拒絕。`--strategy` 指定「由哪一個策略排」，
        // `--compare` 是「由兩個策略排再交錯」——讓其中一個靜默勝出，印出來的
        // 順序就歸屬不到任何一個旗標，而使用者不會知道自己拿到的是哪一種。
        if arguments.has("compare"), arguments.value("strategy") != nil {
            Output.error(
                "--compare 與 --strategy 互斥：--strategy 指定單一排序策略，--compare 用兩個策略交錯。")
            return LTMCommandLine.ExitCode.usageError.rawValue
        }

        // `--k` 在進入檢索之前就要驗。
        //
        // 未驗的負值會一路傳到 `prefix(limit)`，那裡的 stdlib precondition 會**中止
        // 行程**——使用者看到的是 crash，不是錯誤訊息。非數值先前被靜默改成預設，
        // 那同樣糟：命令回報成功，做的卻不是使用者要求的事。
        let limit: Int
        if let raw = arguments.value("k") {
            guard let parsed = Int(raw), (1...1000).contains(parsed) else {
                Output.error("✗ --k 必須是 1 到 1000 之間的整數（收到：\(raw)）")
                return LTMCommandLine.ExitCode.usageError.rawValue
            }
            limit = parsed
        } else {
            limit = 20
        }

        let compare = arguments.has("compare")
        let record = arguments.has("record")
        do {
            if compare {
                let service = try CommandSupport.makeService(
                    needsEventStore: true, needsRecordStore: true)
                let scope = try CommandSupport.resolveScope(
                    arguments: arguments, corpusRoot: service.corpusRoot)
                // **`--compare` 隱含 `--record`**，而它的執行點就是這裡的
                // `persist: true`——不是在上面把 `record` 或起來。那樣寫會是死碼：
                // 這條分支根本不讀 `record`，於是一個看起來在做事的 `|| compare`
                // 實際上什麼都沒做，而讀的人會以為隱含關係由它保證。
                //
                // 不記錄的比較什麼都產不出來，只是改變使用者看到的東西，所以
                // 這裡沒有「不記錄」這個選項；`--record` 一起給也是同一個結果。
                let outcome = try service.compare(
                    text: queryText, limit: limit, scope: scope,
                    a: ComparisonPair.a, b: ComparisonPair.b, persist: true)
                if arguments.has("json") {
                    try printComparisonJSON(outcome)
                } else {
                    printComparisonHuman(outcome)
                }
                return LTMCommandLine.ExitCode.success.rawValue
            }

            let strategy = try CommandSupport.strategy(named: arguments.value("strategy"))
            // 要用會讀歷史的策略、或要記錄呈現，兩者任一都需要事件存放。
            let needsStore = record || (strategy.map { !$0.consumedSignals.isEmpty } ?? false)
            let service = try CommandSupport.makeService(needsEventStore: needsStore)
            let scope = try CommandSupport.resolveScope(
                arguments: arguments, corpusRoot: service.corpusRoot)
            let outcome = try service.query(
                text: queryText, limit: limit, scope: scope,
                strategy: strategy, recordEvents: record)

            if arguments.has("json") {
                try printJSON(outcome)
            } else {
                printHuman(outcome)
            }
            return LTMCommandLine.ExitCode.success.rawValue
        } catch let error as InterleavingViolation {
            Output.error("✗ 交錯比較失敗：\(error)")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        } catch let error as LTMService.ServiceError {
            return report(error)
        } catch let error as EventStoreError {
            // `--strategy human-like` / `conservative` 會讀使用歷史，所以記憶層的
            // 錯誤從這裡出來。先前沒有這個分支，錯誤以裸 enum 形式吐給使用者
            // （`supersededAnchorRule(path: "…", lineNumbers: [1, 2, 3])`），
            // 而 anchor 定址規則換代之後，任何在換代前寫過事件的人第一次用會讀
            // 歷史的策略就必然撞上——一個必然觸發又指名不出補救方式的錯誤，
            // 實際效果等同「歷史從此鎖死」。
            Output.error("✗ \(MemoryCommand.describe(error))")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        } catch let error as IndexBuilder.BuildError {
            // 查詢路徑的增量續讀委派給 `IndexBuilder`，所以它的錯誤會從這裡出來。
            // `lockHeld` 到不了——facade 把它吞成「這一輪不併入新內容」。
            switch error {
            case .stateUnreadable(let detail):
                Output.error(
                    """
                    ✗ 續讀狀態無法讀取：\(detail)
                    索引還在，但無法判斷該從哪裡接著讀——照樣回答會安靜地漏掉新內容。
                    請跑 `ltm build --full` 從零重建。
                    """)
            case .sidecarShorterThanDeclared(let declared, let found):
                Output.error(
                    """
                    ✗ 向量側車檔比索引宣稱的短（宣稱 \(declared) 筆、檔案有 \(found) 筆）
                    缺掉的向量無法補——補零會讓向量通道靜默失效而筆數核對照樣通過。
                    這裡拒答而不是降級成 lexical-only。請跑 `ltm build --full` 重建。
                    """)
            case .fullRebuildRequired(let detail):
                Output.error(
                    """
                    ✗ 索引需要整份重建，查詢路徑不會代勞：\(detail)
                    整份重建會刪掉 DB 與側車，而這條路徑上還有查詢正持有連線。
                    請自己跑 `ltm build --full`。
                    """)
            case .lockHeld(let path):
                Output.error("✗ 意外的鎖錯誤（\(path)）——查詢路徑本應吞掉它。這是 bug。")
            }
            return LTMCommandLine.ExitCode.indexStateError.rawValue
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
        case .anchorSourceRuleMismatch(let indexed, let expected):
            Output.error(
                """
                ✗ 索引的 anchor 定址規則與這個版本不同
                  索引：\(indexed)
                  需要：\(expected)
                舊規則算出的指紋不能拿來跟新規則比對——結果會是「解析到錯的 turn」或
                「報成 orphan」，而兩者都看不出異常。請跑 `ltm build --full` 重建。
                """)
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        case .comparisonRequiresStores:
            Output.error(
                """
                ✗ 比較模式需要事件與呈現紀錄的存放，但取不到
                不能記錄的比較不會執行——一份記不下來的交錯結果與一份記下來的
                在畫面上完全一樣，照做只會讓這次呈現的證據值安靜歸零。
                請確認 LTM_MEMORY_ROOT 指到可寫、且不在語料內的位置。
                """)
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        case .incompatibleComparisonPair(let a, let b):
            Output.error(
                """
                ✗ \(a) 與 \(b) 無法交錯比較：兩者對擴散激發的要求不同
                交錯器收單一 projection，而擴散的授權是逐策略的——共用一份必然
                讓其中一邊看到 spec 沒授權它看的統計。這裡拒絕而不是挑一邊。
                """)
            return LTMCommandLine.ExitCode.usageError.rawValue
        case .unknownStrategy(let name):
            Output.error(
                "未知策略：\(name)（可用：\(StrategyRegistry.known.joined(separator: "、"))）")
            return LTMCommandLine.ExitCode.usageError.rawValue
        case .rootInsideCorpus(let path):
            Output.error(
                """
                ✗ 這個路徑落在唯讀語料裡：\(path)
                語料是 source of truth，任何寫入都是 bug。請把 LTM_DERIVED_ROOT /
                LTM_MEMORY_ROOT 指到語料之外的位置。
                """)
            return LTMCommandLine.ExitCode.corpusError.rawValue
        case .vectorSidecarMismatch(let declared, let found):
            Output.error(
                """
                ✗ 向量側車檔與索引不一致（索引宣稱 \(declared) 筆、檔案有 \(found) 筆）
                少一路向量通道的結果看起來完全正常，所以這裡拒答而不是降級。
                請跑 `ltm build --full` 重建。
                """)
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
            // **不 early return。** 零命中正是「讀不到的來源」最需要被說出來的那一刻
            // ——使用者看到的症狀就是「這東西找不到東西」，而原因可能正是某幾個檔
            // 這一輪讀不到、沒有被併進索引。先前這裡直接 return，於是那段警告在
            // 唯一真正需要它的分支被跳過。
            printRefreshDiagnostics(outcome.refresh)
            return
        }
        let formatter = ISO8601DateFormatter()
        for (index, hit) in outcome.hits.enumerated() {
            let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ")
            let clipped = snippet.count > 160 ? String(snippet.prefix(160)) + "…" : snippet
            print("\(index + 1). [\(hit.project)] \(formatter.string(from: hit.timestamp))")
            print("   \(clipped)")
            // 多來源時列出全部並用**複數**標籤——「這則 turn 存在於好幾份檔案」
            // 因此在輸出上直接看得見，不必數。單一來源維持既有的單數形式逐字不變
            // （#25）。
            let label = hit.sessionSources.count > 1 ? "sessions" : "session"
            print(
                "   ↳ \(label) \(hit.sessionSources.joined(separator: ", "))  turn \(hit.uuid)")
            if hit.displacement != 0 {
                print("   ↳ 位移 \(hit.displacement > 0 ? "+" : "")\(hit.displacement)（\(hit.historyDescription)）")
            }
        }
        var footer = "策略 \(outcome.strategyID)"
        // 「N 筆新內容」名實不符——那個數字是**來源檔數**。
        if outcome.refresh.sourcesRefreshed > 0 {
            footer += "　查詢前併入 \(outcome.refresh.sourcesRefreshed) 個來源檔的新內容"
        }
        if outcome.eventsRecorded > 0 { footer += "　已記錄 \(outcome.eventsRecorded) 筆 shown 事件" }
        print("— \(footer)")

        printRefreshDiagnostics(outcome.refresh)
    }

    /// 比較模式的人類可讀輸出。
    ///
    /// **形狀與一般查詢相同，且一個策略名字都不出現。** 逐位置的歸屬是給計分用
    /// 的資料；讓看結果的人知道哪個位置來自哪一邊，正是交錯評估要避免的事——
    /// 知道了就會影響他接下來點哪一筆，而那個點擊正是要拿來計分的東西。
    ///
    /// 位移一律不印：交錯清單裡的位置是兩份排序輪流取用的產物，不是任何一個
    /// 策略把它移到那裡，印一個數字等於編一個不存在的因果。
    static func printComparisonHuman(_ outcome: LTMService.ComparisonOutcome) {
        if outcome.hits.isEmpty {
            print("（沒有命中）")
            printRefreshDiagnostics(outcome.refresh)
            return
        }
        let formatter = ISO8601DateFormatter()
        for (index, hit) in outcome.hits.enumerated() {
            let snippet = hit.snippet.replacingOccurrences(of: "\n", with: " ")
            let clipped = snippet.count > 160 ? String(snippet.prefix(160)) + "…" : snippet
            print("\(index + 1). [\(hit.project)] \(formatter.string(from: hit.timestamp))")
            print("   \(clipped)")
            let label = hit.sessionSources.count > 1 ? "sessions" : "session"
            print(
                "   ↳ \(label) \(hit.sessionSources.joined(separator: ", "))  turn \(hit.uuid)")
        }
        var footer = "比較模式　呈現 \(outcome.record.id.description)"
        if outcome.record.isNullComparison {
            // **明說**：兩邊順序相同的呈現不會被計分，而使用者從畫面上看不出來。
            // 這在還沒有使用歷史的階段是常態，不是錯誤。
            footer += "　兩邊順序相同（null comparison，不計分）"
        }
        if outcome.refresh.sourcesRefreshed > 0 {
            footer += "　查詢前併入 \(outcome.refresh.sourcesRefreshed) 個來源檔的新內容"
        }
        if outcome.eventsRecorded > 0 { footer += "　已記錄 \(outcome.eventsRecorded) 筆 shown 事件" }
        print("— \(footer)")
        printRefreshDiagnostics(outcome.refresh)
    }

    /// 比較模式的 JSON 輸出。
    ///
    /// 與人類輸出同一條紀律：帶呈現識別碼（讓工具能把後續互動掛回這次呈現），
    /// **不帶逐位置歸屬、也不帶策略名字**。歸屬在 `presentations.jsonl` 裡，
    /// 那是給計分讀的，不是給呈現讀的。
    static func printComparisonJSON(_ outcome: LTMService.ComparisonOutcome) throws {
        let formatter = ISO8601DateFormatter()
        let objects: [[String: Any]] = outcome.hits.map { hit in
            [
                "project": hit.project,
                "uuid": hit.uuid,
                "timestamp": formatter.string(from: hit.timestamp),
                "snippet": hit.snippet,
                "score": hit.score,
                "band": hit.band,
                "channels": hit.channels,
                "sessions": hit.sessionSources,
                "presentation": outcome.record.id.description,
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(data: data, encoding: .utf8) ?? "[]")
        printRefreshDiagnostics(outcome.refresh)
    }

    /// 增量續讀的診斷。**三條輸出路徑共用**（有命中、零命中、`--json`）。
    ///
    /// 抽成具名函式是因為先前它 inline 在有命中那條路徑的尾巴，於是另外兩條
    /// 一個字都不說——而零命中正是最需要它的那一刻，`--json` 則是 #24 Stage 2 的
    /// MCP server 要走的那條。
    static func printRefreshDiagnostics(_ refresh: RefreshReport) {
        // 讀不到的來源**不會被作廢**（讀不到 ≠ 消失），但不作廢就必須說出來——
        // 否則索引少了這些檔的新內容，而使用者看到的是一次成功的查詢。
        //
        // 這條路徑跑的是與 `ltm build` **完全相同**的那段掃描，所以兩邊說法不一致
        // 沒有任何理由：先前 query 把診斷資訊整批丟掉，而它是使用者最常走的介面。
        if !refresh.sourcesUnreadable.isEmpty {
            Output.error(
                "  ⚠ \(refresh.sourcesUnreadable.count) 個來源檔讀不到，本輪未更新（既有內容保留）")
            for key in refresh.sourcesUnreadable.prefix(3) { Output.error("      \(key)") }
            if refresh.sourcesUnreadable.count > 3 {
                Output.error("      …另 \(refresh.sourcesUnreadable.count - 3) 個")
            }
        }
        if refresh.skipped.total > 0 {
            Output.error("  ⚠ 併入時跳過 \(refresh.skipped.total) 筆紀錄（`ltm build` 可看分類）")
        }
    }

    static func printJSON(_ outcome: QueryOutcome) throws {
        let formatter = ISO8601DateFormatter()
        let objects: [[String: Any]] = outcome.hits.map { hit in
            var object: [String: Any] = [
                "project": hit.project,
                "uuid": hit.uuid,
                "timestamp": formatter.string(from: hit.timestamp),
                "snippet": hit.snippet,
                "score": hit.score,
                "band": hit.band,
                "channels": hit.channels,
                // **無條件輸出，即使只有一個元素**（#25）。這裡刻意不沿用下面
                // `displacement`／`presentation` 的「只在有意義時才附加」慣例：
                // 那個慣例適用於「這次查詢沒有這個概念」的欄位，而每一筆命中
                // 永遠至少有一個來源。條件式輸出會逼消費端寫一條「欄位不存在時
                // 回頭用 sessionId」的分支，而那條分支只在單一來源時才走到——
                // 也就是最不容易被測到、最容易寫錯的那條。
                "sessions": hit.sessionSources,
            ]
            // 位移與理由只在重排策略下才有意義；archival 一律 0，附上去只是噪音。
            if outcome.strategyID != "archival" {
                object["displacement"] = hit.displacement
                object["history"] = hit.historyDescription
                object["movement"] = hit.movementDescription
            }
            // 只在有記錄事件時才附加——沒有事件檔可寫就沒有指標可以指，見
            // `QueryHit.presentation` 的說明（add-spreading-activation-fixes
            // Decision 6，ltm-cli spec 的對應 delta）。
            if let presentation = hit.presentation {
                object["presentation"] = presentation.description
            }
            return object
        }
        let data = try JSONSerialization.data(
            withJSONObject: objects, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(data: data, encoding: .utf8) ?? "[]")

        // 診斷走 **stderr**，所以 stdout 仍然是乾淨的 JSON 陣列——ltm-cli spec 逐字
        // 要求「output SHALL be a JSON array」，改成物件需要一條 delta。
        //
        // **誠實邊界**：這只解決「不沉默」，沒有解決「機器讀得到」。stderr 的中文
        // 警告對 #24 Stage 2 的 MCP server 不可消費。真正的修法是把輸出改成
        // `{ "hits": [...], "diagnostics": {...} }`，而那是介面決定，屬於 Stage 2
        // 那次改動，不該在這裡夾帶。
        printRefreshDiagnostics(outcome.refresh)
    }
}
