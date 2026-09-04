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
    env extra: [String: String] = [:], input override: String? = nil, guard guardSeconds: String = "8"
) throws -> HookRun {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-hook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var environment = ProcessInfo.processInfo.environment
    environment["CLAUDE_PLUGIN_ROOT"] = repoRoot().appendingPathComponent("plugin").path
    environment["LTM_RECALL_MODE"] = nil
    environment["LTM_RECALL_CUES"] = nil
    environment["LTM_RECALL_GUARD_SECONDS"] = guardSeconds   // 預設 8 s：負載餘裕，瞬時 stub 不受影響；測逾時者自設小值
    environment["LTM_RECALL_STATS_FILE"] = dir.appendingPathComponent("stats").path
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
    for synthetic in ["Base directory for this skill: /x\n\n之前", "<command-message>idd</command-message>\n上次", "This session is being continued from a previous conversation. earlier", "(Re-invocation of /idd-verify — the previously loaded copy", "Stop hook feedback:\n上次 flock"] {
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
    // prompt 在 `--` 之後，且是最後一個引數（verify R1 logic M3／security S4）。
    let dd = try #require(args.firstIndex(of: "--"))
    #expect(args[dd + 1] == "上次 flock" && dd + 2 >= args.count - 1)
}

@Test("降級可見：逾時／非零結束／binary 缺席／不支援 --format，各印一行通知、exit 0")
func degradationIsOneVisibleLineAndNeverBlocks() throws {
    for (kind, reason) in [("sleep", "逾時"), ("exit2", "結束碼 2"), ("nofmt", "版本過舊")] {
        let run = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", session: "sess-\(kind)-\(UUID().uuidString)", stub: kind, guard: kind == "sleep" ? "2" : "8")
        #expect(run.code == 0, Comment(rawValue: kind))
        let lines = run.out.split(separator: "\n")
        #expect(lines.count == 1, Comment(rawValue: "\(kind): \(run.out)"))
        #expect(run.out.hasPrefix("ltm：本輪回想未完成（") && run.out.contains(reason) && run.out.contains("ltm_query"), Comment(rawValue: "\(kind): \(run.out)"))
    }
    let absent = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", stub: nil)
    #expect(absent.code == 0 && absent.out.split(separator: "\n").count == 1 && absent.out.contains("未安裝"), Comment(rawValue: "code=\(absent.code) out=[\(absent.out)] err=[\(absent.err)]"))
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

// MARK: - verify R1 findings 5／7／10／13：整支腳本的 deadline、輸入驗證、每 session 一次的版本通知

@Test("LTM_BIN 是相對路徑／cwd 進不去／python3 缺席／session_id 含換行，各是一行通知、exit 0、不執行 stub")
func inputValidationDegradesVisibly() throws {
    let rel = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", env: ["LTM_BIN": "./ltm"])
    #expect(rel.code == 0 && !rel.stubInvoked && rel.out.contains("絕對路徑"), Comment(rawValue: rel.out))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-hook-cwd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stub = try makeStub(kind: "block", in: dir)
    let badCwd = "{\"session_id\":\"s\",\"cwd\":\"/nonexistent/dir/\(UUID().uuidString)\",\"prompt\":\"上次 flock\"}"
    let cwd = try runHook("ltm-recall-gate.sh", prompt: "", env: ["LTM_BIN": stub.path], input: badCwd)
    #expect(cwd.code == 0 && cwd.out.contains("工作目錄") && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("invoked").path), Comment(rawValue: cwd.out))
    let tdnopy = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-nopy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tdnopy, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tdnopy) }
    let nopy = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", env: ["LTM_RECALL_PYTHON": "/nonexistent/python3", "TMPDIR": tdnopy.path + "/"])
    #expect(nopy.code == 0 && !nopy.stubInvoked && nopy.out.isEmpty && nopy.err.contains("python3"), Comment(rawValue: "out=[\(nopy.out)] err=[\(nopy.err)]"))
    let nl = "{\"session_id\":\"S1\\n/etc\",\"cwd\":\"/tmp\",\"prompt\":\"上次 flock\"}"
    let injected = try runHook("ltm-recall-gate.sh", prompt: "", env: ["LTM_BIN": stub.path], input: nl)
    // session_id 不合法 → 當作沒有 session（不傳 --exclude-session），cwd 仍是 /tmp、照常查詢。
    #expect(injected.code == 0 && injected.out.hasPrefix("<!-- ltm:recall"), Comment(rawValue: injected.out))
    let args = try String(contentsOf: dir.appendingPathComponent("invoked"), encoding: .utf8).components(separatedBy: "\n")
    #expect(!args.contains("--exclude-session"))
}

@Test("版本過舊只在每個 session 第一次通知，之後同 session 靜默；不同 session 再通知")
func oldBinaryNoticeIsOncePerSession() throws {
    let session = "sess-old-\(UUID().uuidString)"
    let first = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", session: session, stub: "nofmt")
    #expect(first.out.contains("版本過舊") && first.out.contains("只提醒一次"))
    let second = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", session: session, stub: "nofmt")
    #expect(second.code == 0 && second.out.isEmpty, Comment(rawValue: second.out))
    let other = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", session: "sess-other-\(UUID().uuidString)", stub: "nofmt")
    #expect(other.out.contains("版本過舊"))
}

