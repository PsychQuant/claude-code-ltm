import Foundation
import Testing

@testable import ltm

// CLI 的入口契約：**失敗要具名且非零**。這一檔釘住的是「沒說話就當成功」這個
// 失敗模式——一個回 0 的錯誤路徑會讓呼叫端（shell script、Stage 2 的 wrapper）
// 以為事情做完了。

@Test("空參數以 usage error 結束，不是靜默成功")
func emptyArgumentsExitNonZero() {
    #expect(LTMCommandLine.run(arguments: []) == LTMCommandLine.ExitCode.usageError.rawValue)
}

@Test("--help 是成功路徑")
func helpExitsZero() {
    #expect(LTMCommandLine.run(arguments: ["--help"]) == LTMCommandLine.ExitCode.success.rawValue)
    #expect(LTMCommandLine.run(arguments: ["-h"]) == LTMCommandLine.ExitCode.success.rawValue)
}

@Test("未知子命令以 usage error 結束")
func unknownSubcommandExitsNonZero() {
    #expect(
        LTMCommandLine.run(arguments: ["frobnicate"])
            == LTMCommandLine.ExitCode.usageError.rawValue)
}
