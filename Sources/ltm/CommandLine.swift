import Foundation

/// argv → 子命令 → 結束碼。
///
/// 手寫解析，理由見 Package.swift。規模上也划算：子命令與旗標都少，一個依賴的
/// 審查成本高於這幾十行。
///
/// （這裡先前寫「兩個子命令、七個旗標」，而當時已經有四個子命令——一個被複述的
/// 數字就是一份會漂移的規格。把它拿掉而不是更新它。）
public enum LTMCommandLine {
    public static let usage = """
        用法：ltm <子命令> [選項]

        子命令：
          build     掃描語料並建立衍生索引（預設增量）
          query     對索引下查詢
          mark      把一次互動記成事件——使用歷史唯一的來源
          memory    檢查記憶層事件檔，必要時修剪不可用的紀錄
          mcp       以 MCP server 的身分跑（由 client 啟動，不是給人打的）

        選項：
          -h, --help    顯示本說明

        `ltm <子命令> --help` 顯示該子命令的選項。
        """

    /// 結束碼。非零一律**指名原因**——「失敗訊息要說出補救命令」是 ltm-cli
    /// capability 的 requirement，不是禮貌。
    public enum ExitCode: Int32 {
        case success = 0
        case usageError = 2
        case indexStateError = 3
        case scopeError = 4
        case corpusError = 5
        case lockHeld = 6
    }

    public static func run(arguments: [String]) -> Int32 {
        guard let first = arguments.first else {
            // `try?`：stderr 被關掉時（EPIPE）usage 印不出來，但診斷訊息沒有
            // 能力殺掉行程——legacy `write(_:)` 丟 ObjC exception，Swift 接不住，
            // 行程以 SIGABRT 死（#50；SIG_IGN 只把 SIGPIPE 換成 EPIPE，接不住一樣死）。
            try? FileHandle.standardError.write(contentsOf: Data((usage + "\n").utf8))
            return ExitCode.usageError.rawValue
        }
        switch first {
        case "-h", "--help":
            print(usage)
            return ExitCode.success.rawValue
        case "build":
            return BuildCommand.run(arguments: Array(arguments.dropFirst()))
        case "query":
            return QueryCommand.run(arguments: Array(arguments.dropFirst()))
        case "mark":
            return MarkCommand.run(arguments: Array(arguments.dropFirst()))
        case "memory":
            return MemoryCommand.run(arguments: Array(arguments.dropFirst()))
        case "mcp":
            return MCPCommand.run(arguments: Array(arguments.dropFirst()))
        default:
            // `try?`：同上（#50）。
            try? FileHandle.standardError.write(
                contentsOf: Data("未知子命令：\(first)\n\n\(usage)\n".utf8))
            return ExitCode.usageError.rawValue
        }
    }
}
