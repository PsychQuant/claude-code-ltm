# docs/measurements/ — 量測紀錄的使用規則

每一份紀錄自己寫明它涵蓋什麼、不涵蓋什麼；引用時**指名出處**（CLAUDE.md 誠實邊界）。
本檔只放跨紀錄共用的規則。

## 基準查詢使用規則（#63）

### 為什麼需要規則

量測用的查詢字串一旦落進 session 逐字稿裡**會被索引的欄位**，下一次量測的前幾名就是「顯示它
的那一刻」。#56 的量測把三個基準查詢寫在一行 Bash 命令列上（`for q in …`），`command=` 是
被索引的欄位之一，於是 2026-09-01T04:32:12Z 那則 turn 進了索引；v0.4.0 用同三個查詢重跑，
三個的第一名全部是那則命令（觀察記在 issue #62 的 Diagnosis comment，**不是**本目錄的紀錄；
本目錄沒有涵蓋那次觀察的檔案）。從那一刻起，這三個查詢量到的是「自己的量測命令有多好找」。

### 什麼會進索引（判準，不是清單）

判準是「這個字串會不會落進 `CorpusScanner.indexableText` 讀的欄位」。今天那些欄位是：

| 逐字稿裡的位置 | 進索引？ | 查法 |
|---|---|---|
| `text` block（使用者輸入、Claude 的散文、compaction 摘要） | **會**，全文 | `Sources/LTMIndex/CorpusScanner.swift` 的 `indexableText`，`case "text"` |
| `tool_use` 的七個 metadata 欄位：`command` / `file_path` / `path` / `pattern` / `query` / `url` / `description`，各取前 200 字元 | **會** | 同檔 `toolMetadataFields`（封閉列舉，隨該常數變動；改它就要回來改這段） |
| `tool_result` 的內容（Bash 的 stdout、`Read` 讀到的檔案） | 今天**不會**，只記 `⟨tool_result ok|error⟩` | 同檔 `case "tool_result"`；`Tests/LTMIndexTests/CorpusScannerTests.swift` 的「tool_result 只記成敗，不記內容」。**這是 #6 追蹤中的決定，可能改變** |
| `tool_use` 的其他欄位（Write 的 `content`、Edit 的 `old_string`／`new_string`） | 今天**不會** | 不在 `toolMetadataFields` 裡（同上，隨常數變動） |
| 頂層 `toolUseResult` | 不會 | `chunk(from:)` 只讀 `message.content` |

所以真正危險的動作是：查詢出現在 **Bash 命令列**（`echo`、`ltm query <q>`、`grep <q>`）、
**`ltm_query` MCP 工具的 `query=`**（`Sources/LTMMCP/RetrievalTool.swift` 的 input 欄位名就是
`query`）、任何工具呼叫的 **`description=`**、`Grep` 的 **`pattern=`**，以及**被貼進或引述進對話**
（那是 `text` block）。`cat`／`Read` 查詢檔的輸出本身今天不進索引——但 Claude 看到之後引述它的
那句散文一定進，而且 #6 隨時可能把 tool payload 收進來——所以規則把邊界劃在 jsonl，不劃在索引。

### 查詢集在哪、怎麼用

- 查詢集：`scripts/baseline-queries.txt`（一行一條、`#` 註解）。它的檔頭寫著同樣的規則——兩處要一起改。
  `.gitattributes` 對它設了 `-diff`：`git diff`／`git show <rev>`／`git log -p` 只印「Binary files differ」，
  要看內容在 session **之外**用 `git diff --text`。`git show <rev>:scripts/baseline-queries.txt` 照樣
  印全文（`-diff` 只管 diff 生成），別在 session 裡跑。
- 量測：`scripts/measure-baseline.sh [k]`——讀檔、逐條跑
  `ltm query --all-projects --k <k> --json -- <查詢>`（旗標以腳本為準；注意 `--all-projects`
  是全語料，與舊紀錄的單一 project 不同），**stdout 只印 `#N <ms> <verdict>`**。
  `#N` 是檔內第 N 條非註解行（去前後空白後，空行與 `#` 開頭不算——腳本與測試用同一個定義）。
  在 repo 根目錄跑；密鑰用命令替換餵進環境
  （`LTM_ANCHOR_KEY="$(~/bin/ltm memory --export-key)" scripts/measure-baseline.sh`），不落地。
- verdict 是**封閉字母表**（`Tests/LTMMCPTests/BaselineQueryFileTests.swift` 釘住，只有這幾個）：
  `clean`／`dirty`／`empty`／`error(<rc>|sig<N>|exec|json|shape|judge)`。任一列是 `error(…)`
  腳本最後以 1 離開（每列照印）。
