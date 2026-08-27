---
name: ltm-setup
description: Use when claude-code-ltm is not yet usable — the user just installed the plugin, a `ltm_query` call came back with `索引不存在` / `indexMissing`, the user asks "how do I set this up", "為什麼查不到", "ltm 要怎麼開始用", "要先做什麼嗎", or wants to rebuild the index after an upgrade. Checks binary and index state, explains the one-time cost, and runs `ltm build` with the user's consent.
---

# 讓 claude-code-ltm 可用

**分清楚兩件事**，因為它們的成本差三個數量級：

| | 誰做 | 成本 |
|---|---|---|
| 下載 `ltm` binary | **自動**（wrapper 在 MCP server 第一次啟動時做）| 幾秒，3 MB |
| 建索引 `ltm build` | **要人同意才跑** | **首次數十分鐘**，之後自動增量 |

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

**不要在沒說清楚的情況下啟動它。** 依語料規模，首次全量建索引可以是**數小時**等級
的工作——本機實測 **2 小時 6 分**（9,958 檔／5.67 GB → 640,760 chunk，
`docs/measurements/2026-08-27-query-latency-decomposition.md` 的索引欄）——它要掃過 `~/.claude/projects` 底下每一個 `.jsonl`、切 chunk、逐段算
on-device embedding。量測基線見 repo 的
`docs/measurements/2026-08-08-baseline.md`。

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
`tail` 它就有真的進度可以回報——不要從外面用 `ps` 或檔案大小去猜。**四**種行
（先前這裡寫「三種」而實際有四種——一份宣稱自己完整的列舉，#44 R2 verify，
devil's advocate）：

| 何時 | 長相 |
|---|---|
| 掃描一結束（嵌入還沒開始）| `掃描完成：N 個來源檔，M 個新 chunk，其中 K 個要算向量` |
| 分批定案後（仍在嵌入之前）| `分批：47 批，最大一批 4322 chunk，向量累積上界 17.7 MB` |
| 嵌入期間，每 200 個 chunk 或每 5 秒 | `… 嵌入 6000/94000 chunk（已用 8 分 12 秒）` |
| 每批提交後 | `✓ 第 3/47 批已提交，chunk 6000/94000（已用 8 分 12 秒）` |

**第一行在嵌入開始之前就會出現**，所以分母不必等第一批做完。零新增的增量也會
印掃描那一行——「掃完了沒有新東西」與「還在掃」是兩件事。

### ⚠️ 掃描階段仍然是沉默的

上表的「掃描完成」是掃描**結束**時印的。在它之前，掃描本身沒有任何逐步進度——
本機實測那段沉默是 **310 秒**（`ltm build --full`，9,958 檔）。使用者在那五分鐘裡
看到的與「卡死」一模一樣。

**這是已知缺口，追蹤於 #48，仍然 OPEN。** 引導使用者跑首次 build 時要先說這件事，
不要讓他以為沒有輸出就是壞了。

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
