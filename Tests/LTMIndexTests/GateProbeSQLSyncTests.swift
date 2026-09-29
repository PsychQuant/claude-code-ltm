import Foundation
import Testing

/// #60：`scripts/probes/gate-first-touch.c` 量的是 `sourcesWithoutCursor()` 的兩條閘查詢，
/// 但它是 C、不能引用 Swift 的字面——所以 SQL 有兩份。兩份不比對，閘一改寫，探針就安靜地量
/// 另一件事，量測紀錄照樣引用它。這條測試在兩者不一致、或閘多了／少了一條查詢時變紅。
@Test("探針的 Q1／Q2 與 sourcesWithoutCursor() 的兩條查詢逐字相同（空白除外）")
func gateProbeSQLMatchesSourcesWithoutCursor() throws {
    var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
        root = root.deletingLastPathComponent()
        try #require(root.path != "/")
    }
    let probe = try String(
        contentsOf: root.appendingPathComponent("scripts/probes/gate-first-touch.c"), encoding: .utf8)
    let database = try String(
        contentsOf: root.appendingPathComponent("Sources/LTMIndex/IndexDatabase.swift"), encoding: .utf8)

    let squash = { (text: String) -> String in
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }
    // 探針端：`static const char *Q1 = "…";`，每條一行。
    let probeSQL = try ["Q1", "Q2"].map { name -> String in
        let prefix = "static const char *\(name) = \""
        let line = try #require(
            probe.components(separatedBy: "\n").first { $0.hasPrefix(prefix) }, "探針裡找不到 \(name)")
        let body = line.dropFirst(prefix.count)
        let close = try #require(body.range(of: "\";"), "\(name) 沒有收尾的 \";")
        return String(body[..<close.lowerBound])
    }

    // 閘端：函式本體到下一個 `public func` 為止。
    let start = try #require(database.range(of: "public func sourcesWithoutCursor()"))
    let rest = database[start.upperBound...]
    let end = rest.range(of: "public func ")?.lowerBound ?? rest.endIndex
    let gate = squash(String(rest[..<end]))

    // 閘多一條或少一條查詢，探針就不再量「那個閘」。
    #expect(gate.components(separatedBy: "try query(").count - 1 == probeSQL.count,
            "sourcesWithoutCursor() 的查詢數與探針不同——改了閘就要同步改探針")
    for sql in probeSQL {
        #expect(gate.contains(squash(sql)), "探針的 SQL 不在 sourcesWithoutCursor() 裡：\(sql)")
    }
}
