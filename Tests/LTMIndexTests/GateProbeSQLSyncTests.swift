import CryptoKit
import Foundation
import SQLite3
import Testing

@testable import LTMIndex

/// #60：`scripts/probes/gate-first-touch.c` 量的是 `sourcesWithoutCursor()` 的兩條閘查詢，
/// 但它是 C、不能引用 Swift 的字面——所以 SQL 有兩份。兩份不比對，閘或探針一改寫，探針就安靜地量
/// 另一件事，量測紀錄照樣引用它。
///
/// **這條測試比對的是文字，防的是一般的編輯**：只改一邊的 SQL（兩邊不一致）、改閘本體的其他部分、改探針的程式碼，
/// 都會讓它紅；兩邊一起改 SQL 照綠，那是設計上該有的（三個字面在 SHA 裡是佔位，只改 SQL 也不必更新釘值）。它不是對
/// 刻意繞過的保證——切詞器不是編譯器，兩者對「哪些是程式碼」意見不同的地方都是盲點；它也看不到控制流（閘
/// 或建置呼叫被包進 `if false`）與同一條連線上別處另下的語句。已知的幾種不一致直接拒絕、不去模擬：CR 行尾、
/// C 的反斜線續行（反斜線後面可以有空白）、Swift 的條件編譯、raw string 與 `#/` regex literal。這份清單不宣稱
/// 完整——#60 verify R4、R5 各又找到幾種。
///
/// 守的是：
/// - **閘**：`sourcesWithoutCursor()` 的本體骨架（SQL 換成佔位）；這個名字在 IndexDatabase.swift 的程式碼裡
///   只出現一次，就是那個 `func` 宣告（反引號寫法也算）。
/// - **建置**：IndexBuilder.swift 的程式碼裡，含這個名字的識別字只能是它本身，不得宣告它，每次出現都是無參數
///   呼叫，而且至少一次。`Sources/` 其他 Swift 檔一律不得出現這個名字（連註解也算，寧可假紅）。呼叫在不在
///   實際路徑上、結果有沒有被用，文字比對看不到。
/// - **探針**：程式碼骨架的 SHA-256，Q1、Q2、`MMAP_PRAGMA` 三個字面換成佔位——Q1／Q2 另與閘的 SQL 逐項比對，
///   `MMAP_PRAGMA` 由下一條測試照探針的方式執行並讀回。其餘程式碼的一般編輯都會紅，包括無害的；紅了由人確認
///   探針還在量同一件事，再照失敗訊息更新釘值。`#include` 以外的前置處理指令一律拒絕。
///
/// 切詞兩個核心檔的全檔，代價是它們日後若用到切詞器不支援的語法，這條 #60 的測試會紅（假紅，會安全地
/// 失敗）。同檔新增一個呼叫閘的函式也會紅（閘名只能出現一次）——同樣是假紅，改完再更新這條規則。
@Test("閘與探針的文字骨架沒有變、Q1／Q2 與閘的 SQL 逐項相等、建置以無參數呼叫引用這個閘")
func gateProbeMatchesSourcesWithoutCursor() throws {
    let probe = try readRepoFile("scripts/probes/gate-first-touch.c")
    let databaseSource = try readRepoFile("Sources/LTMIndex/IndexDatabase.swift")
    let builderSource = try readRepoFile("Sources/LTMIndex/IndexBuilder.swift")
    for (name, source) in [("探針", probe), ("IndexDatabase.swift", databaseSource), ("IndexBuilder.swift", builderSource)] {
        #expect(!source.unicodeScalars.contains("\r"), "\(name) 含 CR：切詞器只把 LF 當行尾，編譯器兩者都認")
    }
    let splice = try NSRegularExpression(pattern: #"\\[ \t\f\x0B]*\n"#)
    #expect(splice.firstMatch(in: probe, range: NSRange(probe.startIndex..., in: probe)) == nil,
            "探針含反斜線續行（反斜線後可有空白）：C 會先接行再認註解，切詞器不會")
    let database = try lexSwift(databaseSource)
    let builder = try lexSwift(builderSource)
    for (name, tokens) in [("IndexDatabase.swift", database), ("IndexBuilder.swift", builder)] {
        let conditionals = codeMatches(of: #"#(if|elseif|else|endif)(?![A-Za-z0-9_])"#, in: tokens)
        #expect(conditionals.isEmpty, "\(name) 用了條件編譯：切詞器看不出哪一段會被編譯——\(conditionals)")
    }

    // ── 閘 ──
    let nameInDatabase = codeMatches(of: identifierBoundary("sourcesWithoutCursor"), in: database)
    let declarations = codeMatches(of: gateDeclaration, in: database)
    #expect(nameInDatabase.count == 1 && declarations.count == 1,
            "IndexDatabase.swift 的程式碼裡 sourcesWithoutCursor 只能出現一次、就是宣告：出現 \(nameInDatabase.count) 次、宣告 \(declarations.count) 次")
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

    // ── 建置 ──
    let names = codeMatches(of: "\(identifierCharacter)*sourcesWithoutCursor\(identifierCharacter)*", in: builder)
    #expect(!names.isEmpty && names.allSatisfy { $0 == "sourcesWithoutCursor" },
            "IndexBuilder.swift 裡含 sourcesWithoutCursor 的識別字只能是它本身，而且至少一次：\(names)")
    #expect(codeMatches(of: gateDeclaration, in: builder).isEmpty, "IndexBuilder.swift 不得宣告 sourcesWithoutCursor")
    let calls = codeMatches(of: identifierBoundary("sourcesWithoutCursor") + #"\s*\(\s*\)"#, in: builder)
    #expect(calls.count == names.count, "IndexBuilder 對 sourcesWithoutCursor 的每次引用都要是無參數呼叫：\(names.count) 次引用、\(calls.count) 次無參數呼叫")
    let (walked, stray) = try strayGateMentions()
    #expect(walked.isSuperset(of: ["LTMIndex/IndexDatabase.swift", "LTMIndex/IndexBuilder.swift"]), "走訪 Sources/ 沒走到兩個核心檔：\(walked.count) 個檔")
    #expect(stray.isEmpty, "Sources/ 其他 Swift 檔出現了 sourcesWithoutCursor：\(stray)")

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
}