- `dirty` 的判準（封閉列舉，會漏）：前 k 名任一 chunk 的 snippet **含** `⟨tool `，或含 `ltm query`。
  dirty 不是錯，是「這條查詢的命中品質這一輪不可比」；耗時仍可比。
  **`clean` 不是「乾淨」的證明**：它只說兩種已知殘影都沒出現。查詢原文被貼進對話的那則 turn
  兩種殘影都不含，會被判 `clean`。`empty` 是零命中——查詢已經對不到任何東西，這不是 clean。
- `<ms>` 是 `ltm` 行程 fork→exit 的 monotonic 牆鐘（含 process 啟動、查詢前的增量併入、檢索、
  輸出；不含 judge），單一樣本、無暖身——第 1 列常帶冷啟動。

### 三條規則

1. **查詢字串不得落進會被索引的欄位。** 具體（由上表導出，不是另一份清單）：不在 Bash 命令列
   上帶查詢、不餵給 `ltm_query` MCP 工具、不寫進任何工具的 `description`、不貼進對話、不在回覆
   裡引述——連「第 N 條是『…』」這種半句都不行。`cat`／`Read` 查詢檔也不做（理由見上表最後一段）。
   編輯查詢檔用 Write／Edit 工具（`content`／`old_string`／`new_string` 不在那七個欄位裡）或在
   Claude Code 之外的編輯器。要把 diff 交給 review agent，**給檔案路徑讓它自己 Read**，不要把
   diff 內嵌進 prompt——agent 的 prompt 是它逐字稿裡的 `text` block。
2. **量測輸出只印編號。** 命中內容、snippet、查詢文字一律不印；要看命中內容，在 Claude Code
   **之外**的 shell 跑（那個 shell 的逐字稿不在語料裡）。
3. **每次量測前重驗。** 選定當下乾淨不代表永遠乾淨——跑一次 `measure-baseline.sh`，非 `clean`
   的條目在那一輪的命中品質欄標記為不可比。

### 它擋不住什麼（誠實寫下）

- 人手在 session 裡貼了查詢原文，或 Claude 自己引述了——規則靠人守，沒有機制擋（`-diff`
  屬性只擋 diff 生成這一條路）。
- 語料裡本來就有恰好含該字串的**實質** turn（例如退役查詢裡的「資格考」有一則真的使用者 turn）——
  那不是污染，是正常召回；`dirty` 判準不會標它，讀結果時要分辨。
- 未來新的工具殘影形狀（判準是封閉列舉），以及 #6 若把 tool payload 收進索引——那會**回溯**
  索引過去每一次 Write 查詢檔的 `content`。到時候查詢集要整份換掉。
- **目前的八條尚未在真實索引上驗過前 5 名**（檔頭第 1 條寫明了原因與補驗方式）。在那之前，
  「乾淨」是宣稱不是量測。

### 退役清單（已污染，不得再用）

六條，全部來自同一次量測的命令列（`docs/measurements/2026-09-01-scan-parallelism.md` 的方法段，
before 用前三條、after 用全部六條）：

「tokenizer 討論」「flock inode 鎖」「資格考」「band 相關度」「memory strategy」「並行雜湊」

- 查法：`grep -rln -e 'tokenizer 討論' -e 'flock inode 鎖' -e '資格考' docs/` → 只有那份紀錄與本檔
  （加上測試檔）。**只有那一份紀錄**用過它們；`2026-08-08-baseline.md` 等更早的紀錄沒有記過任何
  查詢字串，不受影響。
- 後三條的污染時間點沒有紀錄可指（該紀錄只寫了 `"${QUERIES[@]}"`，陣列賦值那一行不在紀錄裡）；
  它們是**依同一機制推定**退役，不是實測到第一名被佔——這個不確定性寫在這裡，不預設它們乾淨。
- 那份紀錄的耗時欄位仍可讀；命中品質從 2026-09-01T04:32:12Z（污染 turn 的時間）起不可比。
  同日的 `2026-09-01-noop-build-attribution.md` 量的是 SQL 語句不是文字查詢，不需要註記。

### 與其他 issue 的關係

- #62（self-hit 的檢索層排除）：會讓工具殘影的第一名掉下去，但不會讓已污染的查詢恢復成乾淨基準——
  它的前後量測是本查詢集的第一個消費者。**新腳本的列不要與 2026-09-01 之前的表對齊**：
  語料範圍（`--all-projects`）、binary（`~/bin/ltm`）、輸出格式都不同。
- #6（tool payload 是否索引）：上表「今天不會」的兩列都繫在它身上。
- #33（評估集）：真正的解是 `(查詢, 應命中的 turn)`；本查詢集只是把儀器擦乾淨，說不出代表性。
