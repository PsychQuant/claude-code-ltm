import Foundation
import Testing

/// #63：基準查詢集是一份**資料檔**，它的契約是「不被儀器自己污染」——這些測試釘的是契約
/// 的可機械檢查部分：檔頭寫明三件事、條數夠、不含已退役（已被量測命令污染）的查詢、
/// 量測腳本的**每一個守衛都有一條測試扛**（invocation 形狀、stdin、字母表、離開碼、xtrace）。
///
/// 退役查詢以字面寫在這裡是刻意的：它們已經在語料裡（#63 的 root cause），再多出現一次不改變
/// 什麼；而新查詢**不**出現在任何測試或訊息裡——測試只讀檔、只斷言性質，而且斷言一律先算成
/// Bool／索引再 `#expect`，讓失敗訊息的展開式裡**沒有查詢原文**（swift-testing 會把接收者的值
/// 印出來；`#expect(!q.contains(r))` 失敗時 q 會整條落進測試輸出，那是一條洩漏路徑）。
private func repoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
}

/// 六條全部來自 `docs/measurements/2026-09-01-scan-parallelism.md` 的 after 輪命令列（#63）。
private let retired = ["tokenizer 討論", "flock inode 鎖", "資格考", "band 相關度", "memory strategy", "並行雜湊"]

/// 與 `measure-baseline.sh` 同一個「第 N 條非註解行」定義：去 CR、去前後空白後，空行與 `#` 開頭都不算。
private func nonCommentLines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

@Test("baseline-queries.txt：檔頭三件事、≥6 條、無重複、不含六條退役查詢（失敗訊息只帶序號）")
func baselineQueryFileDocumentsItsContractAndRetiresThePollutedQueries() throws {
    let url = repoRoot().appendingPathComponent("scripts/baseline-queries.txt")
    let text = try String(contentsOf: url, encoding: .utf8)
    let header = text.split(separator: "\n").filter { $0.hasPrefix("#") }.joined(separator: "\n")
    for phrase in ["列舉", "會漏", "不得在 Claude Code session 內顯示", "只印編號", "text", "toolMetadataFields"] {
        #expect(header.contains(phrase), Comment(rawValue: "檔頭缺：\(phrase)"))
    }
    let queries = nonCommentLines(text)
    #expect(queries.count >= 6, "基準查詢至少 6 條，得 \(queries.count)")
    #expect(Set(queries).count == queries.count, "查詢重複")
    let offenders = queries.indices.filter { i in retired.contains { queries[i].contains($0) } }.map { $0 + 1 }
    #expect(offenders.isEmpty, Comment(rawValue: "含退役查詢的條目序號：\(offenders)"))
}

// MARK: - measure-baseline.sh

private struct ScriptRun {
    let status: Int32
    let stdout: String
    let stderr: String
    var lines: [String] { stdout.split(separator: "\n").map(String.init) }
    var combined: String { stdout + stderr }
}

private let verdictLine = #"^#[0-9]+ [0-9]+ms ((clean|self|empty) tool=[0-9]+|error\([0-9a-z]+\))$"#

/// `#N <ms>ms ` 之後的全部（verdict 含 `tool=<n>`）。
private func tail(_ line: String) -> String {
    line.split(separator: " ", maxSplits: 2).last.map(String.init) ?? ""
}

/// 建一個把 argv 記到 `argv.log`、先把 stdin 讀光、再依查詢（最後一個參數）回應的 stub。
/// `cat >/dev/null` 是刻意的：腳本若沒把 ltm 的 stdin 接到 /dev/null，stub 會把查詢檔剩下的行
/// 吃掉，列數就少了——這條守衛靠它驅動。
private func makeStub(in dir: URL, responses: [String: String], exits: [String: Int32] = [:]) throws -> URL {
    let stub = dir.appendingPathComponent("ltm")
    let log = dir.appendingPathComponent("argv.log").path
    var cases = ""
    for (q, body) in responses.sorted(by: { $0.key < $1.key }) {
        cases += "  \"\(q)\") printf '%s\\n' '\(body)' ;;\n"
    }
    for (q, code) in exits.sorted(by: { $0.key < $1.key }) {
        cases += "  \"\(q)\") exit \(code) ;;\n"
    }
    try """
    #!/bin/bash
    cat >/dev/null
    printf '%s\\x1f' "$@" >> '\(log)'; printf '\\n' >> '\(log)'
    q="${@: -1}"
    case "$q" in
    \(cases)  *) printf '[{"snippet":"一段實質內容","uuid":"u"}]\\n' ;;
    esac
    """.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    return stub
}

