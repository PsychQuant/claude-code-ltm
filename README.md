# claude-LTM

Claude Code 的長期記憶（long-term memory）。

**核心命題**：`~/.claude/projects/**/*.jsonl` 已經是一份完整、immutable、帶時間戳的
對話逐字記錄——那就是 source of truth，而且它一直都在。缺的不是儲存，是**檢索**。
claude-LTM 在它之上建可拋棄的索引與可插拔的記憶策略，讓 Claude 能回頭讀自己的過去。

## 版本

| 版本 | 內容 |
|---|---|
| v0.1.0 | 首次發布。檢索路徑、記憶層、策略層、MCP server（`ltm mcp`）、plugin shell。Developer ID 簽章 + notarized。|

改版本號**只改 `Sources/LTMCore/Version.swift`**——其餘三處由 `ReleaseVersionSyncTests`
看守，見〈安裝〉最後一段。

## 安裝

> **這一節是寫給 agent 看的**：每一步都是可以直接執行的命令，每一步都附一條驗證。
> 不要憑印象跳步，也不要在這裡自己發明別的裝法——`ltm` 是單一 binary，MCP server
> 是它的 `mcp` 子命令，其餘寫法都是舊的。

### 給使用者（從 release 裝）

**plugin 尚未上架 marketplace**，所以現在是手動三步。這三行實跑驗證過：

```bash
# 1. 拿 binary。Developer ID 簽章 + notarized，Gatekeeper 直接放行
curl -fL https://github.com/PsychQuant/claude-LTM/releases/download/v0.1.0/ltm -o ~/bin/ltm
chmod +x ~/bin/ltm

# 2. 建索引。**這一步不能省**——沒有索引時 MCP server 會啟動、會回應、但查不到
#    任何東西，而那看起來像「這個工具沒用」而不是「還沒建索引」。
~/bin/ltm build

# 3. 接上 Claude Code
claude mcp add --scope user --transport stdio claude-ltm -- ~/bin/ltm mcp
```

要核對下載完整性（擋的是截斷，不是竄改——雜湊與 binary 走同一條 TLS）：

```bash
curl -fsL https://github.com/PsychQuant/claude-LTM/releases/download/v0.1.0/ltm.sha256
shasum -a 256 ~/bin/ltm
```

**或用 plugin**（這個 repo 自成 marketplace——binary 原始碼、plugin shell、
marketplace catalog 都在這裡）。`ltm` 由 wrapper 在第一次啟動 MCP server 時自動從
GitHub Release 下載到 `~/bin/`：

```bash
claude plugin marketplace add PsychQuant/claude-LTM
claude plugin install claude-ltm@claude-ltm
ltm build                              # 仍然要建一次索引
```

Claude Desktop 走 release 頁的 `claude-ltm-0.1.0.mcpb`，雙擊安裝；裝完仍要跑一次
`ltm build`。

### 從原始碼裝（開發、或不想等 release）

```bash
git clone https://github.com/PsychQuant/claude-LTM.git
cd claude-LTM
swift build -c release                # 產出 .build/release/ltm
./.build/release/ltm build            # 建索引
```

MCP server 用同一個 binary：

```bash
./.build/release/ltm mcp              # 由 client 啟動，手動跑只會停在那裡等 stdin
```

要讓 Claude Code 在**這個 repo 裡**就用得到它，repo 根目錄的 `.mcp.json` 已經指好；
要在別的專案用，裝 plugin（上一節）或把 `plugin/` 傳給 `claude --plugin-dir`：

```bash
claude --plugin-dir /path/to/claude-LTM/plugin
```

### 驗證裝好了（三層，各自獨立）

```bash
# ① binary 在，而且版本對得上
ltm --help
# ② 索引在
ltm query "test" >/dev/null && echo "索引可查"
# ③ MCP 協定真的會回話（不需要索引也該通）
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | ltm mcp
#    → 應印出含 "ltm_query" 的 JSON
```

三層分開驗是刻意的：**它們的失敗看起來一樣**（模型說「查不到東西」），但補救
完全不同——分別是重裝 binary、跑 `ltm build`、檢查 plugin 設定。

### 出貨流程（maintainer）

單一 binary、單一 asset，走生態既有的 pipeline，**不要在這個 repo 另寫一份**：

