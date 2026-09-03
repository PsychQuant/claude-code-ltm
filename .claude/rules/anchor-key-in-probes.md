# 探針與量測跑本機 binary 時，anchor 密鑰走環境變數——不要讓每次執行都問鑰匙圈密碼

## 症狀

用 `.build/release/ltm`（或 `.build/debug/ltm`）對**真實**的 `~/.claude-ltm/derived` 查詢或量測時，
每跑一次就跳一次「要存取鑰匙圈」的密碼視窗。`swift test` 本身不會（見下方「為什麼測試不會」），
會的是手動探針、量測腳本、hook 的手動 smoke。

## 原因

anchor 密鑰存在 macOS Keychain（service `claude-ltm-anchor-key`、account `default`，見
`Sources/LTMMemory/AnchorKeyStore.swift`）。Keychain 的存取控制是**綁 binary** 的：
`~/bin/ltm` 按過「永遠允許」之後不再問，但 `.build/` 底下的 binary **每次重建都是一個新的
binary**，鑰匙圈把它當成陌生程式，每次都問。這不是 bug，是 Keychain 的設計；對它按
「永遠允許」也沒用，下一次 build 又是新的。

## 做法

密鑰有一條環境變數的路：`LTM_ANCHOR_KEY` 設了就不碰鑰匙圈。**在同一條命令裡**由已授權的
`~/bin/ltm` 匯出、直接餵給探針，值不落地：

```bash
LTM_ANCHOR_KEY="$(~/bin/ltm memory --export-key)" .build/release/ltm query "…" --k 3
```

多條命令要共用時，在同一個 shell 裡 `export` 一次即可（Claude Code 的每一次 Bash 呼叫都是
新 shell，所以要放在同一次呼叫裡）。hook 的手動 smoke 同理：`LTM_ANCHOR_KEY=… LTM_BIN=.build/release/ltm plugin/hooks/ltm-recall-gate.sh`。

## 不要做的事

- **不要 `echo`、不要寫進檔案、不要進 commit、不要貼進對話**——它是密鑰，命令替換（`$(…)`）
  的用法就是為了讓它只存在於行程環境裡。
- **不要對真實索引用假密鑰**（例如測試用的 `2a2a…`）。anchor 是用這把鑰匙算出來的：鑰匙不同，
  算出來的 anchor 就對不上 `~/.claude-ltm/memory/` 裡的事件——查詢照樣成功、事件全部變成
  orphan，沒有任何錯誤訊息。這正是「安靜失效」那一類。
- **不要為了省事把 `.build/` 的 binary 拷到 `~/bin`**。手動安裝有 inode 陷阱（見 memory 筆記
  `macos-overwrite-signed-binary-sigkill`），而且會讓「目前跑的是哪一版」失去單一答案。

## 為什麼測試不會問

- 單元測試用 `AnchorKey.forTesting`，不碰鑰匙圈。
- `CLICommandTests` / `MCPStdoutTests` 起子行程時在環境裡放固定的 `LTM_ANCHOR_KEY`，
  而且指向 fixture 語料與臨時的 derived 目錄——**從不碰真實索引**，所以假密鑰在那裡是對的。

要是哪天 `swift test` 也開始問密碼，那代表某條測試碰到了真實鑰匙圈或真實索引，那是測試的 bug，
不是要按「允許」解決的事。

## 給 hook 的一句提醒

`plugin/hooks/ltm-recall-gate.sh` 每個命中線索的 prompt 都會跑一次 `~/bin/ltm query`。它用的是
`~/bin/ltm`（wrapper 安裝的那一份），第一次跑要按一次「永遠允許」；沒按的話每一輪都會跳密碼視窗，
而 hook 在 30 秒逾時後會被 Claude Code 靜默丟棄。
