# claude-LTM

Claude Code 的長期記憶（long-term memory）。

**核心命題**：`~/.claude/projects/**/*.jsonl` 已經是一份完整、immutable、帶時間戳的
對話逐字記錄——那就是 source of truth，而且它一直都在。缺的不是儲存，是**檢索**。
claude-LTM 在它之上建可拋棄的索引與可插拔的記憶策略，讓 Claude 能回頭讀自己的過去。

## 這個 repo 不只是一個記憶系統

它是**多個記憶系統的討論場與實作場**。人類記憶不是唯一的設計答案，檔案櫃也不是。
不同策略在同一份語料、同一組查詢上跑，可以比較——這是本專案刻意保留的軸。

現有的策略構想見 [`docs/memory-systems/`](docs/memory-systems/)。

## 三條不變式

任何實作、任何策略都不得違反：

1. **`~/.claude/projects/` 唯讀。** 我們不擁有 source of truth。任何寫入路徑都是 bug。
2. **索引是純衍生物。** `rm -rf ~/.claude-ltm/derived && ltm build` 必須得到等價結果。
   任何只活在索引裡的東西都違規。
3. **回傳一律附指標。** 每個命中帶 `(project, sessionId, uuid, timestamp)`，可回原 jsonl
   讀完整上下文。**檢索只負責導航，不負責當答案。**

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
    └── ltm.sqlite        retrieval history · strength · links · pins
```

`memory/` 存的是「jsonl 記不得的事」——使用歷史。它不是衍生物，所以不適用第 2 條，
但受一條獨立的硬約束：

> **`memory/ltm.sqlite` 只存指標與統計，不存 chunk 原文。**

如此即使它被備份或同步，裡面也沒有任何第三方逐字內容——隱私邊界靠 schema 保證，
不靠自律。

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

`~/.claude-ltm/memory/` 是另一回事：它只存指標與統計，所以**即使被備份或同步**也
不含第三方逐字內容（見上一節）。那條保證與這一節無關，不要混為一談。

## 狀態

**檢索路徑可以跑了**：`ltm build` 掃語料建索引，`ltm query` 查它。策略層、記憶層與
比較層（LTMQuery／LTMMemory／LTMEval）在此之前就已存在，這一步補上的是它們的
輸入端——語料掃描、chunk 切分、FTS5 與向量兩路檢索，以及把它們接起來的 facade。

尚未實作：MCP server 與 plugin（追蹤於 issue #24 的 Stage 2）。

```bash
swift build                      # 產出 .build/debug/ltm
ltm build                        # 掃語料、建索引（預設增量，--full 從零重建）
ltm query "要找的內容" --json     # 查詢；預設只搜當前 project
```

`ltm query` 的行為有幾點是刻意的，不是暫時的：

- **預設只搜當前 project**。工作目錄對應不到語料裡的 project 時，它會要求你用
  `--project` 或 `--all-projects` 明示，而不是安靜地擴大到整份語料。
- **預設不寫使用歷史**。`--record` 才會寫 `shown` 事件——開發與檢查用的查詢會污染
  策略比較所依據的資料。
- **索引過期時拒答而不降級**。embedding revision 與索引不同代時，跨代的向量距離
  沒有意義卻不會報錯，所以它直接拒絕並要你跑 `ltm build --full`。
- **查詢前會把語料的新內容併進索引**（前綴雜湊對得上就只讀尾巴）。

量測基線見 [`docs/measurements/`](docs/measurements/)，設計文件見
[`docs/superpowers/specs/`](docs/superpowers/specs/)。**本節不含任何效能宣稱**——
速度、recall 之類的數字一律以 `docs/measurements/` 底下的紀錄為準，而那些紀錄
涵蓋的是它們自己寫明的比較，不是這條剛落地的路徑。

## Related

- `PsychQuant/rush` — 自成 marketplace 的 Swift plugin 範本（binary + plugin shell + catalog）
- `Akashic-Library` — canonical store 與衍生 index 分離的先例
- `PsychQuant/ai4o` — 既有的記憶系統實作（episodic/semantic、strength、consolidation），
  本專案的策略設計大量參考其 `docs/memory/`
