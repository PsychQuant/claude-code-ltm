import Foundation
import Testing

@testable import LTMMemory

// #31：`pruneUnusable` 就地覆寫（不換 inode，否則 `append` 的 `flock` 會失效），
// 所以崩潰窗口的唯一保險是備份。這幾條鎖住的是**備份確實存在、且等於被覆寫的
// 那份內容**。
//
// 先前備份寫在 `ltm memory` 裡，而 library 層只有一則「呼叫端必須先備份」的註解
// ——那對任何繞過 CLI 的呼叫者都不生效，而崩潰窗口對它們一樣存在。

@Test("修剪會自己建備份，且備份逐字等於被覆寫前的內容")
func pruneWritesABackupIdenticalToWhatItOverwrites() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanup() }

    // 兩行壞的、一行好的。好的那行必須留下，壞的兩行必須進備份。
    let good = #"{"kind":"shown","anchor":{"source":"aaaaaaaaaaaaaaaa","span":[0,1],"contentHash":"0000000000000000000000000000000000000000000000000000000000000000"},"at":0,"policy":"archival"}"#
    let original = Data("{\"broken\n\(good)\n{\"also broken\"}\n".utf8)
    try original.write(to: sandbox.events)

    let store = try FileEventStore(url: sandbox.events)
    let result = try store.pruneUnusable()

    let backup = try #require(result.backup, "有東西要丟就必須有備份")
    #expect(try Data(contentsOf: backup) == original, "備份不等於被覆寫前的內容")
    #expect(try Data(contentsOf: sandbox.events) != original, "原檔應該已被改寫")
}

@Test("沒有東西要丟時不建備份——沒有覆寫就沒有需要保險的窗口")
func pruneWithNothingToDropLeavesNoBackup() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanup() }
    try Data().write(to: sandbox.events)

    let store = try FileEventStore(url: sandbox.events)
    let result = try store.pruneUnusable()

    #expect(result.backup == nil)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path)
            .filter { $0.contains(".bak-") }.isEmpty)
}

// MARK: - 合成樹

private struct Sandbox {
    let root: URL
    var events: URL { root.appendingPathComponent("events.jsonl") }

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ltm-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
