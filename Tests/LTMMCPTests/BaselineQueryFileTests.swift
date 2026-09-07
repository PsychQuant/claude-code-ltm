import CryptoKit
import Foundation
import Testing

/// #63：基準查詢集是一份**資料檔**，它的契約是「不被儀器自己污染」——這些測試釘的是契約
/// 的可機械檢查部分：檔頭寫明三件事、條數夠、不含已退役（已被量測命令污染）的查詢、
/// 量測腳本的守衛各有一條測試扛。
///
/// 「各有一條測試扛」的查法就是變異測試：把腳本裡的一條守衛退掉、跑本檔、必須變紅。#63 verify
/// R2 的 logic lens 逐條退過 30 處，11 處綠——那 11 處在 R2 verify-fix 裡 9 處補上驅動它的測試
/// （error(exec)、error(sig<N>)、66 整行、`-r` 臂、`-x` 臂、70、最後一行沒換行、k 非數字的訊息、
/// snippet 非字串→shape）、2 處拆掉（`bool(q)`、python 端的 stderr=DEVNULL）。同一輪新加了執行期列
/// 形狀的守衛 `valid_row`，R3 再退一次後留下的每個分支各有一個假 python3 驅動（見 judge 測試）。
/// 這句話**只涵蓋那兩輪列出的守衛**；新加的守衛要自己再退一次。
///
/// 退役查詢以字面寫在這裡是刻意的：它們已經在語料裡（#63 的 root cause），再多出現一次不改變
/// 什麼；而新查詢**不**出現在任何測試或訊息裡——測試只讀檔、只斷言性質，而且對真檔的每一個
/// 斷言都先算成 Bool／索引再 `#expect`，讓失敗訊息的展開式裡**沒有檔案內容**（swift-testing 會把
/// 接收者的值印出來；`#expect(!q.contains(r))` 失敗時 q 會整條落進測試輸出，那是一條洩漏路徑）。
private func repoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
}

/// 六條全部來自 `docs/measurements/2026-09-01-scan-parallelism.md` 的 after 輪命令列（#63）。
private let retired = ["tokenizer 討論", "flock inode 鎖", "資格考", "band 相關度", "memory strategy", "並行雜湊"]

/// 腳本只剝 ASCII 空白（空格、tab、CR、VT、FF；LF 由 `read` 吃掉、這裡由切行吃掉，所以兩個集合
/// 差一個 LF 而行為相同）——刻意不用 `.whitespacesAndNewlines`，它含 U+3000／NBSP 等 Zs，而 bash 的
/// `[:space:]` 對那些字元隨 locale 變。兩邊都只認 ASCII，再加上下面對真檔「沒有非 ASCII 空白」的
/// 斷言，三邊就對得上。切行用 `components(separatedBy: "\n")`（UTF-16 層級）而不是
/// `split(separator: "\n")`：後者把 CRLF 當一個 grapheme、不在它中間切，CRLF 檔會被算成一行。
private let asciiWhitespace = CharacterSet(charactersIn: " \t\r\n\u{0B}\u{0C}")

/// 與 `measure-baseline.sh` 同一個「第 N 條非註解行」定義。
private func nonCommentLines(_ text: String) -> [String] {
    text.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: asciiWhitespace) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// 非 ASCII 的空白類字元：任何一個出現在查詢檔裡，腳本與測試的行定義就可能分岔。
private let nonASCIIWhitespace: Set<Unicode.Scalar> = [
    "\u{00A0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}",
    "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}",
    "\u{205F}", "\u{3000}", "\u{FEFF}", "\u{0085}",
]

