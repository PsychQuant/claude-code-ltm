import Foundation
import Testing

@testable import LTMCore
@testable import LTMIndex
@testable import LTMMemory
@testable import LTMService
@testable import ltm

// CLI 的行為測試走**真的執行檔**，而不是直接呼叫 facade：要驗的正是 adapter
// 這一層（旗標解析、範圍解析、結束碼、輸出格式）。直接呼叫 facade 會把 adapter
// 整個跳過，那樣的測試在 adapter 壞掉時仍然全綠。

/// 跑一次 `ltm`，回傳 (結束碼, stdout, stderr)。
@discardableResult
private func runCLI(_ arguments: [String], environment extra: [String: String]) throws -> (
    code: Int32, out: String, err: String
) {
    let binary = try ltmExecutable()
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in extra { environment[key] = value }
    process.environment = environment
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(data: outData, encoding: .utf8) ?? "",
        String(data: errData, encoding: .utf8) ?? ""
    )
}

/// `ltm` 執行檔的位置。
///
/// 從 `#filePath` 往上找 repo 根再進 `.build/`，**不用 `Bundle.allBundles`**：
/// 在 swift-testing 底下那個清單裡沒有 xctest bundle，於是它會回退到
/// toolchain 目錄，測試就變成「找不到執行檔」而不是在測 CLI。
private func ltmExecutable(file: StaticString = #filePath) throws -> URL {
    var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path)
        {
            for configuration in ["debug", "release"] {
                let candidate = directory.appendingPathComponent(".build/\(configuration)/ltm")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            throw CLINotBuilt()
        }
        directory = directory.deletingLastPathComponent()
    }
    throw CLINotBuilt()
}

private struct CLINotBuilt: Error {}

/// 一個含合成語料的臨時工作區。
private struct CLIWorkspace {
    let base: URL
    var corpus: URL { base.appendingPathComponent("corpus") }
    var derived: URL { base.appendingPathComponent("derived") }
    var memory: URL { base.appendingPathComponent("mem") }
    var eventsFile: URL { memory.appendingPathComponent("memory/events.jsonl") }

    var environment: [String: String] {
        [
            "LTM_CORPUS_ROOT": corpus.path,
            "LTM_DERIVED_ROOT": derived.path,
            "LTM_MEMORY_ROOT": memory.path,
            // **HOME 也要隔離**。三個 LTM_* 變數若因為改名或打錯而失效，程式會
            // 回退到 `NSHomeDirectory()` —— 也就是使用者真實的 `~/.claude/projects`
            // 與 `~/.claude-ltm/`。那時測試會安靜地讀寫真實資料，而且看起來是綠的。
            "HOME": base.path,
        ]
    }