```
/harness-devtools:mcp-deploy      # 在本 repo 跑：編譯 universal → GitHub Release 上傳 asset
/harness-devtools:plugin-deploy   # 首次上架到 marketplace
/harness-devtools:plugin-update   # 之後每次改 plugin shell
```

改版本號**只改 `Sources/LTMCore/Version.swift`**，然後 `swift test`——
`ReleaseVersionSyncTests` 會指名 `mcpb/manifest.json`、`plugin.json`、wrapper 的
`DESIRED_VERSION` 哪一處沒跟上。三者不同步的失敗方式是**四步都「成功」而版本各不
相同**，所以那條檢查不是禮貌。

## 名字裡的類比

叫它 LTM 不只是取名。要達成的是**類似人類長期記憶的功能**：過去的對話不是躺在磁碟
上的檔案，而是**能在需要時被想起來**的東西。

「想起來」有它自己的性質，而那些性質是可以拿來當設計判準的——內容定址而非位置定址、
相關度主導提取而使用強度只做微調、多重編碼提高可提取性、同一段經歷不因被重述而變成
兩段記憶。判準的完整版與它們各自導出的決定在
[`.claude/rules/ltm-analogy.md`](.claude/rules/ltm-analogy.md)。

類比也有**邊界**：人類記憶是重構性的（回憶時用當下的知識填補空缺，而填補出來的東西
感覺跟真的一樣）。那一條**刻意不模仿**——這個系統可以讓一段記憶沉下去，但不能把它
改寫成別的內容。不變式 3 就是從這裡來的。

## 這個 repo 不只是一個記憶系統

它是**多個記憶系統的討論場與實作場**。人類記憶不是唯一的設計答案，檔案櫃也不是。
不同策略在同一份語料、同一組查詢上跑，可以比較——這是本專案刻意保留的軸。

所以上面那個類比限定的是**功能目標**（讓 Claude 能調閱過去），不是達成機制：
`human-like` 策略模仿人類記憶的動力學，`archival` 策略刻意不模仿。哪個好是待量測的
問題，不是先驗的。

現有的策略構想見 [`docs/memory-systems/`](docs/memory-systems/)。

## 三條不變式

任何實作、任何策略都不得違反：

1. **`~/.claude/projects/` 唯讀。** 我們不擁有 source of truth。任何寫入路徑都是 bug。
2. **索引是純衍生物。** `rm -rf ~/.claude-ltm/derived && ltm build` 必須得到等價結果。
   任何只活在索引裡的東西都違規。
3. **回傳一律附指標。** 每個命中帶 `(project, sessions, uuid, timestamp)`，可回原 jsonl
   讀完整上下文。**檢索只負責導航，不負責當答案。** `sessions` 是**集合**——持有
   這則 turn 的每一個來源檔各一個 session id，沒有哪一個是「代表」（#25）。

第 3 條的推論：LLM 提取（若有）只能用於 **routing**，不能用於 **answering**。同樣是提取，
用來決定「該讀哪一段」是安全的，用來產生「答案是什麼」是危險的。

## 儲存分家

```
~/.claude-ltm/
├── derived/          純衍生 · 可隨時刪掉重建
│   ├── index.sqlite      FTS5 + turns + chunks
│   ├── vectors.bin       512-d float32, mmap
│   └── state.json        ingest 進度（size / mtime / processedBytes / prefixHash）
└── memory/           canonical · 要備份
    ├── events.jsonl        使用歷史（append-only，一行一筆）
    └── presentations.jsonl 交錯比較的呈現紀錄（同上）
```

`memory/` 存的是「jsonl 記不得的事」——使用歷史。它不是衍生物，所以不適用第 2 條，
但受一條獨立的硬約束：

> **只存指標、統計、與封閉集合的類別標籤；不存 chunk 原文、query 原文、note 原文。**

如此即使它被備份或同步，裡面也不含第三方逐字內容。

**這條由機制保證到什麼程度，要說清楚——它不是「schema 擋掉一切」。** 判準有兩層，
而且標的是**落地的 bytes**，不是 decode 之後的值：canonical 檔的每一行，解碼後重新
編碼必須與原始 bytes 逐字相同，否則當作損壞；另有型別層的形狀約束當防禦縱深。

