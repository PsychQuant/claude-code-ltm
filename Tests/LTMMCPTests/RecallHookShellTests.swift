import Foundation
import Testing

/// proactive-recall-cued-hook 5.2–5.6：hook 腳本的行為，用 stub `ltm` 驅動。
/// 每個 case 對應 spec `proactive-recall-hook` 的 scenario／Example 表。
private func repoRoot(file: StaticString = #filePath) -> URL {
    var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
        directory = directory.deletingLastPathComponent()
    }
    return directory
}

private struct HookRun { let code: Int32; let out: String; let err: String; let stubInvoked: Bool }

/// stub 的三種形狀：`block`（印區塊並記錄被呼叫）、`sleep`（睡 25 s）、`exit2`、`nofmt`（--help 不含 --format recall）。
private func makeStub(kind: String, in dir: URL) throws -> URL {
    let marker = dir.appendingPathComponent("invoked")
    let body: String
    switch kind {
    case "block":
        body = """
        #!/bin/bash
        if [ "$1" = "query" ] && [ "$2" = "--help" ]; then echo "  --format recall      給 hook"; exit 0; fi
        printf '%s\\n' "$@" > "\(marker.path)"
        printf '<!-- ltm:recall v1 -->\\nBANNER\\n1. [proj] 2026-01-01T00:00:00Z\\n   片段\\n   ↳ session s  turn u\\n<!-- /ltm:recall -->\\n'
        """
    case "sleep":
        body = """
        #!/bin/bash
        if [ "$1" = "query" ] && [ "$2" = "--help" ]; then echo "  --format recall"; exit 0; fi
        printf 'x' > "\(marker.path)"; sleep 25; echo late
        """
    case "exit2":
        body = """
        #!/bin/bash
        if [ "$1" = "query" ] && [ "$2" = "--help" ]; then echo "  --format recall"; exit 0; fi
        printf 'x' > "\(marker.path)"; echo "✗ 索引不存在" >&2; exit 2
        """
    case "nofmt":
        body = """
        #!/bin/bash
        if [ "$1" = "query" ] && [ "$2" = "--help" ]; then echo "  --json"; exit 0; fi
        printf 'x' > "\(marker.path)"; echo "未知選項：format" >&2; exit 64
        """
    default: fatalError("unknown stub kind")
    }
    let url = dir.appendingPathComponent("ltm")
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func runHook(
    _ script: String, prompt: String, session: String = "sess-1", stub: String? = "block",
    env extra: [String: String] = [:], input override: String? = nil
) throws -> HookRun {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-hook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var environment = ProcessInfo.processInfo.environment
    environment["CLAUDE_PLUGIN_ROOT"] = repoRoot().appendingPathComponent("plugin").path
    environment["LTM_RECALL_MODE"] = nil
    environment["LTM_RECALL_CUES"] = nil
    if let stub { environment["LTM_BIN"] = try makeStub(kind: stub, in: dir).path }
    else { environment["LTM_BIN"] = dir.appendingPathComponent("absent-ltm").path }
    for (k, v) in extra { environment[k] = v }
    let process = Process()
    process.executableURL = repoRoot().appendingPathComponent("plugin/hooks/\(script)")
    process.environment = environment
    process.currentDirectoryURL = dir
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
    let payload: [String: Any] = [
        "session_id": session, "cwd": dir.path, "hook_event_name": "UserPromptSubmit", "prompt": prompt,
    ]
    let json = try override ?? String(data: JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    try process.run()
    try stdin.fileHandleForWriting.write(contentsOf: Data(json.utf8))
    try stdin.fileHandleForWriting.close()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return HookRun(
        code: process.terminationStatus, out: String(data: out, encoding: .utf8) ?? "",
        err: String(data: err, encoding: .utf8) ?? "",
        stubInvoked: FileManager.default.fileExists(atPath: dir.appendingPathComponent("invoked").path))
}

@Test("線索表：檔頭寫明列舉／會漏／代價，每條 pattern 都是合法 ERE")
func cueFileDocumentsItsMissCostAndCompiles() throws {
    let text = try String(contentsOf: repoRoot().appendingPathComponent("plugin/hooks/recall-cues.txt"), encoding: .utf8)
    for phrase in ["列舉", "會漏", "現狀"] { #expect(text.contains(phrase), Comment(rawValue: phrase)) }
    let patterns = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
    #expect(patterns.count >= 10)
    for pattern in patterns {
        let grep = Process(); grep.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        grep.arguments = ["-E", "-e", pattern, "/dev/null"]; grep.standardError = Pipe()
        try grep.run(); grep.waitUntilExit()
        #expect(grep.terminationStatus == 1, Comment(rawValue: "ERE 無法編譯：\(pattern)"))
    }
    #expect(patterns.contains("上次") && patterns.contains("earlier"))
}

@Test("閘門結果表：cued 命中／未命中、always、off、未知模式")
func gateOutcomesMatchTheSpecTable() throws {
    let hit = try runHook("ltm-recall-gate.sh", prompt: "上次那個 flock 的決定是什麼")
    #expect(hit.code == 0 && hit.stubInvoked && hit.out.hasPrefix("<!-- ltm:recall v1 -->"), Comment(rawValue: hit.err))
    #expect(hit.out.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("<!-- /ltm:recall -->"))
    let miss = try runHook("ltm-recall-gate.sh", prompt: "幫我改這個函式")
    #expect(miss.code == 0 && !miss.stubInvoked && miss.out.isEmpty)
    let always = try runHook("ltm-recall-gate.sh", prompt: "幫我改這個函式", env: ["LTM_RECALL_MODE": "always"])
    #expect(always.code == 0 && always.stubInvoked && always.out.hasPrefix("<!-- ltm:recall"))
    let off = try runHook("ltm-recall-gate.sh", prompt: "上次那個 flock 的決定是什麼", env: ["LTM_RECALL_MODE": "off"])
    #expect(off.code == 0 && !off.stubInvoked && off.out.isEmpty)
    let bogus = try runHook("ltm-recall-gate.sh", prompt: "上次那個 flock 的決定是什麼", env: ["LTM_RECALL_MODE": "bogus"])
    #expect(bogus.code == 0 && bogus.stubInvoked && bogus.out.hasPrefix("<!-- ltm:recall"))
}

@Test("別的 hook 注入的 system-reminder 不能觸發回想；呼叫參數帶 session 排除與預算")
func systemReminderSpansDoNotTriggerAndArgumentsAreWired() throws {
    let injected = try runHook(
        "ltm-recall-gate.sh", prompt: "幫我改這個函式 <system-reminder>earlier we said</system-reminder>")
    #expect(injected.code == 0 && !injected.stubInvoked && injected.out.isEmpty)
    // Claude Code 自己產生的 prompt（skill 本文／slash 展開／compaction 續接）即使含線索也不放行。
    for synthetic in ["Base directory for this skill: /x\n\n之前", "<command-message>idd</command-message>\n上次", "This session is being continued from a previous conversation. earlier"] {
        let run = try runHook("ltm-recall-gate.sh", prompt: synthetic, env: ["LTM_RECALL_MODE": "always"])
        #expect(run.code == 0 && !run.stubInvoked && run.out.isEmpty, Comment(rawValue: synthetic))
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-hook-args-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stub = try makeStub(kind: "block", in: dir)
    _ = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", session: "sess-42", env: ["LTM_BIN": stub.path])
    let args = try String(contentsOf: dir.appendingPathComponent("invoked"), encoding: .utf8)
        .components(separatedBy: "\n")
    #expect(args.contains("--exclude-session") && args.contains("sess-42"))
    #expect(args.contains("--format") && args.contains("recall") && args.contains("--max-refresh-seconds"))
    #expect(args.contains("--k") && args.contains("3"))
}

@Test("降級可見：逾時／非零結束／binary 缺席／不支援 --format，各印一行通知、exit 0")
func degradationIsOneVisibleLineAndNeverBlocks() throws {
    for (kind, reason) in [("sleep", "逾時"), ("exit2", "結束碼 2"), ("nofmt", "版本過舊")] {
        let run = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", stub: kind)
        #expect(run.code == 0, Comment(rawValue: kind))
        let lines = run.out.split(separator: "\n")
        #expect(lines.count == 1, Comment(rawValue: "\(kind): \(run.out)"))
        #expect(run.out.hasPrefix("ltm：本輪回想未完成（") && run.out.contains(reason) && run.out.contains("ltm_query"), Comment(rawValue: "\(kind): \(run.out)"))
    }
    let absent = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", stub: nil)
    #expect(absent.code == 0 && absent.out.split(separator: "\n").count == 1 && absent.out.contains("未安裝"))
}

@Test("線索表讀不到就整個 fail closed：不回想、stdout 空、stderr 指名路徑一次")
func unreadableCueFileFailsClosed() throws {
    let run = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", env: ["LTM_RECALL_CUES": "/nonexistent/cues.txt"])
    #expect(run.code == 0 && !run.stubInvoked && run.out.isEmpty)
    #expect(run.err.components(separatedBy: "/nonexistent/cues.txt").count == 2, Comment(rawValue: run.err))
    let custom = FileManager.default.temporaryDirectory.appendingPathComponent("cues-\(UUID().uuidString).txt")
    try "deploy\n".write(to: custom, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: custom) }
    let admitted = try runHook("ltm-recall-gate.sh", prompt: "please deploy it", env: ["LTM_RECALL_CUES": custom.path])
    #expect(admitted.stubInvoked)
    let notAdmitted = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", env: ["LTM_RECALL_CUES": custom.path])
    #expect(!notAdmitted.stubInvoked)
}

@Test("SessionStart 對每種 source 都印一行含 ltm_query，且不跑 ltm")
func sessionStartRemindsForEverySource() throws {
    for source in ["startup", "resume", "clear", "compact"] {
        let input = "{\"session_id\":\"s\",\"cwd\":\"/tmp\",\"hook_event_name\":\"SessionStart\",\"source\":\"\(source)\"}"
        let run = try runHook("ltm-session-start.sh", prompt: "", input: input)
        #expect(run.code == 0 && run.out.split(separator: "\n").count == 1 && run.out.contains("ltm_query"), Comment(rawValue: source))
        #expect(!run.stubInvoked)
    }
}