    static func make(project: String = "proj-demo", texts: [String]) throws -> CLIWorkspace {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltm-cli-\(UUID().uuidString)")
        let workspace = CLIWorkspace(base: base)
        let projectDir = workspace.corpus.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let lines = texts.enumerated().map { offset, text -> String in
            let object: [String: Any] = [
                "type": offset.isMultiple(of: 2) ? "user" : "assistant",
                "uuid": String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", offset),
                "sessionId": "11111111-2222-3333-4444-555555555555",
                "timestamp": "2026-08-17T06:00:00.000Z",
                "message": ["role": "user", "content": text],
            ]
            return String(
                data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: projectDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        return workspace
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Test("ltm build 建出索引並回報統計，語料保持不變")
func buildSucceedsAndLeavesCorpusUntouched() throws {
    let workspace = try CLIWorkspace.make(texts: ["記憶策略的內容", "檢索量測的內容"])
    defer { workspace.cleanup() }
    let sessionFile = workspace.corpus.appendingPathComponent("proj-demo/s.jsonl")
    let before = try Data(contentsOf: sessionFile)

    let result = try runCLI(["build"], environment: workspace.environment)

    #expect(result.code == 0, "build 失敗，stderr 見測試輸出")
    if result.code != 0 { Issue.record("build stderr: \(result.err)") }
    #expect(result.out.contains("索引完成"))
    #expect(try Data(contentsOf: sessionFile) == before, "建置不得改動語料")
    #expect(
        FileManager.default.fileExists(
            atPath: workspace.derived.appendingPathComponent("index.sqlite3").path))
}

@Test("索引不存在時 ltm query 非零結束，且訊息指名 ltm build")
func queryWithoutIndexNamesBuild() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容"])
    defer { workspace.cleanup() }

    let result = try runCLI(
        ["query", "內容", "--all-projects"], environment: workspace.environment)

    #expect(result.code != 0)
    #expect(result.err.contains("ltm build"), "失敗訊息必須指名補救命令")
}

@Test("無法決定範圍時要求明示，不擴大成全語料")
func ambiguousScopeRefusesInsteadOfWidening() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    // 測試行程的工作目錄對應不到語料裡的任何 project，所以範圍無法推定。
    let result = try runCLI(["query", "內容"], environment: workspace.environment)

    #expect(result.code == LTMCommandLine.ExitCode.scopeError.rawValue)
    #expect(result.err.contains("--project"))
    #expect(result.err.contains("--all-projects"))
    #expect(result.out.isEmpty, "拒絕的查詢不得同時輸出結果")
}

@Test("--json 輸出每筆都帶齊四欄指標")
func jsonOutputIsMachineComplete() throws {
    let workspace = try CLIWorkspace.make(
        texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let result = try runCLI(
        ["query", "記憶策略", "--all-projects", "--json"], environment: workspace.environment)

    #expect(result.code == 0)
    if result.code != 0 { Issue.record("stderr: \(result.err)") }
    let parsed = try JSONSerialization.jsonObject(with: Data(result.out.utf8))
    guard let objects = parsed as? [[String: Any]] else {
        Issue.record("--json 的輸出必須是 JSON 陣列")
        return
    }
    #expect(!objects.isEmpty)
    for object in objects {
        for field in ["project", "sessionId", "uuid", "timestamp"] {
            let value = object[field] as? String
            #expect(value?.isEmpty == false, "\(field) 缺漏——不變式 3 要求每筆都帶指標")
        }
        #expect(object["snippet"] is String)
        #expect(object["score"] is Double)
        #expect(object["band"] is Int)
    }
}

@Test("--json --record 時輸出每筆帶 presentation 欄位；不 --record 時不帶")
func jsonOutputExposesPresentationOnlyWhenRecording() throws {
    let workspace = try CLIWorkspace.make(
        texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let recorded = try runCLI(
        ["query", "記憶策略", "--all-projects", "--json", "--record"],
        environment: workspace.environment)
    #expect(recorded.code == 0)
    if recorded.code != 0 { Issue.record("stderr: \(recorded.err)") }
    let recordedObjects =
        try JSONSerialization.jsonObject(with: Data(recorded.out.utf8)) as? [[String: Any]]
    #expect(!(recordedObjects ?? []).isEmpty)
    for object in recordedObjects ?? [] {
        let value = object["presentation"] as? String
        #expect(value?.isEmpty == false, "--record 時每筆物件都應帶非空 presentation 欄位")
    }

    let notRecorded = try runCLI(
        ["query", "記憶策略", "--all-projects", "--json"], environment: workspace.environment)
    #expect(notRecorded.code == 0)
    let notRecordedObjects =
        try JSONSerialization.jsonObject(with: Data(notRecorded.out.utf8)) as? [[String: Any]]
    #expect(!(notRecordedObjects ?? []).isEmpty)
    for object in notRecordedObjects ?? [] {
        #expect(object["presentation"] == nil, "不 --record 時輸出物件不該帶 presentation 欄位")
    }
}

@Test("預設不寫事件；--record 才寫，且每筆命中一則 shown")
func eventRecordingIsOptIn() throws {
    let workspace = try CLIWorkspace.make(
        texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    // 預設：事件檔完全不該出現。
    _ = try runCLI(["query", "內容", "--all-projects"], environment: workspace.environment)
    #expect(
        !FileManager.default.fileExists(atPath: workspace.eventsFile.path),
        "預設查詢不得寫使用歷史——開發與檢查用的查詢會污染策略比較的依據")

    // --record：命中幾筆就寫幾筆。
    let recorded = try runCLI(
        ["query", "內容", "--all-projects", "--record", "--json"],
        environment: workspace.environment)
    #expect(recorded.code == 0)
    if recorded.code != 0 { Issue.record("stderr: \(recorded.err)") }
    let hits = (try JSONSerialization.jsonObject(with: Data(recorded.out.utf8)) as? [[String: Any]])?
        .count ?? 0
    #expect(hits > 0)
    let lines = try String(contentsOf: workspace.eventsFile, encoding: .utf8)
        .split(separator: "\n").filter { !$0.isEmpty }
    #expect(lines.count == hits, "shown 事件數必須等於呈現的命中數")
}

@Test("寫下的事件只含指標與類別，不含語料原文，也不含查詢原文")
func recordedEventsContainNoCorpusText() throws {
    let secret = "這段文字不應該出現在事件檔裡"
    // 查詢用的字串必須**單獨**斷言。先前只斷言完整的 secret，而實際下的查詢是它的
    // 子字串——真的洩漏 query 原文時，斷言的 needle 比洩漏的內容長，抓不到。
    let queryText = "不應該出現"
    let workspace = try CLIWorkspace.make(texts: [secret])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)
    _ = try runCLI(
        ["query", queryText, "--all-projects", "--record"], environment: workspace.environment)

    let raw = try String(contentsOf: workspace.eventsFile, encoding: .utf8)
    #expect(!raw.contains(secret), "事件檔含語料原文 —— 違反記憶層的硬約束")
    #expect(!raw.contains(queryText), "事件檔含查詢原文 —— 同一條硬約束的另一半")
    #expect(raw.contains("shown"))
    // 帶得動的只有 anchor（指標 + 內容雜湊）與類別標籤。
    #expect(raw.contains("contentHash"))
}

@Test("未知選項不被忽略，而是回報並以 usage error 結束")
func unknownOptionIsReported() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容"])
    defer { workspace.cleanup() }

    let result = try runCLI(
        ["query", "內容", "--jsno", "--all-projects"], environment: workspace.environment)

    #expect(result.code == LTMCommandLine.ExitCode.usageError.rawValue)
    #expect(result.err.contains("jsno"), "打錯的旗標必須被指名，否則使用者以為它生效了")
}

@Test("--strategy 不帶 --record 時仍讀得到歷史，且不寫入任何事件")
func strategyReadsHistoryWithoutRecording() throws {
    let workspace = try CLIWorkspace.make(texts: [
        "記憶策略的內容", "檢索量測的內容", "第三段內容", "第四段內容",
    ])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    // 先用 --record 造出歷史，再確認不帶 --record 的查詢讀得到它。
    _ = try runCLI(["query", "內容", "--all-projects", "--record"], environment: workspace.environment)
    #expect(FileManager.default.fileExists(atPath: workspace.eventsFile.path))
    let before = try Data(contentsOf: workspace.eventsFile)

    let result = try runCLI(
        ["query", "內容", "--all-projects", "--strategy", "human-like"],
        environment: workspace.environment)

    #expect(result.code == 0)
    if result.code != 0 { Issue.record("stderr: \(result.err)") }
    #expect(result.out.contains("human-like"), "輸出應報出實際套用的策略")
    // 關鍵：沒帶 --record 就不該寫入任何事件（讀歷史 ≠ 寫歷史）。
    #expect(try Data(contentsOf: workspace.eventsFile) == before,
            "--strategy 不該順帶寫事件；讀與寫是兩件事")
}

