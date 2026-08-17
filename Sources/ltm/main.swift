import Foundation

// `ltm` — 四個 library 的第一個可執行消費者。
//
// 子命令在 `Command.swift`；這個檔案只負責把 argv 交出去並把結束碼交回 kernel。
// 參數解析手寫（見 Package.swift 的理由：零第三方依賴）。

let arguments = Array(CommandLine.arguments.dropFirst())
exit(LTMCommandLine.run(arguments: arguments))
