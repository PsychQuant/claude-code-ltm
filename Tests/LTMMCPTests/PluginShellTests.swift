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

@Test("每個 MCP 宣告最終都落到 Package.swift 真的產出的那個 executable 的真子命令上")
func declaredEntryPointsResolveToARealSubcommandOfARealExecutable() throws {
    let root = repositoryRoot()
    let manifest = try String(
        contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
    // 一個指向不存在 target 的宣告會讓 client 靜默地少一個 server。
    #expect(manifest.contains(#".executable(name: "ltm""#))
    #expect(manifest.contains(#".executableTarget(name: "ltm""#))
    // **`ltm-mcp` 不得再是一個 executable。** 合併之後若有人把它加回來，兩份
    // 出貨規格就重新分岔（見 `Sources/ltm/MCPCommand.swift`），而 pipeline 只會
    // 出貨其中一個且不報錯。
    #expect(!manifest.contains(#"name: "ltm-mcp""#), "ltm-mcp 已併入 `ltm mcp`，不該再是 target")

    // 這條測試現在驗的是**整條鏈**，不是一個字尾。先前它斷言 command 以
    // `ltm-mcp` 結尾——那在 plugin 改用 wrapper 之後就只是在比對一個檔名，
    // 而 wrapper 裡面 exec 什麼完全沒被看著。
    //
    // 兩個入口的形狀不同，所以各自驗各自的那一段：
    //  · `.mcp.json`（開發用，直接指 binary）→ command 指 `ltm`，args 帶子命令
    //  · `plugin.json`（出貨用，指 wrapper）→ wrapper 存在、可執行、且 exec `ltm mcp`
    let workspace = try #require(
        (try json(at: ".mcp.json")["mcpServers"] as? [String: Any])?["claude-ltm"]
            as? [String: Any])
    let workspaceCommand = try #require(workspace["command"] as? String)
    #expect(workspaceCommand.hasSuffix("/ltm"), ".mcp.json 應直接指向 ltm binary")
    #expect(
        (workspace["args"] as? [String]) == ["mcp"],
        ".mcp.json 少了 `mcp` 子命令——沒有它 server 不會啟動，而 client 只會看到它退出")

    let plugin = try #require(
        (try json(at: "plugin/.claude-plugin/plugin.json")["mcpServers"] as? [String: Any])?[
            "claude-ltm"] as? [String: Any])
    let pluginCommand = try #require(plugin["command"] as? String)
    let wrapperName = try #require(pluginCommand.split(separator: "/").last).description
    let wrapper = root.appendingPathComponent("plugin/bin/\(wrapperName)")
    #expect(
        FileManager.default.isExecutableFile(atPath: wrapper.path),
        "plugin.json 指向 \(wrapperName)，但它不存在或沒有執行權限")
    let script = try String(contentsOf: wrapper, encoding: .utf8)
    #expect(
        script.contains(#"exec "$LTM" mcp"#),
        "wrapper 沒有 exec `ltm mcp`——plugin.json 指到它，而它指到哪沒有人看著")

    // 子命令必須真的存在於派發表裡。這一段是先前整條鏈上唯一沒被驗的一環：
    // `ltm mcp` 打錯字的話，上面每一條斷言都仍然成立。
    let dispatcher = try String(
        contentsOf: root.appendingPathComponent("Sources/ltm/CommandLine.swift"), encoding: .utf8)
    #expect(dispatcher.contains(#"case "mcp":"#), "派發表裡沒有 `mcp` 子命令")
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