/// #60：探針的 `--mmap` 與預設 `cache_size` 被紀錄當成「ltm 的設定」。這裡不比對字面，而是讀回有效值：
/// 用 `IndexDatabase(path:)` 開一條連線，和一條照探針 `--mmap` 的方式設定的連線（`MMAP_PRAGMA` 必須是單一條
/// `PRAGMA mmap_size=<整數>`），兩者讀回的 `mmap_size`、`cache_size` 要相同，且 mmap 真的開著。它只比這兩個值：
/// `init` 裡其他的 PRAGMA 與開檔旗標、建置之後在同一條連線上另下的 PRAGMA、行程層級的 SQLite 設定，這裡都看不到。
@Test("IndexDatabase 開出的連線，mmap_size 與 cache_size 讀回來與探針 --mmap 的連線相同")
func indexDatabaseSettingsMatchProbe() throws {
    let tokens = try lexC(try readRepoFile("scripts/probes/gate-first-touch.c"))
    let mmapPragma = try probeConstant("MMAP_PRAGMA", in: tokens)
    try #require(mmapPragma.range(of: #"^PRAGMA mmap_size=[0-9]+$"#, options: .regularExpression) != nil,
                 "MMAP_PRAGMA 要是單一條 PRAGMA mmap_size=<整數>：\(mmapPragma)")
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-gate-settings-\(UUID().uuidString).sqlite3").path
    defer {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }
    let database = try IndexDatabase(path: path)
    var ltm: [String: Int64] = [:]
    for pragma in ["mmap_size", "cache_size"] {
        try database.query("PRAGMA \(pragma)") { ltm[pragma] = sqlite3_column_int64($0, 0) }
    }
    // 探針是唯讀開檔；這裡讀寫開，因為空的 WAL DB 還沒有 -wal，唯讀連線讀不了（設定的讀回與開檔模式無關）。
    var raw: OpaquePointer?
    try #require(sqlite3_open_v2(path, &raw, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    defer { sqlite3_close_v2(raw) }
    // 照探針的方式執行（`pragma_value`：prepare_v2＋step，只跑第一條語句），並要求它就是單一語句。
    var mmapStatement: OpaquePointer?
    try mmapPragma.withCString { sql in
        var tail: UnsafePointer<CChar>?
        try #require(sqlite3_prepare_v2(raw, sql, -1, &mmapStatement, &tail) == SQLITE_OK)
        let rest = tail.map { String(cString: $0) } ?? ""
        #expect(rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "MMAP_PRAGMA 要是單一語句——探針只執行第一條，其餘被忽略：\(rest)")
    }
    let stepCode = sqlite3_step(mmapStatement)
    sqlite3_finalize(mmapStatement)
    try #require(stepCode == SQLITE_ROW, "探針的 pragma_value 只接受回一列")
    var probeSide: [String: Int64] = [:]
    for pragma in ["mmap_size", "cache_size"] {
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(raw, "PRAGMA \(pragma)", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_step(statement) == SQLITE_ROW)
        probeSide[pragma] = sqlite3_column_int64(statement, 0)
    }
    #expect(ltm == probeSide, "IndexDatabase 的連線設定與探針 --mmap 不同：ltm \(ltm)，探針 \(probeSide)")
    #expect((ltm["mmap_size"] ?? 0) > 0, "IndexDatabase 的連線沒有開 mmap：\(ltm)")
}