@Test("baseline-queries.txt：檔頭三件事、≥6 條、無重複、不含六條退役查詢、無非 ASCII 空白（失敗訊息只帶序號）")
func baselineQueryFileDocumentsItsContractAndRetiresThePollutedQueries() throws {
    let url = repoRoot().appendingPathComponent("scripts/baseline-queries.txt")
    let text = try String(contentsOf: url, encoding: .utf8)
    let header = text.split(separator: "\n").filter { $0.hasPrefix("#") }.joined(separator: "\n")
    for phrase in ["列舉", "會漏", "不得在 Claude Code session 內顯示", "只印編號", "text", "toolMetadataFields"] {
        let present = header.contains(phrase)
        #expect(present, Comment(rawValue: "檔頭缺：\(phrase)"))
    }
    let queries = nonCommentLines(text)
    let count = queries.count, distinct = Set(queries).count
    #expect(count >= 6, "基準查詢至少 6 條，得 \(count)")
    #expect(distinct == count, "查詢重複：\(count - distinct) 條")
    let offenders = queries.indices.filter { i in retired.contains { queries[i].contains($0) } }.map { $0 + 1 }
    #expect(offenders.isEmpty, Comment(rawValue: "含退役查詢的條目序號：\(offenders)"))
    let oddWhitespaceLines = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        .filter { $0.element.unicodeScalars.contains { nonASCIIWhitespace.contains($0) } }.map { $0.offset + 1 }
    #expect(oddWhitespaceLines.isEmpty, Comment(rawValue: "含非 ASCII 空白的行號：\(oddWhitespaceLines)"))
}

// MARK: - measure-baseline.sh

/// verdict 字母表的 error token（封閉集合）。同步測試把它與腳本檔頭、README、腳本的輸出點對照。
private let errorTokens = ["<rc>", "sig<N>", "blank", "exec", "json", "shape", "judge"]
private let errorTokenRegex = errorTokens.map { $0 == "<rc>" ? "[0-9]+" : $0 == "sig<N>" ? "sig[0-9]+" : $0 }.joined(separator: "|")
private let verdictLine = "^#[0-9]+ [0-9]+ms ((clean|self|empty) tool=[0-9]+|error\\((\(errorTokenRegex))\\))$"