private func runScript(queries: URL, stub: URL, k: String = "3", viaBashX: Bool = false,
                       ltmBinOverride: String? = nil, pathPrefix: String? = nil,
                       extraEnv: [String: String] = [:]) throws -> ScriptRun {
    let script = repoRoot().appendingPathComponent("scripts/measure-baseline.sh")
    let process = Process()
    if viaBashX {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-x", script.path, k]
    } else {
        process.executableURL = script
        process.arguments = [k]
    }
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "LTM_ANCHOR_KEY")
    env["LTM_BIN"] = ltmBinOverride ?? stub.path
    env["LTM_BASELINE_QUERIES"] = queries.path
    if let pathPrefix { env["PATH"] = pathPrefix + ":" + (env["PATH"] ?? "/usr/bin:/bin") }
    for (k, v) in extraEnv { env[k] = v }
    process.environment = env
    let out = Pipe(), err = Pipe()
    process.standardOutput = out; process.standardError = err
    try process.run(); process.waitUntilExit()
    return ScriptRun(
        status: process.terminationStatus,
        stdout: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-baseline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test("measure-baseline.sh：invocation 形狀固定、行定義與測試一致、clean/self/empty 與 tool=<n> 各自會動、輸出不含查詢與命中")
func measureBaselinePrintsOnlyIndicesAndVerdicts() throws {
    let script = repoRoot().appendingPathComponent("scripts/measure-baseline.sh")
    let attrs = try FileManager.default.attributesOfItem(atPath: script.path)
    #expect(((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0, "腳本沒有執行位元")

    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // 合成檔（不碰真檔）：縮排註解與純空白行都不算條目；CRLF 與尾隨空白要被剝掉。
    // #1 乾淨（實質命中、無工具 chunk）；#2 self：查詢原文在散文之後的工具殘影裡（tool=1）；
    // #3 self：查詢原文被引述進散文、空白摺疊後才對得上、沒有工具標記（tool=0）；#4 零命中；
    // #5 兩個工具 chunk 但都不含查詢原文 → clean tool=2（工具 chunk 本身不是污染訊號，DA C1）。
    let queries = dir.appendingPathComponent("q.txt")
    try "# header\n   # indented comment\nZQXJ-CLEAN-ONE\n   \nZQXJ-SELF-TWO\r\n  ZQXJ QUOTE THREE  \nZQXJ-EMPTY-FOUR\nZQXJ-TOOLONLY-FIVE\n"
        .write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [
        "ZQXJ-SELF-TWO": #"[{"snippet":"先說明一下\n⟨tool Bash command=ltm query ZQXJ-SELF-TWO --k 5⟩","uuid":"u"},{"snippet":"別的","uuid":"v"}]"#,
        "ZQXJ QUOTE THREE": #"[{"snippet":"使用者說：第三條是 ZQXJ  QUOTE\nTHREE 沒錯","uuid":"u"}]"#,
        "ZQXJ-EMPTY-FOUR": "[]",
        "ZQXJ-TOOLONLY-FIVE": #"[{"snippet":"⟨tool Bash command=swift test⟩","uuid":"u"},{"snippet":"⟨tool Read file_path=x⟩","uuid":"v"}]"#,
    ])

    let run = try runScript(queries: queries, stub: stub)
    #expect(run.status == 0, Comment(rawValue: "rc=\(run.status) err=\(run.stderr)"))
    #expect(run.lines.count == 5, Comment(rawValue: run.stdout))
    #expect(run.lines.allSatisfy { $0.range(of: verdictLine, options: .regularExpression) != nil }, Comment(rawValue: run.stdout))
    #expect(run.lines.map(tail) == ["clean tool=0", "self tool=1", "self tool=0", "empty tool=0", "clean tool=2"], Comment(rawValue: run.stdout))
    #expect(run.lines.map { $0.prefix(3) } == ["#1 ", "#2 ", "#3 ", "#4 ", "#5 "], Comment(rawValue: run.stdout))
    // 查詢文字與 snippet 都不得出現在任何輸出。
    #expect(!run.combined.contains("ZQXJ") && !run.combined.contains("實質內容") && !run.combined.contains("說明"))

    // ltm 每次都收到同一個形狀：query --all-projects --k <k> --json -- <去掉 CR 與前後空白的查詢>。
    let log = try String(contentsOf: dir.appendingPathComponent("argv.log"), encoding: .utf8)
    let calls = log.split(separator: "\n").map { $0.split(separator: "\u{1f}", omittingEmptySubsequences: false).dropLast().map(String.init) }
    let expected = ["ZQXJ-CLEAN-ONE", "ZQXJ-SELF-TWO", "ZQXJ QUOTE THREE", "ZQXJ-EMPTY-FOUR", "ZQXJ-TOOLONLY-FIVE"]
        .map { ["query", "--all-projects", "--k", "3", "--json", "--", $0] }
    #expect(calls == expected, Comment(rawValue: log))
}

