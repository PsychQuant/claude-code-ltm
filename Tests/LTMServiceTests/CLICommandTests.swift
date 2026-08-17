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

@Test("寫下的事件只含指標與類別，不含語料原文")
func recordedEventsContainNoCorpusText() throws {
    let secret = "這段文字不應該出現在事件檔裡"
    let workspace = try CLIWorkspace.make(texts: [secret])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)
    _ = try runCLI(
        ["query", "這段文字", "--all-projects", "--record"], environment: workspace.environment)

    let raw = try String(contentsOf: workspace.eventsFile, encoding: .utf8)
    #expect(!raw.contains(secret), "事件檔含語料原文 —— 違反記憶層的硬約束")
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