@Test("memory root 指進語料時拒絕，且語料下沒有任何目錄被建立")
func memoryRootInsideCorpusIsRefusedBeforeCreation() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)
    let before = try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path).sorted()

    var env = workspace.environment
    env["LTM_MEMORY_ROOT"] = workspace.corpus.path  // 指進正在被掃描的語料
    let result = try runCLI(["query", "內容", "--all-projects", "--record"], environment: env)

    #expect(result.code != 0)
    let after = try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path).sorted()
    #expect(after == before, "語料下多出了東西 —— 守衛跑在 mkdir 之後就等於沒守衛")
}

@Test("derived root 指進被覆寫的語料根時同樣被拒")
func derivedRootInsideOverriddenCorpusIsRefused() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容"])
    defer { workspace.cleanup() }
    var env = workspace.environment
    env["LTM_DERIVED_ROOT"] = workspace.corpus.appendingPathComponent("derived").path
    let before = try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path).sorted()

    let result = try runCLI(["build"], environment: env)

    #expect(result.code != 0, "守衛必須跟著**當下使用中的**語料根走，不是只看預設根")
    let after = try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path).sorted()
    #expect(after == before, "語料下多出了索引產物")
}

@Test("--k 負值被拒且不 crash；非數值不靜默改用預設")
func invalidKIsRefused() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容一", "內容二"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let negative = try runCLI(
        ["query", "內容", "--all-projects", "--k", "-1"], environment: workspace.environment)
    #expect(negative.code == LTMCommandLine.ExitCode.usageError.rawValue,
            "負值先前會以 stdlib precondition 中止行程")
    #expect(negative.err.contains("1000"), "訊息要指名接受範圍")

    let nonNumeric = try runCLI(
        ["query", "內容", "--all-projects", "--k", "abc"], environment: workspace.environment)
    #expect(nonNumeric.code == LTMCommandLine.ExitCode.usageError.rawValue)
    #expect(nonNumeric.out.isEmpty, "不得靜默改用預設然後回報成功")
}
