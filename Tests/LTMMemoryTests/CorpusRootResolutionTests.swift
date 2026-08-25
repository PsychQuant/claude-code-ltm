import Foundation
import Testing

@testable import LTMMemory

// #20 item 5 與 item 7。兩條都在合成樹上跑。

@Test("預設語料根認得 CLAUDE_CONFIG_DIR")
func defaultCorpusRootHonoursTheConfigDirectoryOverride() throws {
    // 先前 `readOnlyRoot` 寫死 `$HOME/.claude/projects`。使用者搬過設定目錄之後，
    // 守衛看的是一個**空目錄**——「不得寫進語料」整條靜默失效，而失效的方向是
    // 放行：真正的語料落在別處，路徑檢查對它沒有意見。
    //
    // **這條不動 `CLAUDE_CONFIG_DIR`**。第一版動了，而那個環境變數是 process
    // 全域的、swift-testing 預設平行跑——於是它讓
    // `multiHopDanglingSymlinkChainIsFollowedToTheEnd` 三次跑紅一次。純函式版本
    // 把環境當參數收，測試因此不必污染別人。
    let relocated = CorpusLocation.readOnlyRoot(
        configDirectory: "/somewhere/else/.claude", home: "/unused")
    #expect(relocated.path == "/somewhere/else/.claude/projects")

    // 沒設時退回 `$HOME/.claude/projects`。
    let fallback = CorpusLocation.readOnlyRoot(configDirectory: nil, home: "/Users/probe")
    #expect(fallback.path == "/Users/probe/.claude/projects")

    // 而生產路徑讀的就是這個函式——兩者不得分岔。
    #expect(
        CorpusLocation.readOnlyRoot
            == CorpusLocation.readOnlyRoot(
                configDirectory: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
                home: NSHomeDirectory()))
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
