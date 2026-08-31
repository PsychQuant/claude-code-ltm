---
name: ltm-setup
description: Use when claude-code-ltm is not yet usable — the user just installed the plugin, a `ltm_query` call came back with `索引不存在` / `indexMissing`, the user asks "how do I set this up", "為什麼查不到", "ltm 要怎麼開始用", "要先做什麼嗎", or wants to rebuild the index after an upgrade. Checks binary and index state, explains the one-time cost, and runs `ltm build` with the user's consent.
---

# 讓 claude-code-ltm 可用

**分清楚兩件事**，因為它們的成本差三個數量級：

| | 誰做 | 成本 |
|---|---|---|
| 下載 `ltm` binary | **自動**（wrapper 在 MCP server 第一次啟動時做）| 幾秒，3 MB |
| 建索引 `ltm build` | **要人同意才跑** | 首次的耗時見下方成本說明；之後自動增量 |

所以「plugin 裝好了卻查不到東西」幾乎一定是第二件事沒做。

## 先診斷，不要直接跑 build

```bash
command -v ltm || ls ~/bin/ltm          # ① binary 在嗎
ltm query "test" 2>&1 | head -5         # ② 索引在嗎（錯誤訊息會直說）
```

| 症狀 | 意思 | 做什麼 |
|---|---|---|
| `ltm` 找不到 | wrapper 還沒跑過，或下載失敗 | 見下方〈binary 沒下載成功〉 |
| `索引不存在（…）` | 只差建索引 | 往下走 |
| `embedding revision 不同代` / `結構版本不符` / `定址規則不同` | 索引是舊的 | `ltm build --full`，成本同首次 |
| 有結果 | 已經可用 | 不用做任何事 |

## 建索引之前先告訴使用者代價

**不要在沒說清楚的情況下啟動它。** 首次全量建索引的耗時**本 repo 沒有量過**，
而它足以讓使用者以為程式壞掉——所以要先講，並讓他自己估。

> **這裡刻意不給任何數字。** 前後改過三次，三次都被驗證推翻：先是「數十分鐘」
> （被實測推翻），再是「實測 2 小時 6 分」（引用的紀錄不含它），再是「觀察到約
> 兩小時」（改引的紀錄同樣不含它，而且那份紀錄自己寫明不支持任何耗時預測）。
>
> 本 repo 的誠實邊界要求宣稱要有一份**涵蓋它**的可指名紀錄，而建置耗時目前沒有
> 那樣一份。**與其再猜一個，不如讓使用者自己量**——下面第 1 點就是那個做法。

先讓使用者知道這三件事，再問要不要現在跑：

1. **要跑多久**取決於他的語料大小——先報數字，別讓他自己猜：
   ```bash
   find ~/.claude/projects -name '*.jsonl' | wc -l
   du -sh ~/.claude/projects
   ```
2. **全程在本機**，不連外。
3. **只有第一次要等**：之後每次查詢會自動併入新內容（`refreshIncrementally`），
   不必再手動跑。

## 跑

```bash
ltm build
```

跑得久，**放背景**，不要讓它把整個 session 卡住：

```bash
ltm build 2> ~/.claude-ltm/build.log &
```

`ltm build` 把進度寫 **stderr**（stdout 留給最終報告），所以導到檔案再定期
`tail` 它就有真的進度可以回報——不要從外面用 `ps` 或檔案大小去猜。行的種類
**以下表為準，數字刻意不寫**——這個數字已經錯過兩次（先寫「三種」而實際四種，
#44 R2 verify；#48 加了掃描心跳後「四種」又過期）。一個被複述的數字就是一份會
漂移的規格；表與 enum 的對應由 `ProgressDocSyncTests` 看守，散文不再複述它：

| 何時 | `BuildProgress` case | 長相 |
|---|---|---|
| 一開工（分母已知）與掃描心跳 | `scanning` | `正在掃描 N 個來源檔…`，之後 `… 掃描 k/N 檔（已用 X）`（#48：首次全量的掃描階段先前整段靜默）|
| 掃描一結束（嵌入還沒開始）| `scanCompleted` | `掃描完成：N 個來源檔，M 個新 chunk，其中 K 個要算向量` |
| 分批定案後（仍在嵌入之前）| `batchPlan` | `分批：N 批，最大一批 M chunk，向量累積上界 X MB` |
| 嵌入期間，每 200 個 chunk 或每 5 秒 | `embedding` | `… 嵌入 6000/94000 chunk（已用 8 分 12 秒）` |
| 每批提交後 | `batchCommitted` | `✓ 第 3/47 批已提交，chunk 6000/94000（已用 8 分 12 秒）` |

