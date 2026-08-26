import Foundation

/// MCP 的 JSON-RPC 訊息處理。
///
/// ## 為什麼自己寫而不是拉一個 SDK
///
/// 本專案的 `Package.swift` 有**零個**外部套件依賴，而那不是巧合：語料含第三方
/// 逐字內容，任何新依賴都是一個新的、要被信任的程式碼來源。MCP 在這裡用到的
/// 部分是 JSON-RPC 2.0 的三個方法（`initialize`、`tools/list`、`tools/call`），
/// 那比審一個 SDK 便宜。
///
/// **誠實邊界**：這是 MCP 的一個**子集**，不是完整實作。沒有 resources、沒有
/// prompts、沒有 sampling、沒有 notification。缺的東西是具名的，不是「還沒測到
/// 的洞」——一個宣稱實作了 MCP 的東西若少了這些，讀者會以為它們壞了而不是沒有。
public enum MCPProtocol {
    /// 本 server 宣告的協定版本。
    public static let protocolVersion = "2024-11-05"

    /// 處理一則請求，回傳要寫回去的一則回應。
    ///
    /// 回 `nil` 代表**這則訊息不需要回應**（JSON-RPC 的 notification：沒有 `id`）。
    /// 對 notification 回一則訊息是協定違規，而且會讓某些 client 掛住。
    public static func respond(
        to line: Data, tools: [MCPTool], serverName: String, serverVersion: String
    ) -> Data? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            // **解析不出來時仍然要回錯誤**，而且 id 用 null——client 才知道它送的
            // 東西壞了。靜默丟棄會讓對方等到 timeout。
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": errorObject(-32700, "Parse error")])
        }
        let method = object["method"] as? String ?? ""
        let id = object["id"]

        guard let id, !(id is NSNull) else {
            // notification：不回應。
            return nil
        }

        switch method {
        case "initialize":
            return encode([
                "jsonrpc": "2.0", "id": id,
                "result": [
                    "protocolVersion": protocolVersion,
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": serverName, "version": serverVersion],
                ],
            ])
        case "tools/list":
            return encode([
                "jsonrpc": "2.0", "id": id,
                "result": ["tools": tools.map(\.descriptor)],
            ])
        case "tools/call":
            return callTool(object: object, id: id, tools: tools)
        default:
            return encode([
                "jsonrpc": "2.0", "id": id,
                "error": errorObject(-32601, "Method not found: \(method)"),
            ])
        }
    }

    private static func callTool(object: [String: Any], id: Any, tools: [MCPTool]) -> Data? {
        let params = object["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        guard let tool = tools.first(where: { $0.name == name }) else {
            return encode([
                "jsonrpc": "2.0", "id": id,
                "error": errorObject(-32602, "Unknown tool: \(name)"),
            ])
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            let text = try tool.run(arguments)
            return encode([
                "jsonrpc": "2.0", "id": id,
                "result": ["content": [["type": "text", "text": text]], "isError": false],
            ])
        } catch {
            // **工具錯誤走 `isError`，不走 JSON-RPC error**。後者是「協定層出錯」，
            // 而「查詢失敗」是工具的正常結果之一——混在一起會讓 client 把可以
            // 顯示給使用者的訊息當成傳輸故障。
            return encode([
                "jsonrpc": "2.0", "id": id,
                "result": [
                    "content": [["type": "text", "text": "✗ \(error)"]],
                    "isError": true,
                ],
            ])
        }
    }

    private static func errorObject(_ code: Int, _ message: String) -> [String: Any] {
        ["code": code, "message": message]
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// 一個 MCP tool。
public struct MCPTool: Sendable {
    public let name: String
    public let description: String
    /// JSON Schema。`[String: Any]` 不是 `Sendable`，所以存成已序列化的
    /// bytes——**不是為了效率，是為了讓 `MCPTool` 能跨 concurrency 邊界**。
    public let inputSchemaData: Data
    /// 執行。回傳的字串就是給 client 的 text content。
    public let run: @Sendable ([String: Any]) throws -> String

    public init(
        name: String, description: String, inputSchema: [String: Any],
        run: @escaping @Sendable ([String: Any]) throws -> String
    ) {
        self.name = name
        self.description = description
        self.inputSchemaData =
            (try? JSONSerialization.data(withJSONObject: inputSchema)) ?? Data("{}".utf8)
        self.run = run
    }

    var descriptor: [String: Any] {
        let schema = (try? JSONSerialization.jsonObject(with: inputSchemaData)) ?? [:]
        return ["name": name, "description": description, "inputSchema": schema]
    }
}
