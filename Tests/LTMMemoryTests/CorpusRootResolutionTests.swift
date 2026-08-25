import Foundation
import Testing

@testable import LTMMemory

// #20 item 5 與 item 7。兩條都在合成樹上跑。

@Test("預設語料根認得 CLAUDE_CONFIG_DIR")
func defaultCorpusRootHonoursTheConfigDirectoryOverride() throws {
    // 先前 `readOnlyRoot` 寫死 `$HOME/.claude/projects`。使用者搬過設定目錄之後，
    // 守衛看的是一個**空目錄**——「不得寫進語料」整條靜默失效，而失效的方向是
    // 放行：真正的語料落在別處，路徑檢查對它沒有意見。
    let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-config-dir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    let previous = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
    setenv("CLAUDE_CONFIG_DIR", sandbox.path, 1)
    defer {
        if let previous { setenv("CLAUDE_CONFIG_DIR", previous, 1) } else {
            unsetenv("CLAUDE_CONFIG_DIR")
        }
    }

    let root = CorpusLocation.readOnlyRoot
    #expect(root.deletingLastPathComponent().path == sandbox.path)
    #expect(root.lastPathComponent == "projects")

    // 而圍籬要跟著動：搬過去之後，那棵樹底下的路徑必須被擋。
    //
    // 這棵樹要真的存在：圍籬用 `(st_dev, st_ino)` 比身分，而一個不存在的目錄
    // 沒有 inode 可比。那不是弱點——不存在的語料沒有東西需要保護——但它是這條
    // 測試必須自己滿足的前提，寫出來免得下一個人以為斷言在驗別的東西。
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let insideRelocated = root.appendingPathComponent("a-project/events.jsonl")
    #expect(CorpusPolicy().isInsideReadOnlyCorpus(insideRelocated))
}

@Test("symlink 迴圈耗盡預算時解析回 nil，讓 fail-closed 分支真的可達")
func resolutionExhaustionIsReportedRatherThanPapered() throws {
    // 先前預算耗盡是 `return path`——非 `nil`，所以呼叫端那條「解析不出來就當成
    // 在語料內」的 fail-closed 分支**永遠不會執行**。註解宣稱的姿態沒有執行點。
    let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-symloop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sandbox) }

    // 兩個互指的 symlink：解析它就是一個無窮迴圈，只有預算能停下來。
    let a = sandbox.appendingPathComponent("a")
    let b = sandbox.appendingPathComponent("b")
    try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
    try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)

    #expect(CorpusLocation.fullyResolve(a.path) == nil)

    // 而 fail-closed 的意思是**當成在語料內**——拒絕，不是放行。
    #expect(CorpusLocation.isInside(a, root: CorpusLocation.readOnlyRoot))
}