> 中間那一欄不是給讀者看的，是給檢查看的：`ProgressDocSyncTests` 比對這一欄與
> `BuildProgress` 的 case **名字集合**。只比列數的版本擋不住「換掉一列」——
> 列數與 case 數可以同時對而內容錯位，使用者看到的「完整清單」仍漏一種
> （#44 R3 verify，三個 lens）。

**第一行在嵌入開始之前就會出現**，所以分母不必等第一批做完。零新增的增量也會
印掃描那一行——「掃完了沒有新東西」與「還在掃」是兩件事。

### ⚠️ 從 v0.2.0 升上來的人會被要求跑一次 `--full`

舊索引的續讀游標存在一個獨立的 `state.json` 裡，而那個檔已經不再被讀——**遷移
路徑刻意刪掉了**：游標涵蓋的內容是否真的在索引裡，這個事實不在磁碟上，猜錯的
後果是那段語料永遠不再被解析而 `build` 印 ✓（已實測）。

所以 v0.2.0 的使用者第一次跑 `ltm build` 會看到一則具名錯誤，要求 `ltm build --full`。
**那是一次完整重建，耗時同上（未量過）。** 引導他升級時要先說這件事——這是刪掉遷移的已知代價，
不是 bug。

### 掃描階段的心跳（#48 已修）

掃描期間現在有進度：一開工印「正在掃描 N 個來源檔…」，之後每 500 檔或每 5 秒
（**檔案邊界上**先到者發）印「… 掃描 k/N 檔」。首次全量先前整段靜默
（一次觀察到 **310 秒**，9,935 檔／5.7 GB，
`docs/measurements/2026-08-28-scan-phase-silence.md`——那是一次觀察、不是受控
量測），與「卡死」外觀相同；現在使用者會看到心跳。

**殘餘限度**：時間側只在檔案邊界檢查——單一超大檔案處理期間仍然沒有輸出。
引導使用者時若心跳停在某個 k/N 很久，先想「正在啃一個大檔」，不要直接判卡死。

（這一段先前寫「已知缺口，追蹤於 #48，**仍然 OPEN**」——同一個 commit 在上表加了
`scanning` 列、卻把 24 行外的這段原樣留著，一個 agent 會照著它警告一個已不存在的
症狀，然後解釋不了使用者看到的「正在掃描…」。batch verify，兩個 lens。）

`--quiet` 可關掉全部進度（CI／腳本用），最終報告不受影響。

完成後驗證：

```bash
ltm query "任意你記得談過的關鍵字" | head -5
```

有命中就結束。**沒有命中不代表失敗**——可能只是那個詞不在語料裡，換一個更確定
談過的詞再試一次，再判斷。

## 沒有登入鑰匙圈的環境（SSH／launchd／CI）

`ltm` 用 macOS Keychain 存 anchor 密鑰。**沒有登入鑰匙圈的環境**——SSH 進來、
launchd／cron、CI、或以另一個 `HOME` 執行——它會直接拒絕並說出補救方式：

```
✗ 這個環境沒有可用的登入鑰匙圈（找過 …/Library/Keychains）。
```

補救是**給它另一個密鑰來源**，不是關掉加密鑰：

```bash
# ① 在有鑰匙圈的 session（本機圖形登入的終端機）匯出
ltm memory --export-key

# ② 在沒有鑰匙圈的環境餵進去
export LTM_ANCHOR_KEY=<上一步的 64 個十六進位字元>
```

**`LTM_ANCHOR_KEY` 不是 opt-out。**「要不要加密鑰」沒有選項；「密鑰從哪來」有兩個
（Keychain 與這個變數）。給壞值一樣會拒絕，不會退回未加密鑰。

**密鑰不對等於全體 orphan**：anchor 是用密鑰算的，換一把就對不上既有記憶。所以是
匯出既有的那把，不是隨便產一把新的。

> **為什麼不乾脆讓它在沒有鑰匙圈時自己產一把**：那把新密鑰會讓這台機器上既有的
> 記憶全部解析不到，而症狀是「turn 不見了」而不是「密鑰不對」——兩者看起來一樣。

## binary 沒下載成功

wrapper 會把它裝到 `~/bin/ltm`。手動補：

```bash
curl -fL https://github.com/PsychQuant/claude-code-ltm/releases/latest/download/ltm -o ~/bin/ltm
chmod +x ~/bin/ltm
```

它是 Developer ID 簽章 + notarized 的，Gatekeeper 會直接放行。若 `~/bin` 不在 PATH，
用完整路徑 `~/bin/ltm` 即可，不必為此改 shell 設定。

## 不要做的事

- **不要自作主張跑 `ltm build --full`**：那會丟掉現有索引重來。只有在錯誤訊息
  明講需要重建時才用。
- **不要碰 `~/.claude/projects`**：那是唯讀語料，是 source of truth。
- **不要為了「讓它快一點」去縮語料範圍**：索引是純衍生物，刪掉重建永遠安全，
  但砍語料不可逆。