@Test("字母表同步：腳本檔頭、ERROR_TOKENS、README、測試的 errorTokens、腳本輸出點五處逐一相等（認不出的輸出形狀直接紅）；CHANGELOG 三個 verdict 詞在；退役清單 README 與測試一致")
func verdictAlphabetIsStatedIdenticallyEverywhere() throws {
    let root = repoRoot()
    let script = try String(contentsOf: root.appendingPathComponent("scripts/measure-baseline.sh"), encoding: .utf8)
    let readme = try String(contentsOf: root.appendingPathComponent("docs/measurements/README.md"), encoding: .utf8)
    let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
    let scriptLines = script.components(separatedBy: "\n")

    // 1. 腳本檔頭的「error tokens：」那一行。
    let headerLine = scriptLines.first { $0.hasPrefix("#   error tokens：") }
    let headerTokens = Set((headerLine ?? "").replacingOccurrences(of: "#   error tokens：", with: "")
        .split(separator: " ").map(String.init))
    // 2. 腳本裡的 ERROR_TOKENS（valid_row 執行期用的字面集合）＝ errorTokens 扣掉兩個樣式 token。
    let errorTokensLine = scriptLines.first { $0.hasPrefix("ERROR_TOKENS=\"") }
    let runtimeLiterals = Set((errorTokensLine ?? "").dropFirst("ERROR_TOKENS=\"".count).dropLast()
        .split(separator: " ").map(String.init))
    // 3. 腳本程式碼裡實際會印出的 error(...)：跳過註解行（去前導空白後以 # 開頭）與 valid_row 的
    //    函式本體（那裡是比對不是輸出）。每一個輸出點必須是字面 token、{rc} 或 sig{-rc}——別的形狀
    //    （例如 $var）不是「略過」而是失敗：略過就是 R2 的漏洞（用字元形狀當排除鍵）。
    var inValidRow = false
    var codeLines: [String] = []
    for line in scriptLines {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { continue }
        if t.hasPrefix("valid_row()") { inValidRow = true; continue }
        if inValidRow { if t == "}" { inValidRow = false }; continue }
        codeLines.append(line)
    }
    var emitted = Set<String>()
    var unrecognised: [String] = []
    for raw in matches(#"error\(([^)]*)\)"#, in: codeLines.joined(separator: "\n")) {
        switch raw {
        case "{rc}": emitted.insert("<rc>")
        case "sig{-rc}": emitted.insert("sig<N>")
        default:
            if raw.range(of: "^[a-z]+$", options: .regularExpression) != nil { emitted.insert(raw) } else { unrecognised.append(raw) }
        }
    }
    // 4. README 的字母表行：`error(<rc>|sig<N>|…)`。
    let readmeTokens = Set(matches(#"error\(([^)]*\|[^)]*)\)"#, in: readme).flatMap { $0.split(separator: "|").map(String.init) })
    // 5. 測試自己的 errorTokens。
    let expected = Set(errorTokens)
    let expectedLiterals = expected.subtracting(["<rc>", "sig<N>"])

    #expect(unrecognised.isEmpty, Comment(rawValue: "腳本裡認不出的 error(...) 輸出形狀（只准字面 token、{rc}、sig{-rc}）：\(unrecognised)"))
    #expect(headerTokens == expected, Comment(rawValue: "腳本檔頭：\(headerTokens.sorted())"))
    #expect(runtimeLiterals == expectedLiterals, Comment(rawValue: "ERROR_TOKENS：\(runtimeLiterals.sorted())"))
    #expect(emitted == expected, Comment(rawValue: "腳本輸出點：\(emitted.sorted())"))
    #expect(readmeTokens == expected, Comment(rawValue: "README：\(readmeTokens.sorted())"))

    // 每個 token 在測試檔裡有一個實際產生它的 expected tail（不只是集合相等）。
    let testSource = try String(contentsOf: URL(fileURLWithPath: "\(#filePath)"), encoding: .utf8)
    let producedLiterals = ["error(7)", "error(sig9)", "error(blank)", "error(exec)", "error(json)", "error(shape)", "error(judge)"]
    let missingProductions = producedLiterals.filter { !testSource.contains("\"" + $0 + "\"") && !testSource.contains("[\"" + $0) && !testSource.contains(", \"" + $0) }
    #expect(missingProductions.isEmpty, Comment(rawValue: "沒有測試產生：\(missingProductions)"))

    // 七個 metadata 欄位名：CorpusScanner 的常數、README 表、查詢檔檔頭三處同一份。
    let scanner = try String(contentsOf: root.appendingPathComponent("Sources/LTMIndex/CorpusScanner.swift"), encoding: .utf8)
    let constantBody = matches(#"static let toolMetadataFields = \[([^\]]*)\]"#, in: scanner).first ?? ""
    let constantFields = matches(#""([a-z_]+)""#, in: constantBody)
    let readmeFieldRow = readme.components(separatedBy: "\n").first { $0.contains("七個 metadata 欄位") && $0.hasPrefix("|") } ?? ""
    let readmeFirstCell = readmeFieldRow.components(separatedBy: "|").dropFirst().first ?? ""   // 只看「位置」那一格
    let readmeFields = matches(#"`([a-z_]+)`"#, in: readmeFirstCell).filter { $0 != "tool_use" }
    let queryHeader = try String(contentsOf: root.appendingPathComponent("scripts/baseline-queries.txt"), encoding: .utf8)
        .components(separatedBy: "\n").filter { $0.hasPrefix("#") }.joined(separator: "\n")
    // 檔頭那一段的形狀是「`CorpusScanner.toolMetadataFields`：a / b / … / g，各取前 200 字元」，可能跨行。
    let headerJoined = queryHeader.replacingOccurrences(of: "\n#", with: "").replacingOccurrences(of: " ", with: "")
    let headerFieldList = matches(#"toolMetadataFields`：([a-z_/]+)，各取前200字元"#, in: headerJoined).first ?? ""
    let headerFields = headerFieldList.split(separator: "/").map(String.init)
    #expect(constantFields.count == 7, Comment(rawValue: "常數：\(constantFields)"))
    #expect(Set(readmeFields) == Set(constantFields), Comment(rawValue: "README 表：\(readmeFields)"))
    #expect(Set(headerFields) == Set(constantFields), Comment(rawValue: "查詢檔檔頭少了：\(Set(constantFields).subtracting(headerFields).sorted())"))

    // 離開碼：檔頭那一行列的數字 ＝ 程式碼裡 exit 的數字 ∪ {0}。
    let exitHeaderLine = scriptLines.first { $0.hasPrefix("# 離開碼（") } ?? ""
    let headerExits = Set((exitHeaderLine.components(separatedBy: "：").last ?? "").split(separator: " ").compactMap { Int($0) })
    let codeExits = Set(matches(#"exit ([0-9]+)"#, in: codeLines.joined(separator: "\n")).compactMap { Int($0) }).union([0])
    #expect(headerExits == codeExits, Comment(rawValue: "檔頭：\(headerExits.sorted()) 程式碼：\(codeExits.sorted())"))

    // 退役清單：README 的「…」列與測試的 retired 陣列是同一份，不能各自漂移。
    let readmeRetiredLine = readme.components(separatedBy: "\n").first { $0.hasPrefix("「") && $0.contains("」「") } ?? ""
    let readmeRetired = Set(matches(#"「([^」]+)」"#, in: readmeRetiredLine))
    #expect(readmeRetired == Set(retired), Comment(rawValue: "README 退役清單：\(readmeRetired.sorted())"))
    // 先算成 Bool 再 #expect：失敗時不把整份檔案展開進測試輸出（同檔對真查詢檔的紀律）。
    let scriptNormalised = script.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    for word in ["clean tool=<n>", "self tool=<n>", "empty tool=0"] {
        let inReadme = readme.contains(word), inScript = scriptNormalised.contains(word)
        #expect(inReadme, Comment(rawValue: "README 缺 verdict：\(word)"))
        #expect(inScript, Comment(rawValue: "腳本檔頭缺 verdict：\(word)"))
    }
    let changelogHasWords = changelog.contains("clean|self|empty")
    #expect(changelogHasWords, "CHANGELOG 缺三個 verdict 詞")
}

private func matches(_ pattern: String, in text: String) -> [String] {
    let re = try! NSRegularExpression(pattern: pattern)
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
}

private struct ScriptRun {
    let status: Int32
    let stdout: String
    let stderr: String
    /// stdout 第一行是 `set sha256:<12 hex>`（查詢集指紋），之後才是列。
    var setLine: String { stdout.split(separator: "\n").first.map(String.init) ?? "" }
    var rows: [String] { Array(stdout.split(separator: "\n").map(String.init).dropFirst()) }
    var combined: String { stdout + stderr }
}

/// 與腳本同一個指紋：對非註解行（同一個 ASCII trim 定義）逐行 sha256（行＋"\n"），取前 12 個 hex。
private func setFingerprint(_ text: String) -> String {
    var h = SHA256()
    for line in nonCommentLines(text) { h.update(data: Data((line + "\n").utf8)) }
    return "set sha256:" + h.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
}

/// `#N <ms>ms ` 之後的全部（verdict 含 `tool=<n>`）。
private func tail(_ line: String) -> String {
    line.split(separator: " ", maxSplits: 2).last.map(String.init) ?? ""
}

/// 建一個把 argv 記到 `argv.log`、先把 stdin 讀光、再依查詢（最後一個參數）回應的 stub。
/// `cat >/dev/null` 是刻意的：腳本若沒把 ltm 的 stdin 接到 /dev/null，stub 會把查詢檔剩下的行
/// 吃掉，列數就少了——這條守衛靠它驅動。`raw` 是整段 bash，給訊號自殺這類回應用。
private func makeStub(in dir: URL, responses: [String: String], exits: [String: Int32] = [:],
                      raw: [String: String] = [:]) throws -> URL {
    let stub = dir.appendingPathComponent("ltm")
    let log = dir.appendingPathComponent("argv.log").path
    var cases = ""
    for (q, body) in responses.sorted(by: { $0.key < $1.key }) {
        cases += "  \"\(q)\") printf '%s\\n' '\(body)' ;;\n"
    }
    for (q, code) in exits.sorted(by: { $0.key < $1.key }) {
        cases += "  \"\(q)\") exit \(code) ;;\n"
    }
    for (q, body) in raw.sorted(by: { $0.key < $1.key }) {
        cases += "  \"\(q)\") \(body) ;;\n"
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
                       ltmBinOverride: String? = nil, pathOverride: String? = nil, pathPrefix: String? = nil,
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
    if let pathOverride { env["PATH"] = pathOverride }
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

/// 測試行程 PATH 上真正的 python3（假 python3 對非 judge 的呼叫要轉交給它）。
private func realPython3() -> String {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    for dir in path.split(separator: ":") {
        let candidate = "\(dir)/python3"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return "/usr/bin/python3"
}

/// 一個 PATH 目錄，只放腳本本身需要的外部命令（`dirname`）加上呼叫端指定的假命令。
/// `judgeFakes` 是假 python3 對 **judge 呼叫**（`python3 -c …`）的行為；其他呼叫（算查詢集指紋的
/// `python3 - <file>`）轉交真的 python3——要模擬的是 judge 掛掉，不是整個 python 壞掉。
private func makeBinDir(in dir: URL, judgeFakes: [String: String]) throws -> URL {
    let bin = dir.appendingPathComponent("bin-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("dirname"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/dirname"))
    for (name, body) in judgeFakes {
        let f = bin.appendingPathComponent(name)
        try "#!/bin/bash\nif [ \"$1\" = \"-c\" ]; then\n\(body)\nfi\nexec '\(realPython3())' \"$@\"\n".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    }
    return bin
}

@Test("measure-baseline.sh：invocation 形狀固定、行定義與測試一致、clean/self/empty 與 tool=<n> 各自會動、self 摺疊空白與大小寫、輸出不含查詢與命中")
func measureBaselinePrintsOnlyIndicesAndVerdicts() throws {
    let script = repoRoot().appendingPathComponent("scripts/measure-baseline.sh")
    let attrs = try FileManager.default.attributesOfItem(atPath: script.path)
    #expect(((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0, "腳本沒有執行位元")

    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // 合成檔（不碰真檔）：縮排註解與純空白行都不算條目；CRLF、tab 與尾隨空白要被剝掉；
    // 最後一行沒有換行也要量到。
    // #1 乾淨（實質命中、無工具 chunk）；#2 self：查詢原文在散文之後的工具殘影裡（tool=1）；
    // #3 self：查詢原文被引述進散文、空白摺疊後才對得上、沒有工具標記（tool=0）；#4 零命中；
    // #5 兩個工具 chunk 但都不含查詢原文 → clean tool=2（工具 chunk 本身不是污染訊號，DA C1）；
    // #6 self：只差大小寫（casefold）。
    let queries = dir.appendingPathComponent("q.txt")
    try "# header\n   # indented comment\nZQXJ-CLEAN-ONE\n   \nZQXJ-SELF-TWO\r\n\t ZQXJ QUOTE THREE  \nZQXJ-EMPTY-FOUR\nZQXJ-TOOLONLY-FIVE\nzqxj lower six"
        .write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [
        "ZQXJ-SELF-TWO": #"[{"snippet":"先說明一下\n⟨tool Bash command=ltm query ZQXJ-SELF-TWO --k 5⟩","uuid":"u"},{"snippet":"別的","uuid":"v"}]"#,
        "ZQXJ QUOTE THREE": #"[{"snippet":"使用者說：第三條是 ZQXJ  QUOTE\nTHREE 沒錯","uuid":"u"}]"#,
        "ZQXJ-EMPTY-FOUR": "[]",
        "ZQXJ-TOOLONLY-FIVE": #"[{"snippet":"⟨tool Bash command=swift test⟩","uuid":"u"},{"snippet":"⟨tool Read file_path=x⟩","uuid":"v"}]"#,
        "zqxj lower six": #"[{"snippet":"⟨tool Bash command=ltm query ZQXJ Lower SIX --k 5⟩","uuid":"u"}]"#,
    ])

    let run = try runScript(queries: queries, stub: stub)
    #expect(run.status == 0, Comment(rawValue: "rc=\(run.status) err=\(run.stderr)"))
    let fixtureText = try String(contentsOf: queries, encoding: .utf8)
    #expect(run.setLine == setFingerprint(fixtureText), Comment(rawValue: "第一行：\(run.setLine)"))
    #expect(run.setLine.range(of: "^set sha256:[0-9a-f]{12}$", options: .regularExpression) != nil)
    #expect(run.rows.count == 6, Comment(rawValue: run.stdout))
    #expect(run.rows.allSatisfy { $0.range(of: verdictLine, options: .regularExpression) != nil }, Comment(rawValue: run.stdout))
    #expect(run.rows.map(tail) == ["clean tool=0", "self tool=1", "self tool=0", "empty tool=0", "clean tool=2", "self tool=1"], Comment(rawValue: run.stdout))
    #expect(run.rows.map { $0.prefix(3) } == ["#1 ", "#2 ", "#3 ", "#4 ", "#5 ", "#6 "], Comment(rawValue: run.stdout))
    // 查詢文字與 snippet 都不得出現在任何輸出。
    #expect(!run.combined.lowercased().contains("zqxj") && !run.combined.contains("實質內容") && !run.combined.contains("說明"))

    // ltm 每次都收到同一個形狀：query --all-projects --k <k> --json -- <去掉 CR 與前後空白的查詢>。
    let log = try String(contentsOf: dir.appendingPathComponent("argv.log"), encoding: .utf8)
    let calls = log.split(separator: "\n").map { $0.split(separator: "\u{1f}", omittingEmptySubsequences: false).dropLast().map(String.init) }
    let expected = ["ZQXJ-CLEAN-ONE", "ZQXJ-SELF-TWO", "ZQXJ QUOTE THREE", "ZQXJ-EMPTY-FOUR", "ZQXJ-TOOLONLY-FIVE", "zqxj lower six"]
        .map { ["query", "--all-projects", "--k", "3", "--json", "--", $0] }
    #expect(calls == expected, Comment(rawValue: log))
}

@Test("measure-baseline.sh：行定義只認 ASCII 空白，LC_ALL=C 與 UTF-8 下列數相同、與測試的 nonCommentLines 一致；只含 U+3000 的條目報 error(blank) 而不是 self")
func measureBaselineLineDefinitionIsLocaleIndependent() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // 一個只有 U+3000 的行，與一個以 U+3000 縮排的「註解」：兩者對腳本與測試都**是**條目（都不剝 U+3000）。
    // 最後兩行是 CRLF：Swift 端若用 split(separator: "\n") 會把 CRLF 當一個 grapheme、不切，兩邊就分岔。
    let text = "# header\nZQXJ-A\n\u{3000}\n\u{3000}# not a comment\nZQXJ-B\nZQXJ-C\r\nZQXJ-D\r\n"
    let queries = dir.appendingPathComponent("q.txt")
    try text.write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [:])
    let swiftCount = nonCommentLines(text).count
    #expect(swiftCount == 6)
    for locale in ["C", "en_US.UTF-8"] {
        let run = try runScript(queries: queries, stub: stub, extraEnv: ["LC_ALL": locale, "LANG": locale])
        #expect(run.rows.count == swiftCount, Comment(rawValue: "LC_ALL=\(locale): \(run.stdout)"))
        // 只有 U+3000 的那一行：行定義算條目，但 judge 的 Unicode 空白摺疊會得到空針——那是 error(blank)，
        // 不能是 self。U+3000 縮排的「# not a comment」摺疊後不是空的，照常量（clean）。
        #expect(run.rows.map(tail) == ["clean tool=0", "error(blank)", "clean tool=0", "clean tool=0", "clean tool=0", "clean tool=0"], Comment(rawValue: "LC_ALL=\(locale): \(run.stdout)"))
        #expect(run.status == 1, Comment(rawValue: "LC_ALL=\(locale): rc=\(run.status)"))
        #expect(run.setLine == setFingerprint(text), Comment(rawValue: "LC_ALL=\(locale): \(run.setLine)"))
    }
}

@Test("measure-baseline.sh：error 字母表的每個 token 都會出現（rc、sig<N>、exec、json、shape×3）、每列照印、任一 error 以 1 離開；stderr 不帶 traceback 也不帶查詢")
func measureBaselineReportsEveryFailureAndExitsNonZero() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-RC-SEVEN\nZQXJ-SIGNAL\nZQXJ-NONJSON\nZQXJ-OBJECT\nZQXJ-STRINGS\nZQXJ-NULLSNIPPET\nZQXJ-OK\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [
        "ZQXJ-NONJSON": "not json at all",
        "ZQXJ-OBJECT": #"{"hits":[{"snippet":"⟨tool x⟩"}]}"#,
        "ZQXJ-STRINGS": #"["⟨tool x⟩"]"#,
        "ZQXJ-NULLSNIPPET": #"[{"snippet":null,"uuid":"u"}]"#,
    ], exits: ["ZQXJ-RC-SEVEN": 7], raw: ["ZQXJ-SIGNAL": "kill -9 $$"])

    let run = try runScript(queries: queries, stub: stub)
    #expect(run.status == 1, Comment(rawValue: "rc=\(run.status) out=\(run.stdout) err=\(run.stderr)"))
    #expect(run.rows.map(tail) == ["error(7)", "error(sig9)", "error(json)", "error(shape)", "error(shape)", "error(shape)", "clean tool=0"], Comment(rawValue: run.stdout))
    #expect(run.rows.allSatisfy { $0.range(of: verdictLine, options: .regularExpression) != nil }, Comment(rawValue: run.stdout))
    #expect(!run.combined.contains("ZQXJ") && !run.combined.contains("Traceback"), Comment(rawValue: run.stderr))

    // error(exec)：LTM_BIN 是可執行的一般檔案，但不是可執行格式（ENOEXEC）。
    let notAProgram = dir.appendingPathComponent("notaprogram")
    try "this is not a program\n".write(to: notAProgram, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notAProgram.path)
    let one = dir.appendingPathComponent("one.txt")
    try "ZQXJ-ONE\n".write(to: one, atomically: true, encoding: .utf8)
    let exec = try runScript(queries: one, stub: stub, ltmBinOverride: notAProgram.path)
    #expect(exec.status == 1 && exec.rows.map(tail) == ["error(exec)"], Comment(rawValue: "rc=\(exec.status) out=\(exec.stdout)"))
}

@Test("measure-baseline.sh：judge 掛掉或印出不合形狀的東西 → 該列 error(judge)、以 1 離開，judge 的 stderr／雜訊不外流")
func measureBaselineContainsAJudgeCrash() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-ONE\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [:])
    let fakes: [(String, String)] = [
        // 崩掉：traceback 進 stderr、非零離開。
        ("crash", "echo 'Traceback (most recent call last): ZQXJ-JUDGE' >&2; exit 1"),
        // 沒崩，但 stdout 多了一行雜訊（例如 site-packages 的 .pth 印字）。
        ("junk", "printf 'ZQXJ-JUNK from a .pth\\n42 clean tool=0\\n'; exit 0"),
        // 一行，但 <ms> 不是數字。
        ("badms", "printf 'fast clean tool=0\\n'; exit 0"),
        // 一行，verdict 不在字母表。
        ("badword", "printf '42 dirty tool=0\\n'; exit 0"),
        // tool= 後面不是數字。
        ("toolx", "printf '42 clean tool=x\\n'; exit 0"),
        // sig 後面不是數字。
        ("sigx", "printf '42 error(sigx)\\n'; exit 0"),
        // 字面 token 不在 ERROR_TOKENS（字元都合法——這條釘的是「字面比對」而不是「字元類別」）。
        ("badtoken", "printf '42 error(timeout)\\n'; exit 0"),
        // 空 token。
        ("emptytok", "printf '42 error()\\n'; exit 0"),
    ]
    for (label, body) in fakes {
        let bin = try makeBinDir(in: dir, judgeFakes: ["python3": body])
        let run = try runScript(queries: queries, stub: stub, pathPrefix: bin.path)
        #expect(run.status == 1, Comment(rawValue: "\(label): rc=\(run.status) out=\(run.stdout)"))
        #expect(run.rows == ["#1 0ms error(judge)"], Comment(rawValue: "\(label): \(run.stdout)"))
        #expect(!run.combined.contains("ZQXJ") && !run.combined.contains("Traceback"), Comment(rawValue: "\(label): \(run.stderr)"))
    }
}

@Test("measure-baseline.sh：前置守衛各自有離開碼——k 越界或非數字 64（且 stderr 只有那一句）、只有註解 65、查詢檔缺／是目錄／不可讀 66、ltm 是目錄或不可執行 69、沒有 python3 70")
func measureBaselinePreflightGuardsHaveDistinctExitCodes() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-ONE\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [:])

    #expect(try runScript(queries: queries, stub: stub, k: "0").status == 64)
    #expect(try runScript(queries: queries, stub: stub, k: "1001").status == 64)
    let nonDigit = try runScript(queries: queries, stub: stub, k: "x")
    #expect(nonDigit.status == 64 && nonDigit.stderr == "k 必須是 1–1000 的整數\n", Comment(rawValue: nonDigit.stderr))

    #expect(try runScript(queries: dir.appendingPathComponent("missing.txt"), stub: stub).status == 66)
    #expect(try runScript(queries: dir, stub: stub).status == 66)
    let unreadable = dir.appendingPathComponent("unreadable.txt")
    try "ZQXJ-ONE\n".write(to: unreadable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
    #expect(try runScript(queries: unreadable, stub: stub).status == 66)

    #expect(try runScript(queries: queries, stub: stub, ltmBinOverride: dir.path).status == 69)
    let notExecutable = dir.appendingPathComponent("noexec")
    try "#!/bin/bash\n".write(to: notExecutable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExecutable.path)
    #expect(try runScript(queries: queries, stub: stub, ltmBinOverride: notExecutable.path).status == 69)

    let noPython = try makeBinDir(in: dir, judgeFakes: [:])
    #expect(try runScript(queries: queries, stub: stub, pathOverride: noPython.path).status == 70)

    let onlyComments = dir.appendingPathComponent("c.txt")
    try "# a\n\n   # b\n".write(to: onlyComments, atomically: true, encoding: .utf8)
    let run = try runScript(queries: onlyComments, stub: stub)
    #expect(run.status == 65 && run.rows.isEmpty, Comment(rawValue: "rc=\(run.status) out=\(run.stdout)"))
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
        #expect(run.rows.count == 1 && run.rows[0].hasSuffix(" clean tool=0"), Comment(rawValue: "\(label): \(run.stdout)"))
        let leaked = run.combined.contains("ZQXJ")
        #expect(!leaked, Comment(rawValue: "\(label): xtrace 漏了查詢或命中（stderr \(run.stderr.count) bytes）"))
    }
}