@Test("measure-baseline.sh：error 字母表封閉、每列照印、任一 error 以 1 離開；stderr 不帶 traceback 也不帶查詢")
func measureBaselineReportsEveryFailureAndExitsNonZero() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-RC-SEVEN\nZQXJ-NONJSON\nZQXJ-OBJECT\nZQXJ-STRINGS\nZQXJ-OK\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [
        "ZQXJ-NONJSON": "not json at all",
        "ZQXJ-OBJECT": #"{"hits":[{"snippet":"⟨tool x⟩"}]}"#,
        "ZQXJ-STRINGS": #"["⟨tool x⟩"]"#,
    ], exits: ["ZQXJ-RC-SEVEN": 7])

    let run = try runScript(queries: queries, stub: stub)
    #expect(run.status == 1, Comment(rawValue: "rc=\(run.status) out=\(run.stdout) err=\(run.stderr)"))
    #expect(run.lines.map(tail) == ["error(7)", "error(json)", "error(shape)", "error(shape)", "clean tool=0"], Comment(rawValue: run.stdout))
    #expect(run.lines.allSatisfy { $0.range(of: verdictLine, options: .regularExpression) != nil }, Comment(rawValue: run.stdout))
    #expect(!run.combined.contains("ZQXJ") && !run.combined.contains("Traceback"), Comment(rawValue: run.stderr))
}

@Test("measure-baseline.sh：judge 自己掛掉 → 該列 error(judge)、以 1 離開，judge 的 stderr 不外流")
func measureBaselineContainsAJudgeCrash() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-ONE\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [:])
    // PATH 最前面放一個會崩的 python3：模擬 judge 拋例外（traceback 進 stderr、非零離開）。
    let fakeBin = dir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    let fakePython = fakeBin.appendingPathComponent("python3")
    try "#!/bin/bash\necho 'Traceback (most recent call last): ZQXJ-JUDGE' >&2\nexit 1\n"
        .write(to: fakePython, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePython.path)

    let run = try runScript(queries: queries, stub: stub, pathPrefix: fakeBin.path)
    #expect(run.status == 1, Comment(rawValue: "rc=\(run.status) out=\(run.stdout)"))
    #expect(run.lines == ["#1 0ms error(judge)"], Comment(rawValue: run.stdout))
    #expect(!run.combined.contains("ZQXJ") && !run.combined.contains("Traceback"), Comment(rawValue: run.stderr))
}

@Test("measure-baseline.sh：前置守衛各自有離開碼——k 越界 64、只有註解 65、LTM_BIN 是目錄 69")
func measureBaselinePreflightGuardsHaveDistinctExitCodes() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-ONE\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [:])

    #expect(try runScript(queries: queries, stub: stub, k: "0").status == 64)
    #expect(try runScript(queries: queries, stub: stub, k: "1001").status == 64)
    #expect(try runScript(queries: queries, stub: stub, k: "x").status == 64)
    #expect(try runScript(queries: queries, stub: stub, ltmBinOverride: dir.path).status == 69)
    let onlyComments = dir.appendingPathComponent("c.txt")
    try "# a\n\n   # b\n".write(to: onlyComments, atomically: true, encoding: .utf8)
    let run = try runScript(queries: onlyComments, stub: stub)
    #expect(run.status == 65 && run.stdout.isEmpty, Comment(rawValue: "rc=\(run.status) out=\(run.stdout)"))
}

@Test("measure-baseline.sh：`bash -x`／`SHELLOPTS=xtrace`／`BASH_ENV` 三條 xtrace 路徑都不漏——第一行就關掉")
func measureBaselineDoesNotLeakUnderXtrace() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-TRACE-ONE\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [
        "ZQXJ-TRACE-ONE": #"[{"snippet":"ZQXJ-SNIPPET 一段命中","uuid":"u"}]"#,
    ])
    let benv = dir.appendingPathComponent("benv.sh")
    try "set -x\n".write(to: benv, atomically: true, encoding: .utf8)
    let runs = [
        ("bash -x", try runScript(queries: queries, stub: stub, viaBashX: true)),
        ("SHELLOPTS", try runScript(queries: queries, stub: stub, extraEnv: ["SHELLOPTS": "xtrace"])),
        ("BASH_ENV", try runScript(queries: queries, stub: stub, extraEnv: ["BASH_ENV": benv.path])),
    ]
    for (label, run) in runs {
        #expect(run.status == 0, Comment(rawValue: "\(label): rc=\(run.status)"))
        #expect(run.lines.count == 1 && run.lines[0].hasSuffix(" clean tool=0"), Comment(rawValue: "\(label): \(run.stdout)"))
        let leaked = run.combined.contains("ZQXJ")
        #expect(!leaked, Comment(rawValue: "\(label): xtrace 漏了查詢或命中（stderr \(run.stderr.count) bytes）"))
    }
}
