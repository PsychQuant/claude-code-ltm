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
@Test("ltm-setup skill 的進度行表格涵蓋每一個 BuildProgress case")
func theSetupSkillEnumeratesEveryProgressCase() throws {
    let root = try repositoryRoot()
    let skill = try String(
        contentsOf: root.appendingPathComponent("plugin/skills/ltm-setup/SKILL.md"),
        encoding: .utf8)

    // `BuildProgress` 的 case 數。用 source 而不是反射：enum 沒有 `allCases`
    // （每個 case 都有 associated value），而加 `CaseIterable` 只為了測試會改
    // 出貨型別。
    let builderSource = try String(
        contentsOf: root.appendingPathComponent("Sources/LTMIndex/IndexBuilder.swift"),
        encoding: .utf8)
    let progressBlock = try #require(
        builderSource.range(of: "public enum BuildProgress: Sendable, Equatable {").map {
            String(builderSource[$0.upperBound...].prefix(while: { $0 != "}" }))
        })
    let caseCount = progressBlock.components(separatedBy: "\n")
        .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ") }.count
    #expect(caseCount > 0, "抓不到 case——這條檢查失去意義，比失敗更糟")

    // skill 的進度表格：抓「何時 | 長相」那張表的資料列。
    let lines = skill.components(separatedBy: "\n")
    let header = try #require(lines.firstIndex { $0.hasPrefix("| 何時 ") })
    var rows = 0
    var index = header + 2  // 跳過表頭與分隔列
    while index < lines.count, lines[index].hasPrefix("|") {
        rows += 1
        index += 1
    }

    #expect(
        rows == caseCount,
        "skill 列的進度行數與 BuildProgress 的 case 數不符——一份宣稱自己完整的列舉漏掉了一種，而使用者會據此判斷 build 是不是卡住了")
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