@Test("--help 探測卡住也在 deadline 內：一行「版本探測逾時」通知，不撞外層 timeout")
func helpProbeIsBounded() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-hook-help-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("ltm")
    try "#!/bin/bash\nif [ \"$1\" = query ] && [ \"$2\" = --help ]; then sleep 25; fi\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    let t0 = Date()
    let run = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", env: ["LTM_BIN": url.path], guard: "2")
    #expect(run.code == 0 && run.out.contains("版本探測逾時"), Comment(rawValue: run.out))
    #expect(Date().timeIntervalSince(t0) < 6)
}

@Test("統計檔只記封閉集合的類別標籤，不含 prompt 文字")
func statsFileRecordsOnlyClosedSetLabels() throws {
    let stats = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-stats-\(UUID().uuidString)")
    _ = try runHook("ltm-recall-gate.sh", prompt: "上次 flock 秘密字串", env: ["LTM_RECALL_STATS_FILE": stats.path])
    _ = try runHook("ltm-recall-gate.sh", prompt: "幫我改函式 秘密字串", env: ["LTM_RECALL_STATS_FILE": stats.path])
    _ = try runHook("ltm-recall-gate.sh", prompt: "Stop hook feedback: 上次", env: ["LTM_RECALL_STATS_FILE": stats.path])
    let lines = try String(contentsOf: stats, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(lines.map { $0.split(separator: " ").last.map(String.init) ?? "" } == ["hit", "miss", "synthetic"], Comment(rawValue: lines.joined(separator: " | ")))
    #expect(!lines.joined().contains("秘密"))
}

// MARK: - verify R2 findings N2/N3/N7：便宜的 raw 閘門、未命中不通知、輸出驗證

@Test("python 缺席＝無法閘門＝安靜未命中（不論有無線索），不對每輪 prompt 注入通知（verify R3 codex #2）")
func pythonAbsentIsSilentMissNotAPerTurnNotice() throws {
    // nopython 提醒去重粒度是 $TMPDIR，所以每次給獨立 TMPDIR 才能觀察到 first-time 的 stderr。
    let td1 = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-nopy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: td1, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: td1) }
    let first = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", env: ["LTM_RECALL_PYTHON": "/nonexistent/python3", "TMPDIR": td1.path + "/"])
    #expect(first.code == 0 && first.out.isEmpty, Comment(rawValue: "out=[\(first.out)] err=[\(first.err)]"))
    #expect(first.err.contains("python3"), Comment(rawValue: first.err))
    let td2 = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-nopy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: td2, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: td2) }
    let miss = try runHook("ltm-recall-gate.sh", prompt: "幫我改這個函式", env: ["LTM_RECALL_PYTHON": "/nonexistent/python3", "TMPDIR": td2.path + "/"])
    #expect(miss.code == 0 && miss.out.isEmpty, Comment(rawValue: "out=[\(miss.out)]"))
}

@Test("查詢 exit 0 但輸出不是區塊：通知，不靜默 cat 空檔（N7）")
func emptyQueryOutputStillDegradesVisibly() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-hook-empty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("ltm")
    try "#!/bin/bash\nif [ \"$1 $2\" = \"query --help\" ]; then echo '--format recall'; exit 0; fi\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    let run = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", env: ["LTM_BIN": url.path])
    #expect(run.code == 0 && run.out.contains("回想區塊"), Comment(rawValue: "code=\(run.code) out=[\(run.out)] err=[\(run.err)]"))
}

@Test("LTM_RECALL_GUARD_SECONDS 被 clamp 在 manifest 的 28 s 以下：設 60 也不會晚於外層逾時")
func guardIsClampedBelowManifestTimeout() throws {
    // 用一個 query 睡很久的 stub，設 GUARD=60：若沒有 clamp，內部 deadline 會晚於 28 s。
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-hook-clamp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("ltm")
    try "#!/bin/bash\nif [ \"$1 $2\" = \"query --help\" ]; then echo '--format recall'; exit 0; fi\nsleep 60\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    // manifest=5、guard=60 → clamp 到 2 → 快速逾時（不必真的等 25 s）。
    let t0 = Date()
    let run = try runHook("ltm-recall-gate.sh", prompt: "上次 flock",
        env: ["LTM_BIN": url.path, "LTM_RECALL_GUARD_SECONDS": "60", "LTM_RECALL_MANIFEST_TIMEOUT": "5"])
    #expect(run.code == 0 && run.out.contains("逾時"), Comment(rawValue: run.out))
    #expect(Date().timeIntervalSince(t0) < 5, "clamp 失效：跑了 \(Date().timeIntervalSince(t0)) s（應 clamp 到 2）")
}

