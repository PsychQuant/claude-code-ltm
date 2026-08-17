import Foundation

/// argv → 子命令 → 結束碼。
///
/// 手寫解析，理由見 Package.swift。規模上也划算：兩個子命令、七個旗標，
/// 一個依賴的審查成本高於這幾十行。
public enum LTMCommandLine {
    public static let usage = """
        用法：ltm <子命令> [選項]

        子命令：
          build     掃描語料並建立衍生索引（預設增量）
          query     對索引下查詢

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
            FileHandle.standardError.write(Data((usage + "\n").utf8))
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
        default:
            FileHandle.standardError.write(Data("未知子命令：\(first)\n\n\(usage)\n".utf8))
            return ExitCode.usageError.rawValue
        }
    }
}
