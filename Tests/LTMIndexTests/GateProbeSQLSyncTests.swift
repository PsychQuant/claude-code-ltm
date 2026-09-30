import Foundation
import Testing

/// #60：`scripts/probes/gate-first-touch.c` 量的是 `sourcesWithoutCursor()` 的兩條閘查詢，
/// 但它是 C、不能引用 Swift 的字面——所以 SQL 有兩份。兩份不比對，閘一改寫，探針就安靜地量
/// 另一件事，量測紀錄照樣引用它。
///
/// 第一版只查「探針的 SQL 是閘本體的子字串」，#60 verify R2 找到七種該紅卻綠的改法（在閘的 SQL
/// 尾端加子句、前面加 `EXPLAIN QUERY PLAN`、把探針砍成前綴、舊 SQL 留在註解裡、`try self.query(`、
/// `_ = try chunkCount()`、探針把 Q1 當 Q2 跑）。那是列舉式的防線，所以這一版不再列舉改法，改成
/// 一條性質：**閘的函式本體（去掉註解、壓縮空白）有任何改動就紅**。改動可能無害——紅了就去確認
/// 探針還在量同一件事，再更新下面的 `expectedGateSkeleton`。
@Test("閘的本體沒有變、探針的 Q1／Q2 與閘的 SQL 逐項相等、--mmap 與 IndexDatabase 同字面")
func gateProbeMatchesSourcesWithoutCursor() throws {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
        root = root.deletingLastPathComponent()
        try #require(root.path != "/")
    }
    let probe = try String(
        contentsOf: root.appendingPathComponent("scripts/probes/gate-first-touch.c"), encoding: .utf8)
    let database = try String(
        contentsOf: root.appendingPathComponent("Sources/LTMIndex/IndexDatabase.swift"), encoding: .utf8)

    // 閘端：函式本體拆成程式碼與字串字面。`query(` 後面緊接的字面是 SQL，其餘字面留在骨架裡。
    let gate = try functionBody(of: "public func sourcesWithoutCursor()", in: database)
    var skeleton = ""
    var gateSQL: [String] = []
    for token in gate {
        switch token {
        case .code(let text): skeleton += text
        case .literal(let text):
            if squash(skeleton).hasSuffix("query(") {
                gateSQL.append(squash(text))
                skeleton += "<SQL>"
            } else {
                skeleton += "\"" + text + "\""
            }
        }
    }
    #expect(squash(skeleton) == expectedGateSkeleton,
            "sourcesWithoutCursor() 的本體變了——確認 scripts/probes/gate-first-touch.c 仍量同一件事，再更新 expectedGateSkeleton。目前是：\(squash(skeleton))")

    // 探針端：Q1／Q2 的宣告，以及 main() 實際把哪個常數交給哪個標籤。
    let probeSQL = try ["Q1", "Q2"].map { try squash(probeConstant($0, in: probe)) }
    #expect(gateSQL == probeSQL, "探針的 SQL 與閘的 SQL 不是逐項相等：閘 \(gateSQL)，探針 \(probeSQL)")
    let runPattern = try NSRegularExpression(pattern: #"run\(db, "(Q[0-9]+)", (Q[0-9]+),"#)
    let runCalls = runPattern.matches(in: probe, range: NSRange(probe.startIndex..., in: probe)).map { match in
        [1, 2].map { String(probe[Range(match.range(at: $0), in: probe)!]) }
    }
    #expect(runCalls == [["Q1", "Q1"], ["Q2", "Q2"]], "探針 main() 跑的查詢與標籤對不上：\(runCalls)")

    // --mmap：探針宣稱與 IndexDatabase.init 相同。init 本體（去掉註解）裡的 mmap PRAGMA 必須恰好一條且同字面。
    let initLiterals = try functionBody(of: "public init(path: String)", in: database)
        .compactMap { token -> String? in
            if case .literal(let text) = token, text.hasPrefix("PRAGMA mmap_size") { return text }
            return nil
        }
    #expect(initLiterals == [try probeConstant("MMAP_PRAGMA", in: probe)],
            "IndexDatabase.init 的 mmap PRAGMA 與探針的 MMAP_PRAGMA 不同：\(initLiterals)")
}

/// 目前 `sourcesWithoutCursor()` 去掉註解、壓縮空白、SQL 換成 `<SQL>` 之後的樣子。
private let expectedGateSkeleton =
    #"var missing: [String] = [] var orphanChunks = 0 try query( <SQL> ) { statement in orphanChunks = Int(sqlite3_column_int64(statement, 0)) } if orphanChunks > 0 { missing.append("(\(orphanChunks) 個 chunk 沒有任何 source mapping)") } try query( <SQL> ) { statement in missing.append(columnText(statement, 0)) } return missing.sorted()"#

