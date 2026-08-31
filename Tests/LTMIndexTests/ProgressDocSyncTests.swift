import Foundation
import Testing

@testable import LTMIndex

/// `ltm-setup` 的 skill 列舉「`ltm build` 會印哪幾種進度行」，而那份列舉宣稱自己
/// 完整。它漏過一種——`batchPlan`——並以「三種行」的形式出貨（#44 R2 verify，
/// devil's advocate 實測 stderr 有四種）。
///
/// **修法不是把數字改成四。** 那只是再列舉一次，而下一個 `BuildProgress` case
/// 加進來時它會再漏一次，且不報錯。CLAUDE.md：一個數字被複述 N 次就是 N 份會
/// 漂移的規格；收斂之後要補的是**一個會變紅的檢查**。
///
/// 這就是那個檢查：`BuildProgress` 的 case 數是來源，skill 的表格列數必須跟上。
@Test("ltm-setup skill 的進度行表格逐一對應 BuildProgress 的 case 名字")
func theSetupSkillEnumeratesEveryProgressCase() throws {
    let root = try repositoryRoot()
    let skill = try String(
        contentsOf: root.appendingPathComponent("plugin/skills/ltm-setup/SKILL.md"),
        encoding: .utf8)
    let builderSource = try String(
        contentsOf: root.appendingPathComponent("Sources/LTMIndex/IndexBuilder.swift"),
        encoding: .utf8)

    // `BuildProgress` 的 case **名字**。用 source 而不是反射：enum 沒有 `allCases`
    // （每個 case 都有 associated value），而加 `CaseIterable` 只為了測試會改出貨型別。
    let progressBlock = try #require(
        builderSource.range(of: "public enum BuildProgress: Sendable, Equatable {").map {
            String(builderSource[$0.upperBound...].prefix(while: { $0 != "}" }))
        })
    // **跨行的 case list 要先接回一行。** `case a(\n  x: Int)` 的參數在下一行，
    // 而下一行不以 `case ` 開頭——先前按行過濾會把它整段丟掉，於是同一個宣告裡
    // 逗號後的第二個 case 名字漏掉（#44 R5 verify，codex）。
    // 做法：把不以 `case `／`}` 開頭的續行併回前一行。
    var joined: [String] = []
    for raw in progressBlock.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("case ") || joined.isEmpty {
            joined.append(line)
        } else if !line.isEmpty, !line.hasPrefix("///"), !line.hasPrefix("//") {
            joined[joined.count - 1] += " " + line
        }
    }
    let caseNames = Set(
        joined
            .filter { $0.hasPrefix("case ") }
            // **一行可以宣告多個 case**（`case a, b`）。上一版只取第一個，於是
            // 一個以那種形式加進來的 case 會讓這條檢查靜默漏掉它——一份宣稱自己
            // 完整的列舉，用一個看不出漏洞的 parser 支撐（#44 R4 verify，codex）。
            //
            // **逗號只在括號深度 0 才算分隔。** associated value 的參數列裡也有逗號
            // （`case scanCompleted(files: Int, chunks: Int, …)`），天真的 `split`
            // 會把 `files`、`chunks` 也當成 case 名字——第一版就是這樣，而它讓
            // 這條檢查改成噪音而不是漏洞。
            .flatMap { line -> [String] in
                var names: [String] = []
                var depth = 0
                var current = ""
                for character in line.dropFirst("case ".count) {
                    switch character {
                    // `<` / `>` **不算深度**：`->` 的箭頭會讓深度變成 −1，之後
                    // 每個逗號都被當成頂層分隔。泛型在 case 宣告裡罕見，而箭頭
                    // 在 associated value 的函式型別裡不罕見（#44 R5 verify，codex）。
                    case "(", "[": depth += 1
                    case ")", "]": depth -= 1
                    case "," where depth == 0:
                        names.append(current)
                        current = ""
                        continue
                    default: break
                    }
                    if depth == 0 { current.append(character) }
                }
                names.append(current)
                return names
                    .map { String($0.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isLetter || $0.isNumber })) }
                    .filter { !$0.isEmpty }
            })
    #expect(!caseNames.isEmpty, "抓不到 case 名字——這條檢查失去意義，比失敗更糟")

    // skill 表格中間那一欄的 `case` 名字。
    let lines = skill.components(separatedBy: "\n")
    let header = try #require(lines.firstIndex { $0.hasPrefix("| 何時 ") })
    var documented: Set<String> = []
    var index = header + 2  // 跳過表頭與分隔列
    while index < lines.count, lines[index].hasPrefix("|") {
        let columns = lines[index].components(separatedBy: "|")
        if columns.count > 2 {
            let cell = columns[2].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            if !cell.isEmpty { documented.insert(cell) }
        }
        index += 1
    }

    // **比對名字集合，不是基數。** 只比列數擋不住「換掉一列」：列數與 case 數
    // 同時對而內容錯位，使用者看到的「完整清單」仍漏一種（#44 R3 verify；
    // 這則註解自己曾把數字寫死成「四」，#48 加 case 後過期——數字不再出現）。
    // 測試名宣稱「逐一對應」，所以它必須真的逐一對應——這正是 CLAUDE.md 那條
    // 「宣稱自己完整的列舉」要防的東西，而上一版的修法用一個較弱的檢查冒充了它。
    #expect(
        documented == caseNames,
        "SKILL.md 的進度行與 BuildProgress 的 case 名字對不上——使用者會據此判斷 build 是不是卡住了")
}

private func repositoryRoot(file: StaticString = #filePath) throws -> URL {
    var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path)
        {
            return directory
        }
        directory = directory.deletingLastPathComponent()
    }
    struct RootNotFound: Error {}
    throw RootNotFound()
}