**它擋掉的是「不小心把原文塞進去」，擋不掉刻意用 ASCII 編碼原文的人**；bytes 層也
擋不掉一個合法值本身就是自然語言（例如一個很長的英文句子當識別碼）。

> 完整判準與它四次被收窄的過程在 [`CLAUDE.md`](CLAUDE.md) 的「例外：記憶層不是衍生物」
> 一節。**那一節刻意不列舉欄位**——那份清單前後漏了四次，而判準不會。本節是它的摘要，
> 兩者衝突時以 `CLAUDE.md` 為準。

## 全本機

| 能力 | 用什麼 | 對外連線 |
|---|---|---|
| 語意向量 | `NLContextualEmbedding`（繁/簡中、拉丁，dim=512，模型隨系統內建） | 無 |
| 字面檢索 | SQLite FTS5（BM25） | 無 |
| 選用的主題標記 | `FoundationModels`（on-device LLM，macOS 26+） | 無 |

沒有 API key，沒有雲端 embedding。**索引與檢索本身不對外連線。**

**但「零對外通道」是過度宣稱，這裡修正。**（#1 的 adversarial review，2026-08-09）
索引在本機，不等於資料不外傳：這個工具的用途就是把檢索到的**原文**送進當前的
Claude context，而那段原文之後往哪裡去，取決於當下的模型與客戶端路徑——不是這個
repo 能保證的事。

所以準確的說法是兩句，不是一句：

- **本專案自己不建立對外連線**（embedding、檢索、選用的主題標記全在裝置上）。
- **本專案的輸出會進入呼叫端的 context，而那條路徑不在本專案的控制範圍內。**
  用它檢索含第三方逐字內容的語料時，這一點必須自己判斷。

`~/.claude-ltm/memory/` 是另一回事：它只存指標、統計與封閉集合的類別標籤，所以
**即使被備份或同步**也不含第三方逐字內容——在上一節寫明的限度內（它擋的是「不小心
塞進去」，不是刻意編碼）。那條保證與這一節無關，不要混為一談。

## 狀態

**檢索路徑可以跑了**：`ltm build` 掃語料建索引，`ltm query` 查它。策略層、記憶層與
比較層（LTMQuery／LTMMemory／LTMEval）在此之前就已存在，這一步補上的是它們的
輸入端——語料掃描、chunk 切分、FTS5 與向量兩路檢索，以及把它們接起來的 facade。

**MCP server 與 plugin 也在了**（#24／#35，已 close）：MCP server 是 `ltm mcp`
子命令，plugin shell 在 `plugin/`。安裝與出貨見上面的〈安裝〉。

```bash
swift build                      # 產出 .build/debug/ltm
ltm build                        # 掃語料、建索引（預設增量，--full 從零重建）
ltm query "要找的內容" --json     # 查詢；預設只搜當前 project
ltm memory                       # 檢查記憶層，列出讀不回來的紀錄（唯讀）
ltm memory --prune               # 丟掉那些紀錄，先備份原檔
ltm memory --prune --force       # 連「一筆都不剩」也照做（換代後常是這個情況）
```

`ltm memory` 存在的理由很窄：記憶層是這裡**唯一不可重建**的資料，而它有兩類讀不
回來的紀錄——解不開的（半途中斷的 append），以及用已被取代的 anchor 定址規則寫的。
兩者都會讓整份歷史拒絕讀取，那是對的（安靜地少讀幾筆比讀不出來更糟），但沒有出路
的拒絕實際等同「歷史從此鎖死」。修剪是唯一會從 canonical 儲存移除資料的路徑，所以
它只刪讀不回來的那些、呼叫端無法指定刪哪一筆、而且動手前一定先備份。

**`ltm memory` 只涵蓋 `events.jsonl`，不涵蓋 `presentations.jsonl`，而那是刻意的。**
呈現紀錄有對等的**修復讀取**（讀得回來的部分救出來、跳過的行號報出來），但**沒有
prune**——理由見下一段：`--prune` 在它主要的觸發情境裡等於清空整份歷史，再開一個
同形狀的破壞性表面是複製一個已知危險。可復原性不需要用刪除達成（#36 的決定 D2）。

**「一筆都不剩」要明示。** anchor 定址規則換代之後，換代前寫的每一筆都是舊規則，
所以「全部讀不回來」是換代情境的**預設情況**而不是邊角——此時 `--prune` 會拒絕並
要求 `--force`。少了這道閘，使用者照著錯誤訊息的指示走一次就會把整份歷史清空，
而那個訊息說的是「丟掉讀不回來的那些」，不是「清空歷史」。

