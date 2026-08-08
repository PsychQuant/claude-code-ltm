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

沒有 API key，沒有雲端 embedding，沒有對外通道。

## 狀態

構思與設計中。量測基線見 [`docs/measurements/`](docs/measurements/)，設計文件見
[`docs/superpowers/specs/`](docs/superpowers/specs/)。

## Related

- `PsychQuant/rush` — 自成 marketplace 的 Swift plugin 範本（binary + plugin shell + catalog）
- `Akashic-Library` — canonical store 與衍生 index 分離的先例
- `PsychQuant/ai4o` — 既有的記憶系統實作（episodic/semantic、strength、consolidation），
  本專案的策略設計大量參考其 `docs/memory/`
