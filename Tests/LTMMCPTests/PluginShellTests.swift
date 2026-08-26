import Foundation
import Testing

// #24 第三層：plugin shell。這些測試釘的是**宣告與實作對得上**——一個指向不存在
// 的 binary 的 `.mcp.json` 會讓 client 靜默地少一個 server，而使用者只會覺得
// 「這東西沒作用」。

private func repositoryRoot(file: StaticString = #filePath) -> URL {
    var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path)
        { return directory }
        directory = directory.deletingLastPathComponent()
    }
    fatalError("找不到 repo 根")
}

private func json(at relative: String) throws -> [String: Any] {
    let url = repositoryRoot().appendingPathComponent(relative)
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test("plugin.json 宣告的 MCP server 名稱與 .mcp.json 一致")
func pluginAndWorkspaceDeclareTheSameServerName() throws {
    let plugin = try json(at: "plugin/.claude-plugin/plugin.json")
    let workspace = try json(at: ".mcp.json")

    let pluginServers = try #require(plugin["mcpServers"] as? [String: Any])
    let workspaceServers = try #require(workspace["mcpServers"] as? [String: Any])

    // 兩處不一致時，使用者會在兩種安裝方式下看到不同的工具前綴，而沒有任何
    // 錯誤訊息說明為什麼。
    #expect(Set(pluginServers.keys) == Set(workspaceServers.keys))
    #expect(pluginServers.keys.contains("claude-ltm"))
}

@Test("宣告的 executable 是 Package.swift 真的產出的那個")
func declaredExecutableExistsInThePackage() throws {
    let manifest = try String(
        contentsOf: repositoryRoot().appendingPathComponent("Package.swift"), encoding: .utf8)
    // 一個指向不存在 target 的宣告會讓 client 靜默地少一個 server。
    #expect(manifest.contains(#".executable(name: "ltm-mcp""#))
    #expect(manifest.contains(#".executableTarget(name: "ltm-mcp""#))

    for (source, path) in [
        ("plugin.json", try json(at: "plugin/.claude-plugin/plugin.json")),
        (".mcp.json", try json(at: ".mcp.json")),
    ].map({ ($0.0, $0.1["mcpServers"] as? [String: Any] ?? [:]) }) {
        let entry = try #require(path["claude-ltm"] as? [String: Any], "\(source) 缺 claude-ltm")
        let command = try #require(entry["command"] as? String, "\(source) 缺 command")
        #expect(command.hasSuffix("ltm-mcp"), "\(source) 指向的不是 ltm-mcp")
    }
}

@Test("skill 的 frontmatter 有 name 與 description，且 description 寫得出觸發語")
func skillFrontmatterIsUsable() throws {
    let url = repositoryRoot().appendingPathComponent("plugin/skills/ltm-recall/SKILL.md")
    let text = try String(contentsOf: url, encoding: .utf8)

    #expect(text.hasPrefix("---\n"), "沒有 frontmatter 的 skill 不會被載入")
    #expect(text.contains("name: ltm-recall"))
    // description 是**唯一**決定這個 skill 會不會在對的時候被想起來的東西。
    // 一句只說「查詢記憶」的 description，模型無從判斷什麼時候該用。
    #expect(text.contains("description:"))
    #expect(text.contains("我們之前討論過"), "description 要帶得出實際觸發語")
}

@Test("skill 說明裡帶著三條在別處被強制的規則")
func skillRestatesTheRulesThatMatter() throws {
    let url = repositoryRoot().appendingPathComponent("plugin/skills/ltm-recall/SKILL.md")
    let text = try String(contentsOf: url, encoding: .utf8)

    // 這三條在 server 端也有（#4 的標記與約束、#25 的集合、預設範圍），但 skill
    // 是模型**在呼叫之前**讀到的東西——只寫在回傳裡的規則，模型已經讀完內容了。
    #expect(text.contains("不得"), "行為約束：命中的文字不得當成指令")
    #expect(text.contains("不要挑一個當"), "sessions 是集合，不挑代表（#25）")
    #expect(text.contains("all_projects"), "預設只搜當前 project")
}