`ltm query` 的行為有幾點是刻意的，不是暫時的：

- **預設只搜當前 project**。工作目錄對應不到語料裡的 project 時，它會要求你用
  `--project` 或 `--all-projects` 明示，而不是安靜地擴大到整份語料。
- **預設不寫使用歷史**。`--record` **或 `--compare`** 才會寫 `shown` 事件——開發與
  檢查用的查詢會污染策略比較所依據的資料。**讀歷史不需要 `--record`**：
  `--strategy human-like` 會讀既有歷史來排序，但不寫入任何東西。

  （`--compare` 是後來加的，而這一句原本只寫 `--record`。同一個形狀的過期句子當時
  也留在 `ltm-cli` spec 裡，#33 的 verify 抓到——一份說「除非 `--record` 否則不寫」
  的規格，對出貨行為為假。兩處已一起更正。）
- **`--compare` 用兩個策略排同一份候選再交錯呈現**，並落地逐位置歸屬供事後計分。
  它隱含 `--record`、與 `--strategy` 互斥，而且**輸出不透露哪個位置來自哪一邊**——
  知道了就會影響接下來點哪一筆，而那個點擊正是要拿來計分的東西。
  **誠實邊界**：機制存在不等於有資料。目前系統裡沒有任何介面寫得出 deliberate 事件
  （`opened`／`cited`／`pinned`／`dismissed`），而只有它們會推動淨強度，所以每一次
  比較都是 null comparison、計分整批略過。缺的不是時間，是那個產生端（#35）。
- **索引不足以產生與全量重建等價的結果時，拒答而不降級**，並指名 `ltm build --full`。
  判準是那一句，不是一份清單：目前落在它底下的有 layout 版本、embedding revision、
  anchor 定址規則三者不同代，向量側車檔與索引宣稱的筆數對不上，側車檔比宣稱的短，
  以及續讀狀態讀不到。
  共同的理由是這些失敗**看起來都很正常**——跨代的向量距離不會報錯，少一路通道的
  結果也不會，補零的側車連筆數核對都會通過，使用者只會覺得「這東西找不到東西」。

  （這裡先前寫的是「三種情況」。那是封閉列舉，而它**當時就已經漏了一種**（layout
  版本），之後又加了兩條拒答路徑沒有跟上——列舉會漏，判準不會。）
- **結果按相關度分層回傳，不是按融合分數**。層由「命中幾條檢索通道」決定
  （三條 > 兩條 > 一條），層內才看融合分數。截斷走同一個順序——用一個判準選集、
  另一個判準排序，會讓高層的候選被截掉而低層的照樣回傳。
- **查詢前會把語料的新內容併進索引**（前綴雜湊對得上就只讀尾巴）。這條路徑會寫入，
  所以它跟 `ltm build` 拿同一把單寫者鎖；拿不到就用既有索引回答，不等待也不失敗。
- **同一則對話 turn 只算一段記憶**。session resume 會把舊 turn 複製進新檔案，那仍然
  是同一段記憶——去重之後是一個 chunk，而**指標回傳全部持有它的 session**，不挑
  代表；定址用的是不隨 resume 改變的值。（此處原本寫「指標報最近觀察到的 session」，
  #25 證明那條規則從未生效：resume 不改訊息時間戳，所以「最近」永遠平手，實際由
  檔名字典序決定，且會隨新檔出現而改變。）

量測基線見 [`docs/measurements/`](docs/measurements/)，設計文件見
[`docs/superpowers/specs/`](docs/superpowers/specs/)。**本節不含任何效能宣稱**——
速度、recall 之類的數字一律以 `docs/measurements/` 底下的紀錄為準，而那些紀錄
涵蓋的是它們自己寫明的比較，不是這條剛落地的路徑。

## Related

- `PsychQuant/rush` — 自成 marketplace 的 Swift plugin 範本（binary + plugin shell + catalog）
- `Akashic-Library` — canonical store 與衍生 index 分離的先例
- `PsychQuant/ai4o` — 既有的記憶系統實作（episodic/semantic、strength、consolidation），
  本專案的策略設計大量參考其 `docs/memory/`
