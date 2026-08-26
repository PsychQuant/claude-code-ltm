import Foundation
import Testing

@testable import LTMMCP

// #24：MCP server 的協定層。這些測試直接驅動 `respond`，不開 subprocess——
// 一個把邏輯寫在 stdio 迴圈裡的 server，行為只能靠 subprocess 驗，而本 repo
// 已經付過那個代價（CLI 測試因 Keychain 對話框卡了 116 秒）。

private let probeTool = MCPTool(
    name: "probe", description: "測試用", inputSchema: ["type": "object"]
) { arguments in
    if arguments["explode"] as? Bool == true { throw ProbeFailure() }
    return "probe-ok:\(arguments["echo"] as? String ?? "")"
}

private struct ProbeFailure: Error, CustomStringConvertible {
    var description: String { "刻意失敗" }
}

private func respond(_ object: [String: Any]) -> [String: Any]? {
    let data = try! JSONSerialization.data(withJSONObject: object)
    guard
        let out = MCPProtocol.respond(
            to: data, tools: [probeTool], serverName: "t", serverVersion: "0")
    else { return nil }
    return (try! JSONSerialization.jsonObject(with: out)) as? [String: Any]
}

@Test("initialize 回宣告的協定版本與 server 身分")
func initializeAnnouncesTheProtocolVersion() {
    let result = respond(["jsonrpc": "2.0", "id": 1, "method": "initialize"])
    let payload = result?["result"] as? [String: Any]
    #expect(payload?["protocolVersion"] as? String == MCPProtocol.protocolVersion)
    #expect((payload?["serverInfo"] as? [String: Any])?["name"] as? String == "t")
}

@Test("tools/list 列出工具及其 schema")
func toolsListDescribesTheTools() {
    let result = respond(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
    let tools = (result?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
    #expect(tools?.count == 1)
    #expect(tools?.first?["name"] as? String == "probe")
    #expect(tools?.first?["inputSchema"] != nil, "沒有 schema 的工具 client 不知道怎麼呼叫")
}

@Test("tools/call 把回傳值放進 text content")
func toolsCallReturnsTextContent() {
    let result = respond([
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": ["name": "probe", "arguments": ["echo": "嗨"]],
    ])
    let payload = result?["result"] as? [String: Any]
    let content = payload?["content"] as? [[String: Any]]
    #expect(content?.first?["text"] as? String == "probe-ok:嗨")
    #expect(payload?["isError"] as? Bool == false)
}

@Test("工具錯誤走 isError，不走 JSON-RPC error")
func toolFailuresAreResultsNotProtocolErrors() {
    // 兩者混在一起會讓 client 把「可以顯示給使用者的訊息」當成傳輸故障。
    let result = respond([
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": ["name": "probe", "arguments": ["explode": true]],
    ])
    #expect(result?["error"] == nil, "工具失敗不是協定錯誤")
    let payload = result?["result"] as? [String: Any]
    #expect(payload?["isError"] as? Bool == true)
    #expect(
        ((payload?["content"] as? [[String: Any]])?.first?["text"] as? String)?
            .contains("刻意失敗") == true)
}

@Test("未知方法與未知工具各自回對應的錯誤")
func unknownMethodAndUnknownToolAreDistinguished() {
    let method = respond(["jsonrpc": "2.0", "id": 5, "method": "resources/list"])
    #expect((method?["error"] as? [String: Any])?["code"] as? Int == -32601)

    let tool = respond([
        "jsonrpc": "2.0", "id": 6, "method": "tools/call",
        "params": ["name": "nope", "arguments": [:] as [String: Any]],
    ])
    #expect((tool?["error"] as? [String: Any])?["code"] as? Int == -32602)
}

@Test("notification（沒有 id）不回應——回了是協定違規")
func notificationsGetNoResponse() {
    // 對 notification 回一則訊息會讓某些 client 掛住。
    let data = try! JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "method": "notifications/initialized",
    ])
    #expect(
        MCPProtocol.respond(to: data, tools: [probeTool], serverName: "t", serverVersion: "0")
            == nil)
}

@Test("解析不出來的輸入仍然回錯誤，不靜默丟棄")
func malformedInputStillGetsAnError() {
    // 靜默丟棄會讓對方等到 timeout。
    let out = MCPProtocol.respond(
        to: Data("{ 這不是 JSON".utf8), tools: [probeTool], serverName: "t", serverVersion: "0")
    let object = out.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    #expect((object?["error"] as? [String: Any])?["code"] as? Int == -32700)
}
