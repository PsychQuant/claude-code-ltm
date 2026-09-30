import CryptoKit
import Foundation
import Testing

/// #60：`scripts/probes/gate-first-touch.c` 量的是 `sourcesWithoutCursor()` 的兩條閘查詢，
/// 但它是 C、不能引用 Swift 的字面——所以 SQL 有兩份。兩份不比對，閘或探針一改寫，探針就安靜地量
/// 另一件事，量測紀錄照樣引用它。
///
/// 這條測試的防線寫成性質，不列舉改法（#60 verify R2、R3 各找到一批列舉漏掉的改法）：
/// - **閘**：`sourcesWithoutCursor()` 的本體（去掉註解、壓縮空白、SQL 換成佔位）一改就紅；宣告在
///   去掉註解之後找，而且全檔只能有一個；`IndexBuilder` 呼叫的閘必須就是它。
/// - **探針**：整份程式碼（去掉註解、壓縮空白、Q1／Q2／MMAP_PRAGMA 換成佔位）的 SHA-256 一變就紅；
///   `#include` 以外的前置處理指令一律拒絕。
/// - **兩邊的字面**：Q1／Q2 與閘的 SQL 逐項相等；`MMAP_PRAGMA` 與 IndexDatabase.swift 全檔唯一一條
///   含 `mmap_size` 的字面（不分大小寫）相同。
///
/// 改動可能無害——紅了就去確認探針還在量同一件事，再照失敗訊息更新下面的釘值。
@Test("閘與探針的程式碼沒有變、Q1／Q2 與閘的 SQL 逐項相等、--mmap 與 IndexDatabase 同字面、建置呼叫的是這個閘")
func gateProbeMatchesSourcesWithoutCursor() throws {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
        root = root.deletingLastPathComponent()
        try #require(root.path != "/")
    }
    let read = { (path: String) in try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    let probe = try read("scripts/probes/gate-first-touch.c")
    let database = try lexSwift(try read("Sources/LTMIndex/IndexDatabase.swift"))
    let builder = try lexSwift(try read("Sources/LTMIndex/IndexBuilder.swift"))

    // ── 閘 ──
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
            "sourcesWithoutCursor() 的本體變了——確認探針仍量同一件事，再更新 expectedGateSkeleton。目前是：\(squash(skeleton))")
    let builderCalls = codeMatches(of: #"sourcesWithoutCursor[A-Za-z0-9_]*\("#, in: builder)
    #expect(!builderCalls.isEmpty && builderCalls.allSatisfy { $0 == "sourcesWithoutCursor(" },
            "IndexBuilder 呼叫的閘不是 sourcesWithoutCursor()：\(builderCalls)")

    // ── 探針 ──
    let probeTokens = try lexC(probe)
    let directives = probeTokens.code.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("#") && !$0.hasPrefix("#include <") }
    #expect(directives.isEmpty, "探針不得用 #include 以外的前置處理指令：\(directives)")
    let q1 = try probeConstant("Q1", in: probeTokens)
    let q2 = try probeConstant("Q2", in: probeTokens)
    let mmapPragma = try probeConstant("MMAP_PRAGMA", in: probeTokens)
    #expect(gateSQL == [squash(q1), squash(q2)], "探針的 SQL 與閘的 SQL 不是逐項相等：閘 \(gateSQL)，探針 \([q1, q2])")
    let probeSkeleton = squash(probeTokens.skeleton(replacing: [q1: "<Q1>", q2: "<Q2>", mmapPragma: "<MMAP>"]))
    let digest = SHA256.hash(data: Data(probeSkeleton.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(digest == expectedProbeSkeletonSHA256,
            "探針的程式碼變了——確認它仍量 sourcesWithoutCursor() 的兩條查詢、--mmap 仍下 MMAP_PRAGMA，再把 expectedProbeSkeletonSHA256 更新成 \(digest)")

    // ── mmap ──
    let mmapLiterals = database.compactMap { token -> String? in
        if case .literal(let text) = token, text.lowercased().contains("mmap_size") { return text }
        return nil
    }
    #expect(mmapLiterals == [mmapPragma], "IndexDatabase.swift 裡含 mmap_size 的字面要恰好一條、且與探針的 MMAP_PRAGMA 相同：\(mmapLiterals)")
}

/// `sourcesWithoutCursor()` 去掉註解、壓縮空白、SQL 換成 `<SQL>` 之後的樣子。
private let expectedGateSkeleton =
    #"var missing: [String] = [] var orphanChunks = 0 try query( <SQL> ) { statement in orphanChunks = Int(sqlite3_column_int64(statement, 0)) } if orphanChunks > 0 { missing.append("(\(orphanChunks) 個 chunk 沒有任何 source mapping)") } try query( <SQL> ) { statement in missing.append(columnText(statement, 0)) } return missing.sorted()"#

/// 探針去掉註解、壓縮空白、三個字面換成佔位之後的 SHA-256。
private let expectedProbeSkeletonSHA256 = "59f163d718e134282c7dd36fa5219429dccc0859315ba0a1c1c5238c3968b824"

private enum SwiftToken: Equatable {
    case code(String)
    case literal(String)
}

private func squash(_ text: String) -> String {
    text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
}

/// 只在程式碼（不含註解與字串）裡找符合 pattern 的片段。
private func codeMatches(of pattern: String, in tokens: [SwiftToken]) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    return tokens.flatMap { token -> [String] in
        guard case .code(let text) = token else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .map { String(text[Range($0.range, in: text)!]) }
    }
}