private func readRepoFile(_ path: String) throws -> String {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
        root = root.deletingLastPathComponent()
        try #require(root.path != "/")
    }
    return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

/// 識別字的一個字元：ASCII 標點與空白以外的任何字元（含 `_` 與非 ASCII）。寬鬆是故意的——比對到比較長的
/// 識別字只會讓測試紅，不會讓它綠。
private let identifierCharacter = #"[^\s\x21-\x2F\x3A-\x40\x5B-\x5E\x60\x7B-\x7E]"#

private func identifierBoundary(_ pattern: String) -> String {
    "(?<!\(identifierCharacter))\(pattern)(?!\(identifierCharacter))"
}

/// `func sourcesWithoutCursor` 的宣告，反引號寫法也算。
private let gateDeclaration = #"func\s+`?"# + identifierBoundary("sourcesWithoutCursor")

/// 走訪 `Sources/` 底下的 Swift 檔（相對路徑），回傳走到的檔與兩個核心檔以外、原文含這個名字的檔。
/// 走訪失敗要拋錯，不能安靜地變成「沒有檔」。
private func strayGateMentions() throws -> (walked: Set<String>, stray: [String]) {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
        root = root.deletingLastPathComponent()
        try #require(root.path != "/")
    }
    let sources = root.appendingPathComponent("Sources")
    var failures: [String] = []
    // 相對路徑在遍歷當下由起點構造（`.producesRelativePathURLs`），不用字串前綴去算——FileManager 回的路徑形式
    // 與起點不一定一致（CLAUDE.md 技術要點）。
    let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil,
                                                options: [.producesRelativePathURLs], errorHandler: { url, error in
        failures.append("\(url.lastPathComponent): \(error)")
        return true
    })
    var walked: Set<String> = []
    var stray: [String] = []
    while let url = walker?.nextObject() as? URL {
        guard url.pathExtension == "swift" else { continue }
        let relative = url.relativePath
        walked.insert(relative)
        if relative == "LTMIndex/IndexDatabase.swift" || relative == "LTMIndex/IndexBuilder.swift" { continue }
        if try String(contentsOf: url, encoding: .utf8).contains("sourcesWithoutCursor") { stray.append(relative) }
    }
    try #require(failures.isEmpty, "走訪 Sources/ 失敗：\(failures)")
    return (walked, stray)
}

/// `sourcesWithoutCursor()` 去掉註解、壓縮空白、SQL 換成 `<SQL>` 之後的樣子。
private let expectedGateSkeleton =
    #"var missing: [String] = [] var orphanChunks = 0 try query( <SQL> ) { statement in orphanChunks = Int(sqlite3_column_int64(statement, 0)) } if orphanChunks > 0 { missing.append("(\(orphanChunks) 個 chunk 沒有任何 source mapping)") } try query( <SQL> ) { statement in missing.append(columnText(statement, 0)) } return missing.sorted()"#

/// 探針去掉註解、壓縮空白、三個字面換成佔位之後的 SHA-256。
private let expectedProbeSkeletonSHA256 = "fa32cff5ae23b93e05832163bb79af1ae683ebc909d2540313c544f169c441da"

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
    case unsupported(String)
}

/// 最小的 Swift 切詞：去掉 `//` 與（可巢狀的）`/* */` 註解，把 `"…"` 與 `"""…"""` 字面分出來（保留
/// 內容原樣，含 `\(…)` 插值）。它只懂 Swift 的一個子集：認得出的不支援語法（raw string、`#/` regex
/// literal）直接拋錯，切不動也拋錯——那是紅燈；認不出的（例如裸的 `/…/` regex literal 裡有引號）可能
/// 切錯而不報錯。
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
        if c == "#" && (next == "\"" || next == "#" || next == "/") {
            throw LexError.unsupported("raw string 或 regex literal：" + context())
        }
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
