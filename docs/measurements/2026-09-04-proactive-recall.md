# 主動回想 hook 的成本量測（proactive-recall-cued-hook，#64）

**日期**：2026-09-04。**機器**：M5 Max、128 GB。**binary**：本 change 的 `.build/release/ltm`
（release 建置，含 `--format recall`／`--exclude-session`／`--max-refresh-seconds`）。**索引**：
真實的 `~/.claude-ltm/derived`（約 64 萬 chunk；本 session `3a2ceb7e…` 佔 19,945 個）。
**anchor 密鑰**：由 `~/bin/ltm memory --export-key` 匯出到環境，不碰鑰匙圈
（`.claude/rules/anchor-key-in-probes.md`）。所有數字都是 n=20 的單機樣本。

**本紀錄不宣稱任何「回答變好」**——沒有評估集（#33），量得到的只有延遲、context 成本、
命中率與落後次數。

## 1. hook 每輪牆鐘時間

驅動：`printf '{"session_id":…,"cwd":…,"prompt":…}' | plugin/hooks/ltm-recall-gate.sh`，
`LTM_BIN` 指向 release binary、`CLAUDE_PLUGIN_ROOT` 指向 `plugin/`，計時含 bash 啟動與 python 抽欄位。

| 情境 | n | p50 | p90 | max | 注入 bytes（平均） | 命中數（平均） | 落後行 | 通知行 |
|---|---|---|---|---|---|---|---|---|
| 閘門未命中（prompt「幫我改這個函式 N」） | 20 | 69 ms | 81 ms | 84 ms | 0 | — | — | — |
| 閘門命中，cwd＝本 repo，排除本 session | 20 | 949 ms | 1,064 ms | 1,620 ms | 345 | **0.0** | 0 | 0 |
| 閘門命中，cwd＝`Akashic-Library`，排除一個不存在的 session | 20 | 1,040 ms | 1,078 ms | 1,472 ms | 1,084 | 3.0 | 0 | 0 |

- 未命中輪次的成本是 hook 本身（bash＋python＋grep），規格的 100 ms 上限有餘裕。
- 命中輪次 ≈ 1 s，與 `ltm query` 穩態（2026-09-03：p50 1.12 s）同量級——hook 沒有加多少。
- 第二列 0 命中**不是 bug**：本 repo 自 2026-08-26 起只有這一個 session id（一直 `--resume`），
  19,945 個 chunk 全在它名下；把它排除後，這個查詢在前 200 名裡只剩 1 個別的 session 的候選
  （`--k 50 --exclude-session` 直接跑也是 n=1）。「回想自己的 session」在單一長 session 的專案裡
  本來就沒東西可想。這一列同時記錄了修法前的形狀：**k 若在排除前截斷**，前三名全是本 session
  → 空區塊（345 bytes 只有 banner）；修法是排除後再截 k（多撈 4·k，上限 1,000）。
- 第一次命中輪次的 max（2.4 s／1.6 s／1.5 s）都是 backlog 併入：hook 為自己的查詢設
  `LTM_BUILD_BATCH_CHUNKS=200`，之後各輪回到 ~1 s。

## 2. 併入預算的粒度（為什麼 hook 要設 200 一批）

第一版量測**二十輪全部逾時**（21.5 s，一行通知）：`--max-refresh-seconds 15` 的判定只在批次
邊界，預設 2,000 chunk 一批；本機嵌入速度由 2026-09-03 的 build 推得 11,935 chunk／152 s
≈ **78 chunk/s**，所以第一個邊界在 ~25 s 之後——預算永遠等不到。改成 200 一批（~2.6 s）後
逾時歸零，一輪最多併入約五批，大 backlog 跨幾輪回想慢慢消化。判準寫進 design decision 3。

## 3. 閘門命中率（線索表對真實 prompt）

方法：讀 `~/.claude/projects/<project>/*.jsonl` 的 user turn 文字，剝掉 `<system-reminder>`，
取最後 200 則，對 `plugin/hooks/recall-cues.txt` 的每條 ERE 比對（Python `re`）。

| project | prompt 數 | 命中 | 命中率 |
|---|---|---|---|
| `-Users-che-Developer-Akashic-Library`（**含**系統產生的 prompt） | 200 | 60 | 30.0% |
| 同上（worktree 分身，含系統產生） | 200 | 43 | 21.5% |
| `-Users-che-Developer-Akashic-Library`（只算使用者打字） | 200 | 18 | 9.0% |
| 同上 worktree 分身（只算使用者打字） | 131 | 12 | 9.2% |
| 教學專案（只算使用者打字） | 200 | 5 | 2.5% |

「系統產生」＝以 `<` 開頭（slash 展開）、`Base directory for this skill`（skill 本文）、
`This session is being continued`（compaction 續接）——它們的樣板文字含 `earlier`／`previously`，
把命中率灌到兩三成。閘門因此把這三種前綴一律當未命中（封閉列舉，會漏）。三個 project 合計
各線索命中次數：`earlier` 17、`之前` 9、`先前` 7、`previously` 6、`當初` 2、`上回` 1；其餘為 0。

## 4. 基線（重述，#64 diagnosis）

本 repo 之外，2,313 個 session 檔中真正的 `ltm_query` tool_use 為 **0**——先前算出的 44 是工具名
出現在 deferred-tools 清單訊息裡，不是呼叫。

## 誠實邊界

- 單機、單日、n=20；沒有負載對照；索引是活的（量測期間本 session 自己的 jsonl 也在成長）。
- 命中率的三個 project 都是使用者自己的語料，不代表別人的用語；線索表本來就是列舉。
- 量測用的查詢字串已進本 session 的 transcript，之後同字串的查詢會先召回這裡（#63）。
- `all_projects` 未量；`always` 模式未量（開關存在，數字沒有）。
- 沒有任何一個數字能說「回答變好」。
