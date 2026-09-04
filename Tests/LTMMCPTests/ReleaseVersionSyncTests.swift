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

// MARK: - proactive-recall-cued-hook 6.3：閘門的最低版本與 CHANGELOG 對得上

/// 閘門腳本在跑 `ltm query --format recall` 之前先探 `--help`，探不到就印「版本過舊，需 ≥ X」。
/// X 是**第一個出貨 `--format recall` 的版本**，而那個事實只有 CHANGELOG 知道：
/// - 該旗標仍在 `## Unreleased` 下 → X 必須**大於** `LTMVersion.current`（任何已出貨版本都沒有它）；
/// - 已落在 `## [X.Y.Z]` 下 → X 必須**等於** X.Y.Z。
/// 兩個方向都會漂移：release 時把 Unreleased 改成版本號卻忘了腳本，或腳本先改了而 CHANGELOG 沒跟上。
@Test("閘門的 LTM_RECALL_MIN_VERSION 與 CHANGELOG 裡 --format recall 首次出貨的版本一致")
func recallGateMinimumVersionTracksTheChangelog() throws {
    let root = try releaseRepositoryRoot()
    let gate = try String(
        contentsOf: root.appendingPathComponent("plugin/hooks/ltm-recall-gate.sh"), encoding: .utf8)
    let minimum = try #require(
        gate.firstMatch(of: #/LTM_RECALL_MIN_VERSION="([^"]+)"/#).map { String($0.1) },
        "閘門腳本裡找不到 LTM_RECALL_MIN_VERSION")
    let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
    // CHANGELOG 由新到舊；要的是**首次**出貨的段落，所以掃到最後一個命中而不是第一個
    // （verify R1 logic L2／regression R6：第一版 break 在第一個命中，抓到的是最新提到它的版本）。
    var section = "(none)"
    var found = false
    var current = "(none)"
    for line in changelog.components(separatedBy: "\n") {
        if line.hasPrefix("## ") { current = line }
        if line.contains("--format recall") { found = true; section = current }
    }
    #expect(found, "CHANGELOG 沒有任何一段提到 --format recall")
    func parts(_ v: String) -> [Int] { v.split(separator: ".").compactMap { Int($0) } }
    if section.hasPrefix("## Unreleased") {
        #expect(
            parts(minimum).lexicographicallyPrecedes(parts(LTMVersion.current)) == false && minimum != LTMVersion.current,
            "旗標尚未出貨，閘門的最低版本 \(minimum) 必須大於 LTMVersion.current=\(LTMVersion.current)")
    } else {
        let shipped = try #require(
            section.firstMatch(of: #/## \[(\d+\.\d+\.\d+)\]/#).map { String($0.1) }, "段落標題不是版本：\(section)")
        #expect(minimum == shipped, "閘門要求 ≥ \(minimum)，但 --format recall 首次出貨在 \(shipped)")
    }
}