private enum SwiftToken: Equatable {
    case code(String)
    case literal(String)
}

private func squash(_ text: String) -> String {
    text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
}

/// `static const char *<name> = "…";` 那一行的字面。整行只能是這個形狀。
private func probeConstant(_ name: String, in probe: String) throws -> String {
    let prefix = "static const char *\(name) = \""
    let lines = probe.components(separatedBy: "\n").filter { $0.hasPrefix(prefix) }
    let line = try #require(lines.count == 1 ? lines.first : nil, "探針裡的 \(name) 要恰好宣告一次")
    let body = line.dropFirst(prefix.count)
    try #require(body.hasSuffix("\";"), "\(name) 那一行要以 \"; 結尾")
    let value = String(body.dropLast(2))
    try #require(!value.contains("\""), "\(name) 的字面不得含引號")
    return value
}

/// 從宣告開始，到與第一個 `{` 配對的 `}` 為止的切詞結果（不含外層大括號）。切詞只走到那個 `}`，
/// 不碰檔案其餘部分；回傳 token 而不是文字，免得多行字面被重新包成單行字面再切一次。
private func functionBody(of declaration: String, in source: String) throws -> [SwiftToken] {
    let start = try #require(source.range(of: declaration), "找不到 \(declaration)")
    var tokens = try lexSwift(String(source[start.upperBound...]), untilBalancedBrace: true)
    // 去掉宣告尾巴到第一個 `{`（含）。
    let first = try #require(tokens.firstIndex { if case .code(let text) = $0 { return text.contains("{") } else { return false } },
                             "\(declaration) 沒有本體")
    guard case .code(let head) = tokens[first], let brace = head.firstIndex(of: "{") else { throw GateProbeSyncError.unterminated }
    tokens[first] = .code(String(head[head.index(after: brace)...]))
    tokens.removeFirst(first)
    // 去掉最後那個 `}`。
    guard case .code(let tail) = tokens.last, tail.hasSuffix("}") else { throw GateProbeSyncError.unterminated }
    tokens[tokens.count - 1] = .code(String(tail.dropLast()))
    return tokens
}

private enum GateProbeSyncError: Error {
    case unterminated
}

/// 最小的 Swift 切詞：去掉 `//` 與 `/* */` 註解，把 `"…"` 與 `"""…"""` 字面分出來（保留內容原樣，
/// 含 `\(…)` 插值）。只用在 `sourcesWithoutCursor()` 與 `init(path:)` 兩個本體上（`untilBalancedBrace`
/// 讓它停在本體結束的 `}`）；切不動就拋錯——那也是紅燈，不會變成靜默通過。
private func lexSwift(_ source: String, untilBalancedBrace: Bool = false) throws -> [SwiftToken] {
    var tokens: [SwiftToken] = []
    var code = ""
    let chars = Array(source)
    var i = 0
    var depth = 0
    func flush() {
        if !code.isEmpty { tokens.append(.code(code)); code = "" }
    }
    while i < chars.count {
        let c = chars[i]
        let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        if c == "/" && next == "/" {
            while i < chars.count && chars[i] != "\n" { i += 1 }
            continue
        }
        if c == "/" && next == "*" {
            i += 2
            while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
            guard i + 1 < chars.count else { throw GateProbeSyncError.unterminated }
            i += 2
            continue
        }
        if c == "\"" {
            flush()
            let triple = i + 2 < chars.count && chars[i + 1] == "\"" && chars[i + 2] == "\""
            i += triple ? 3 : 1
            var value = ""
            var parenDepth = 0
            while true {
                guard i < chars.count else { throw GateProbeSyncError.unterminated }
                let d = chars[i]
                if parenDepth == 0 && d == "\\" && i + 1 < chars.count && chars[i + 1] == "(" {
                    value += "\\("
                    parenDepth = 1
                    i += 2
                    continue
                }
                if parenDepth > 0 {
                    if d == "(" { parenDepth += 1 } else if d == ")" { parenDepth -= 1 }
                    value.append(d)
                    i += 1
                    continue
                }
                if d == "\\" && i + 1 < chars.count {
                    value.append(d)
                    value.append(chars[i + 1])
                    i += 2
                    continue
                }
                if triple {
                    if d == "\"" && i + 2 < chars.count && chars[i + 1] == "\"" && chars[i + 2] == "\"" {
                        i += 3
                        break
                    }
                } else if d == "\"" {
                    i += 1
                    break
                } else if d == "\n" {
                    throw GateProbeSyncError.unterminated
                }
                value.append(d)
                i += 1
            }
            tokens.append(.literal(value))
            continue
        }
        code.append(c)
        i += 1
        if untilBalancedBrace {
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 { break }
            }
        }
    }
    if untilBalancedBrace && depth != 0 { throw GateProbeSyncError.unterminated }
    flush()
    return tokens
}
