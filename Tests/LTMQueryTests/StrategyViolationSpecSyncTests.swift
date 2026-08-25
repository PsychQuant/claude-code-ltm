import Foundation
import Testing

// `memory-strategy` spec 的 seam requirement 列了 seam 會拋的每一個違規名，並宣稱
// 那份列舉與實作逐一對應。**這一檔是那句宣稱的執行點。**
//
// ## 為什麼需要它
//
// #14 的三輪 verify 是同一個缺陷的三次重演，而第三次推翻了前兩次的修法：
//
// - **R1**：列舉漏了三個違規（`rerank` 在進 `rerankChecked` 之前跑的前置檢查），
//   而同一段文字宣稱「每個可達的 `throw` 都在清單裡」。
// - **R2**：修法在旁邊寫下查法（三個集合逐一對應），並把「檢查條數」從四處註解
//   拿掉、只留 spec 一份。commit message 稱之為結構性修法。
// - **R3**：`Package.swift` 的第五處從未被拿掉，兩輪都漏。而且當時的兩份產物互相
//   矛盾——commit message 說「四處」，同一次 commit 新寫的註解說「五個地方」，
//   **沒有一份對，也沒有任何東西比對它們**。
//
// 所以 R2 那個修法買到的東西比它宣稱的少：**把一份規格收斂到單一位置，不等於它
// 從此不會漂移，只是把漂移搬到一個沒人看守的地方。** 收斂之後要補的是一個會變紅
// 的檢查——就是這一檔。
//
// ## 它驗什麼、不驗什麼
//
// 驗的是**名字的三方對應**：enum 的 case、`throw` 站點、spec 的列舉。
// 加一個 case 而不寫進 spec 會紅；spec 寫一個不存在的名字會紅；新增一個拋既有
// 違規的站點不會紅（那是同一個名字）。
//
// **不驗語意**：spec 對某一項的描述是否正確、它是否真的無條件、順序是否與入口
// 實際執行順序一致——這些這一檔都看不出來，而 R2 的兩個 CRITICAL 恰好都是那一類。
// 具名的缺口好過假裝有守衛。
//
// `StrategyViolation` 的 case 帶關聯值，所以無法合成 `CaseIterable`，只能從原始碼
// 解析。這是刻意的取捨：靠型別系統拿不到這份清單，而一個會紅的近似檢查，勝過一句
// 沒有執行點的宣稱。

@Test("spec 列舉的違規名與 enum 的 case 逐一對應")
func specEnumerationMatchesViolationCases() throws {
    let cases = try violationCaseNames()
    let listed = try specViolationNames()

    #expect(cases.isEmpty == false, "解析不到任何 case，代表解析器壞了而不是實作乾淨")
    #expect(
        cases.subtracting(listed).isEmpty,
        "這些違規存在於 StrategyViolation 但沒有寫進 spec 的列舉：\(cases.subtracting(listed).sorted())")
    #expect(
        listed.subtracting(cases).isEmpty,
        "spec 的列舉寫了不存在的違規：\(listed.subtracting(cases).sorted())")
}

@Test("每個 throw 站點拋的違規名都在 spec 的列舉裡")
func everyThrownViolationIsListedInTheSpec() throws {
    let thrown = try thrownViolationNames()
    let listed = try specViolationNames()

    #expect(thrown.isEmpty == false, "掃不到任何 throw 站點，代表掃描器壞了")
    #expect(
        thrown.subtracting(listed).isEmpty,
        "這些違規會被拋出但沒有寫進 spec 的列舉：\(thrown.subtracting(listed).sorted())")
}

// MARK: - 來源

/// `StrategyViolation` 宣告的 case 名。
private func violationCaseNames() throws -> Set<String> {
    let source = try read("Sources/LTMQuery/MemoryStrategy.swift")
    guard let start = source.range(of: "public enum StrategyViolation") else {
        throw SyncCheckFailure.enumNotFound
    }
    // enum 之後的第一個頂層 `}`（行首單獨一個）為界。
    let rest = source[start.upperBound...]
    let body = rest.range(of: "\n}").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
    return Set(matches(of: #"case ([a-zA-Z][a-zA-Z0-9]*)"#, in: body))
}

/// `Sources/` 底下所有 `throw StrategyViolation.<name>` 的 name。
private func thrownViolationNames() throws -> Set<String> {
    var names: Set<String> = []
    let root = try repositoryRoot().appendingPathComponent("Sources")
    guard
        let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true })
    else { throw SyncCheckFailure.sourcesUnreadable }

    for case let url as URL in walker where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        names.formUnion(
            matches(of: #"throw StrategyViolation\.([a-zA-Z][a-zA-Z0-9]*)"#, in: text))
    }
    return names
}

/// spec 的 seam requirement 在「Violation:」/「Violations:」之後具名的違規。
///
/// 只掃那個 requirement 的列舉段，不掃整份 spec——別處出現的識別碼（例如敘述
/// 某個歷史缺陷時提到的名字）不算列舉的一部分。
private func specViolationNames() throws -> Set<String> {
    let spec = try read("openspec/specs/memory-strategy/spec.md")
    guard
        let start = spec.range(of: "**Ordering correctness is enforced at the seam"),
        let end = spec.range(of: "**The privacy boundary", range: start.upperBound..<spec.endIndex)
    else { throw SyncCheckFailure.specSectionNotFound }

    let section = String(spec[start.upperBound..<end.lowerBound])
    var names: Set<String> = []
    for line in section.split(separator: "\n") {
        guard let marker = line.range(of: "Violation:") ?? line.range(of: "Violations:") else {
            continue
        }
        names.formUnion(matches(of: "`([a-zA-Z][a-zA-Z0-9]*)`", in: String(line[marker.upperBound...])))
    }
    return names
}

// MARK: - 工具

private func matches(of pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let full = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: full).compactMap { match in
        Range(match.range(at: 1), in: text).map { String(text[$0]) }
    }
}

private func read(_ relativePath: String) throws -> String {
    try String(
        contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
}

/// 從測試檔位置往上找 repo 根（同 `PackageDependencyTests` 的做法）。
///
/// 不用 cwd：`swift test` 的工作目錄不保證是 repo 根，而 `#filePath` 是編譯期
/// 就固定的絕對路徑。
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
    throw SyncCheckFailure.repositoryRootNotFound
}

private enum SyncCheckFailure: Error {
    case enumNotFound
    case sourcesUnreadable
    case specSectionNotFound
    case repositoryRootNotFound
}
