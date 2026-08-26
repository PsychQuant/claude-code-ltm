import Foundation
import Testing

@testable import LTMCore

// MARK: - 版本號的單一來源，與看守它的檢查

/// 版本號在發布路徑上出現在四個地方，而它們**不會一起改**。
///
/// `CLAUDE.md`：「一個數字被複述 N 次就是 N 份會漂移的規格，而漂移不會報錯。」
/// 同一則紀錄的下一句同樣適用：**把一份規格收斂到單一位置，不等於它從此不會
/// 漂移，只是把漂移搬到一個沒人看守的地方。收斂之後要補的是一個會變紅的檢查。**
///
/// 這就是那個檢查。`LTMVersion.current` 是來源，其餘三處必須跟上：
///
/// | 位置 | 誰讀它 | 不同步的後果 |
/// |---|---|---|
/// | `mcpb/manifest.json` | `mcp-deploy`、Claude Desktop 安裝對話框 | 使用者看到的版本 ≠ 實際裝的 |
/// | `plugin/.claude-plugin/plugin.json` | Claude Code plugin 系統、marketplace | 同上 |
/// | wrapper 的 `DESIRED_VERSION` | wrapper 決定抓哪個 release asset | **抓到別的版本，而且四步都「成功」** |
///
/// 最後一列是最難看見的：wrapper 去抓 `v0.1.0`、plugin 顯示 `0.2.0`、binary
/// 自報 `0.3.0`——沒有任何一步失敗。
@Test("四處版本號與 LTMVersion.current 一致")
func everyShippedVersionMatchesTheSingleSource() throws {
    let root = try releaseRepositoryRoot()
    let source = LTMVersion.current

    #expect(
        source.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
        "LTMVersion.current（\(source)）不是 semver——git tag 是 v + 這個值")

    for (path, key) in [
        ("mcpb/manifest.json", "version"),
        ("plugin/.claude-plugin/plugin.json", "version"),
    ] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(path) 不是 JSON 物件")
        let declared = try #require(object[key] as? String, "\(path) 缺 \(key)")
        #expect(declared == source, "\(path) 的 \(key)=\(declared)，但 LTMVersion.current=\(source)")
    }

    let wrapper = try String(
        contentsOf: root.appendingPathComponent("plugin/bin/ltm-mcp-wrapper.sh"), encoding: .utf8)
    let declared = try #require(
        wrapper.firstMatch(of: #/DESIRED_VERSION="([^"]+)"/#).map { String($0.1) },
        "wrapper 裡找不到 DESIRED_VERSION")
    #expect(
        declared == source,
        "wrapper 的 DESIRED_VERSION=\(declared)，但 LTMVersion.current=\(source)——不同步時它會去抓別的版本的 asset，而每一步都不會失敗")
}

/// 從測試檔位置往上找 repo 根（同 `StrategyViolationSpecSyncTests` 的做法）。
///
/// 不用 cwd：`swift test` 的工作目錄不保證是 repo 根。
private func releaseRepositoryRoot(file: StaticString = #filePath) throws -> URL {
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
