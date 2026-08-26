import Foundation
import LTMCore
import LTMIndex
import LTMMCP
import LTMMemory
import LTMService

// MCP server 的 stdio 殼（#24）。
//
// **這個檔案刻意只有搬運**：協定在 `LTMMCP.MCPProtocol`、工具在
// `LTMMCP.RetrievalTool`，兩者都可以在測試裡直接驅動。一個把邏輯寫在 stdio
// 迴圈裡的 server，它的行為只能靠開一個 subprocess 來驗——而那正是本 repo
// 已經付過代價的形狀（CLI 測試因為 Keychain 對話框卡了 116 秒）。
//
// ## 為什麼是 stdio 而不是 socket
//
// MCP 的 client（Claude Code / Claude Desktop）以 stdio 啟動 server 為預設。
// 更重要的是**零對外通道**：一個監聽 port 的 server 是一個對外表面，而語料含
// 第三方逐字內容。stdio 沒有這個問題。

/// 建立 service。**每次呼叫都重建**——facade 會在查詢前併入新內容，而一個
/// 長命的 service 會抓著建立當下的索引狀態。
private func makeService() throws -> LTMService {
    let corpusRoot =
        ProcessInfo.processInfo.environment["LTM_CORPUS_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? CorpusLocation.readOnlyRoot
    let derivedRoot =
        ProcessInfo.processInfo.environment["LTM_DERIVED_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? DerivedLocation.defaultRoot
    return try LTMService.make(
        corpusRoot: corpusRoot, derivedRoot: derivedRoot,
        embedder: try ContextualEmbeddingProvider(), eventStore: nil,
        anchorKey: try AnchorKeyStore.loadOrCreate(), memoryRoot: nil)
}

let tools = [RetrievalTool.make(service: makeService)]

// 逐行讀。MCP 的 stdio 傳輸是一行一則 JSON 訊息。
//
// **`readLine` 回 nil 代表 stdin 關閉，那時要結束**——不結束的話 client 退出後
// 這個行程會留下來，而使用者不會知道。
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard
        let response = MCPProtocol.respond(
            to: Data(line.utf8), tools: tools,
            serverName: "claude-ltm", serverVersion: "0.1.0")
    else { continue }  // notification：不回應
    FileHandle.standardOutput.write(response)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
