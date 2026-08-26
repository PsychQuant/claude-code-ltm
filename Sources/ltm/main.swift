import Foundation

// `ltm` — 四個 library 的第一個可執行消費者。
//
// 子命令在 `Command.swift`；這個檔案只負責把 argv 交出去並把結束碼交回 kernel。
// 參數解析手寫（見 Package.swift 的理由：零第三方依賴）。

// **SIGPIPE 忽略掉，讓寫入失敗變成 errno 而不是死亡。**
//
// 預設下，往一個沒有讀端的 pipe 寫會收到 SIGPIPE，預設處置是終止行程——
// `write()` 根本不會回傳。所以「把寫入包在 try? 裡」對這個情況完全無效：
// 行程在那之前就沒了。
//
// 這對 `ltm build` 是實際的資料問題，不是美觀問題：build 可以跑一小時，中途
// 有若干批次已經提交。`ltm build 2> >(head -1)`、把終端機關掉、或任何讓 stderr
// 讀端先走的情況，都會讓那個 build 被 SIGPIPE 殺掉——**只因為它想印一行進度**。
// 進度是附屬品，不該有能力殺掉主工作。
//
// 實測（本 repo，改這行之前）：stderr 導進立刻關閉的 pipe → exit 141 = 128 + 13。
// 這個數字是這行存在的理由，也是它的查核方式：
//
//     ltm build 2> >(exec head -c 0)   # 改之前 141，改之後 0
//
// 代價說明白：忽略之後，往已關閉的 stdout 寫會安靜失敗而不是讓 `ltm query | head`
// 立刻結束。那是可接受的——輸出本來就被截斷了，而讀端已經走了沒有人在等。
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())
exit(LTMCommandLine.run(arguments: arguments))