/// 在去掉註解的 token 裡找宣告（全檔只能出現一次），取到與它後面第一個 `{` 配對的 `}` 為止，
/// 回傳本體的 token（不含外層大括號）。宣告若只出現在註解裡，這裡找不到——那是對的。
private func functionBody(of declaration: String, in tokens: [SwiftToken]) throws -> [SwiftToken] {
    var hits: [(Int, String.Index)] = []
    for (index, token) in tokens.enumerated() {
        guard case .code(let text) = token else { continue }
        var searchStart = text.startIndex
        while let range = text.range(of: declaration, range: searchStart..<text.endIndex) {
            hits.append((index, range.upperBound))
            searchStart = range.upperBound
        }
    }
    let (start, offset) = try #require(hits.count == 1 ? hits.first : nil, "\(declaration) 要在程式碼裡恰好出現一次，實際 \(hits.count) 次")
    var body: [SwiftToken] = []
    var depth = 0
    for index in start..<tokens.count {
        switch tokens[index] {
        case .literal(let value):
            if depth > 0 { body.append(.literal(value)) }
        case .code(let full):
            let text = index == start ? String(full[offset...]) : full
            var chunk = ""
            for character in text {
                if character == "{" {
                    depth += 1
                    if depth == 1 { continue }
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        if !chunk.isEmpty { body.append(.code(chunk)) }
                        return body
                    }
                }
                if depth > 0 { chunk.append(character) }
            }
            if !chunk.isEmpty { body.append(.code(chunk)) }
        }
    }
    throw LexError.unbalanced(declaration)
}

private enum LexError: Error {
    case unterminated(String)
    case unbalanced(String)
}

/// 最小的 Swift 切詞：去掉 `//` 與（可巢狀的）`/* */` 註解，把 `"…"` 與 `"""…"""` 字面分出來（保留
/// 內容原樣，含 `\(…)` 插值）。切不動就拋錯——那也是紅燈，不會變成靜默通過。
private func lexSwift(_ source: String) throws -> [SwiftToken] {
    var tokens: [SwiftToken] = []
    var code = ""
    let chars = Array(source)
    var i = 0
    func context() -> String { String(chars[max(0, i - 30)..<min(chars.count, i + 30)]) }
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
            var nesting = 1
            i += 2
            while nesting > 0 {
                guard i + 1 < chars.count else { throw LexError.unterminated("區塊註解：" + context()) }
                if chars[i] == "/" && chars[i + 1] == "*" { nesting += 1; i += 2 }
                else if chars[i] == "*" && chars[i + 1] == "/" { nesting -= 1; i += 2 }
                else { i += 1 }
            }
            code.append(" ")
            continue
        }
        if c == "\"" {
            flush()
            let triple = i + 2 < chars.count && chars[i + 1] == "\"" && chars[i + 2] == "\""
            i += triple ? 3 : 1
            var value = ""
            var parenDepth = 0
            while true {
                guard i < chars.count else { throw LexError.unterminated("字串：" + context()) }
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
                    throw LexError.unterminated("單行字串跨行：" + context())
                }
                value.append(d)
                i += 1
            }
            tokens.append(.literal(value))
            continue
        }
        code.append(c)
        i += 1
    }
    flush()
    return tokens
}

/// C 原始碼去掉 `//`、`/* */` 註解之後的片段：程式碼與字串字面分開，才能把指定的字面換成佔位。
private struct CTokens {
    var segments: [SwiftToken] = []

    /// 程式碼（字面以原樣、加引號放回）——用來掃前置處理指令。
    var code: String {
        segments.map { token -> String in
            switch token {
            case .code(let text): return text
            case .literal(let value): return "\"" + value + "\""
            }
        }.joined()
    }

    func skeleton(replacing replacements: [String: String]) -> String {
        segments.map { token -> String in
            switch token {
            case .code(let text): return text
            case .literal(let value): return replacements[value] ?? "\"" + value + "\""
            }
        }.joined()
    }
}

private func lexC(_ source: String) throws -> CTokens {
    var out = CTokens()
    var code = ""
    let chars = Array(source)
    var i = 0
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
            guard i + 1 < chars.count else { throw LexError.unterminated("C 區塊註解") }
            i += 2
            code.append(" ")
            continue
        }
        if c == "\"" || c == "'" {
            let quote = c
            var value = ""
            i += 1
            while true {
                guard i < chars.count, chars[i] != "\n" else { throw LexError.unterminated("C 字面") }
                if chars[i] == "\\" && i + 1 < chars.count {
                    value.append(chars[i]); value.append(chars[i + 1]); i += 2; continue
                }
                if chars[i] == quote { i += 1; break }
                value.append(chars[i]); i += 1
            }
            if quote == "\"" {
                if !code.isEmpty { out.segments.append(.code(code)); code = "" }
                out.segments.append(.literal(value))
            } else {
                code += "'" + value + "'"
            }
            continue
        }
        code.append(c)
        i += 1
    }
    if !code.isEmpty { out.segments.append(.code(code)) }
    return out
}

/// `static const char *<name> = "…";`——在去掉註解的程式碼裡恰好一次。
private func probeConstant(_ name: String, in tokens: CTokens) throws -> String {
    var hits: [String] = []
    for (index, token) in tokens.segments.enumerated() {
        guard case .literal(let value) = token, index > 0, index + 1 < tokens.segments.count,
              case .code(let before) = tokens.segments[index - 1],
              case .code(let after) = tokens.segments[index + 1] else { continue }
        if squash(before).hasSuffix("static const char *\(name) =") && squash(after).hasPrefix(";") {
            hits.append(value)
        }
    }
    return try #require(hits.count == 1 ? hits.first : nil, "探針裡的 \(name) 要恰好宣告一次，實際 \(hits.count) 次")
}