@Test("verify R2 security N-S1：cue 檔是 fifo（非一般檔案）→ fail closed，不阻塞、不通知")
func nonRegularCueFileFailsClosedFast() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-hook-fifo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let fifo = dir.appendingPathComponent("cuefifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let t0 = Date()
    // 無人寫 fifo：若 grep 直接讀它會永久阻塞。regular-file 檢查要在讀之前擋掉。
    let run = try runHook("ltm-recall-gate.sh", prompt: "之前討論過的事", env: ["LTM_RECALL_CUES": fifo.path])
    #expect(run.code == 0 && run.out.isEmpty, Comment(rawValue: "out=[\(run.out)]"))
    #expect(Date().timeIntervalSince(t0) < 6, "非一般 cue 檔應快速 fail closed（不卡在 fifo），卻跑了 \(Date().timeIntervalSince(t0)) s")
    #expect(run.err.contains("不是可讀的一般檔案"), Comment(rawValue: run.err))
}

@Test("verify R2 logic finding 2：\\uXXXX 逃脫的 JSON 裡的中文線索仍會觸發（raw grep 未命中但含 \\u → 落到 python）")
func escapedUnicodeCueStillTriggers() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-hook-esc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("ltm")
    try "#!/bin/bash\nif [ \"$1 $2\" = \"query --help\" ]; then echo '--format recall'; exit 0; fi\nprintf '<!-- ltm:recall v1 -->\\nB\\n1. [p] t\\n   s\\n   ↳ session x  turn u\\n<!-- /ltm:recall -->\\n'\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    // \uXXXX 逃脫的 JSON（Python json.dumps ensure_ascii=True 的形狀）——中文線索的 bytes 是 之前，
    // stage-1 raw grep 對不上，但輸入含 \u → fallback 到 python → stage-2 對解碼後的 prompt 命中。
    let escaped = "{\"prompt\":\"\\u4e4b\\u524d\\u90a3\\u500b\\u6c7a\\u5b9a\",\"session_id\":\"s1\",\"cwd\":\"\(dir.path)\"}"
    let run = try runHook("ltm-recall-gate.sh", prompt: "", env: ["LTM_BIN": url.path], input: escaped)
    #expect(run.code == 0 && run.out.hasPrefix("<!-- ltm:recall"), Comment(rawValue: "out=[\(run.out)] err=[\(run.err)]"))
    // 對照：全 ASCII、無 \u、無線索 → 終止未命中（快退、空）。
    let ascii = "{\"prompt\":\"just fix this function\",\"session_id\":\"s1\",\"cwd\":\"\(dir.path)\"}"
    let miss = try runHook("ltm-recall-gate.sh", prompt: "", env: ["LTM_BIN": url.path], input: ascii)
    #expect(miss.code == 0 && miss.out.isEmpty, Comment(rawValue: miss.out))
}


@Test("verify R3 codex #1：閘門對解碼後 prompt，錨點線索 `^上次` 在 JSON 裡不在行首也命中")
func anchoredCueMatchesDecodedPrompt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-hook-anchor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cues = dir.appendingPathComponent("cues.txt"); try "^上次\n".write(to: cues, atomically: true, encoding: .utf8)
    let ltm = dir.appendingPathComponent("ltm")
    try "#!/bin/bash\nif [ \"$1 $2\" = \"query --help\" ]; then echo '--format recall'; exit 0; fi\nprintf '<!-- ltm:recall v1 -->\\nB\\n1. [p] t\\n   s\\n   ↳ session x  turn u\\n<!-- /ltm:recall -->\\n'\n".write(to: ltm, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ltm.path)
    // prompt「上次 flock」在 JSON 裡是 `{"prompt":"上次 flock",...}`——`^上次` 對整份 JSON 不在行首，
    // 但對**解碼後的 prompt**（開頭就是「上次」）命中。這正是 raw-grep prefilter 會漏、decoded gate 不漏的例子。
    let run = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", env: ["LTM_BIN": ltm.path, "LTM_RECALL_CUES": cues.path])
    #expect(run.code == 0 && run.out.hasPrefix("<!-- ltm:recall"), Comment(rawValue: "out=[\(run.out)] err=[\(run.err)]"))
}

@Test("verify R3 codex #4：查詢輸出未閉合（缺結束標記）→ 通知，不注入不完整區塊")
func unterminatedBlockIsRejected() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-hook-unterm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let ltm = dir.appendingPathComponent("ltm")
    // help 說支援；query 印開標記 + payload 但**沒有**閉標記。
    try "#!/bin/bash\nif [ \"$1 $2\" = \"query --help\" ]; then echo '--format recall'; exit 0; fi\nprintf '<!-- ltm:recall v1 -->\\nunclosed payload\\n'\n".write(to: ltm, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ltm.path)
    let run = try runHook("ltm-recall-gate.sh", prompt: "上次 flock", env: ["LTM_BIN": ltm.path])
    #expect(run.code == 0 && run.out.contains("完整的回想區塊") && !run.out.contains("unclosed"), Comment(rawValue: run.out))
}
