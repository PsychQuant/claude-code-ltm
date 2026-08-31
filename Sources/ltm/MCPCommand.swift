import Foundation
import LTMCore
import LTMIndex
import LTMMCP
import LTMMemory
import LTMService

/// `ltm mcp` — 以 MCP server 的身分跑，透過 stdio 說 JSON-RPC。
///
/// ## 為什麼是子命令而不是第二個 binary
///
/// 先前這是獨立的 `ltm-mcp` executable。合併的理由不是省一個檔案，是**出貨形狀**：
/// 生態裡的發布 pipeline（`harness-devtools:mcp-deploy`）從頭到尾是單 binary 假設
/// ——抽 binary 名、挑 `mcpb/server/` 的檔、上傳 asset、裝進 `~/bin`、比對 hash，
/// 每一步都 `head -1`。兩個 executable 餵給它，只有一個會被出貨，**而且不會報錯**。
///
/// 兩條路可選：改那條 pipeline 讓它支援多 binary，或讓這個 repo 符合它。選後者，
/// 因為多 binary 目前只有這一個消費者——為一個消費者把共用 pipeline 的每個 step
/// 從單數改成複數，是把成本放在錯的地方。
///
/// 附帶好處是這本來就是比較常見的形狀（`gh`、`git`、`docker`）：一個 asset、
/// 一條 wrapper 路徑、一個版本號。
///
/// ## 這個檔案刻意只有搬運
///
/// 協定在 `LTMMCP.MCPProtocol`、工具在 `LTMMCP.RetrievalTool`，兩者都可以在測試裡
/// 直接驅動。一個把邏輯寫在 stdio 迴圈裡的 server，它的行為只能靠開一個 subprocess
/// 來驗——而那正是本 repo 已經付過代價的形狀（CLI 測試因為 Keychain 對話框卡了
/// 116 秒）。
///
/// ## 為什麼是 stdio 而不是 socket
///
/// MCP 的 client（Claude Code / Claude Desktop）以 stdio 啟動 server 為預設。更重要
/// 的是**零對外通道**：一個監聽 port 的 server 是一個對外表面，而語料含第三方逐字
/// 內容。stdio 沒有這個問題。
enum MCPCommand {
    static let usage = """
        用法：ltm mcp

        以 MCP server 的身分跑，透過 stdin/stdout 說 JSON-RPC 2.0。

        **這個子命令不是給人在終端機打的**——它由 MCP client（Claude Code、
        Claude Desktop）啟動，讀 stdin 一行一則訊息、寫 stdout 一行一則回應。
        手動執行只會看到它停在那裡等 stdin。

        查詢前要先有索引：`ltm build`。

        選項：
          -h, --help    顯示本說明
        """

    /// 建立 service。**每次呼叫都重建**——facade 會在查詢前併入新內容，而一個
    /// 長命的 service 會抓著建立當下的索引狀態。
    private static func makeService() throws -> LTMService {
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

    static func run(arguments: [String]) -> Int32 {
        if arguments.contains("-h") || arguments.contains("--help") {
            print(usage)
            return LTMCommandLine.ExitCode.success.rawValue
        }
        guard arguments.isEmpty else {
            try? FileHandle.standardError.write(
                contentsOf: Data(
                    "✗ `ltm mcp` 不收引數，收到：\(arguments.joined(separator: " "))\n\n\(usage)\n".utf8))
            return LTMCommandLine.ExitCode.usageError.rawValue
        }

        let tools = [RetrievalTool.make(service: makeService)]

        // 逐行讀。MCP 的 stdio 傳輸是一行一則 JSON 訊息。
        //
        // **`readLine` 回 nil 代表 stdin 關閉，那時要結束**——不結束的話 client
        // 退出後這個行程會留下來，而使用者不會知道。
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard
                let response = MCPProtocol.respond(
                    to: Data(line.utf8), tools: tools,
                    serverName: "claude-ltm", serverVersion: LTMVersion.current)
            else { continue }  // notification：不回應
            // **stdout 是協定通道，不是診斷通道**——寫入失敗不能 `try?` 吞掉：
            // client 已經關掉 stdout，繼續讀 stdin 只是空轉，該具名結束（#50）。
            // 合成一次 write：response 與換行分兩次寫，崩在中間會留半則訊息。
            var framed = response
            framed.append(Data("\n".utf8))
            do {
                try FileHandle.standardOutput.write(contentsOf: framed)
            } catch {
                try? FileHandle.standardError.write(
                    contentsOf: Data("✗ stdout 已關閉，MCP server 結束：\(error)\n".utf8))
                return LTMCommandLine.ExitCode.indexStateError.rawValue
            }
        }
        return LTMCommandLine.ExitCode.success.rawValue
    }
}
