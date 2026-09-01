# no-op build 的成本歸因與 #58 的兩個修法（#58）

**日期**：2026-09-01（傍晚；同日稍早的 `2026-09-01-scan-parallelism.md` 之後，
語料已再成長——當日數字之間**不可直接互比**，見誠實邊界）。**機器**：M5 Max、
128 GB。**DB**：1.9 GB（index.sqlite3）。

## 歸因（sample，1ms 間隔，no-op build）

兩次獨立取樣一致：

| 取樣 | 主執行緒樣本 | 落在 `IndexDatabase.sourcesWithoutCursor()` |
|---|---|---|
| sample1 | 1,152 | 931（81%） |
| sample2 | 1,188 | 1,188（~100%；掃描落在視窗外） |

熱路徑：`sqlite3BtreeIndexMoveto → readDbPage → pread`——逐列 b-tree 探查。
worker 執行緒（#56 的並行掃描）全程接近 idle：**#56 之後瓶頸已從雜湊移到這個
每 build 必跑的正確性閘**（#44 R4/R5：「有 chunk 卻沒有游標的來源，空集合才
放行增量」——語意不可弱化）。時間軸自洽：pre-#56 build ≈ 閘 ~0.9s＋循序雜湊
~2.5s；post-#56 ≈ 閘 ~0.9s＋並行掃 ~0.2s。

第三個同類項（sample3 尾段、24 樣本、僅方向性）：`chunkCount()` 的
`SELECT COUNT(*)`——全表 b-tree 走訪。與閘的 Q1 同一性質：**成本隨索引總量
成長、與改動量無關**的每 build 固定項。

## 候選改寫（sqlite3 CLI 對生產 DB 唯讀；OS 快取暖）

| 查詢 | 現行 | 候選 | 結果 |
|---|---|---|---|
| Q2（缺游標來源） | 0.20s | `EXCEPT` | **0.073s**，精確等價（EXCEPT 自帶去重＝DISTINCT＋anti-join）→ **採用** |
| Q1（orphan chunks，`NOT IN`） | 0.21s | `EXCEPT` | 3.08s（排序全掃更糟）→ 棄 |
| Q1 | 同上 | count-diff（`COUNT(chunks) − COUNT(DISTINCT chunk_id)`） | 0.072s 但**不 sound**：等價性假設「chunk_sources 無懸空引用」，而該不變式正屬本函式所稽核的家族——稽核者不得假設待稽核物 → 棄 |

## 實作與 A/B（同一語料時點、cp 還原紀律；語料為活的，噪音大）

改動：Q2 → `EXCEPT`；連線層 `PRAGMA mmap_size=4 GiB`（只影響讀路徑，
durability 語意不動；sample3 證實 `getPageMMap` 生效）。

| | build 暖 ×3 | query ×3 |
|---|---|---|
| A（無改動） | 2.13 / 1.70 / 4.22s | 2.61 / 2.19 / 1.83s |
| B（EXCEPT＋mmap） | 7.38*／1.75 / 1.41s | 1.66 / 1.63 / 1.60s |

\* B 第一輪消化了 A 量測期間累積的新語料，不列入比較。

**方向**：B 的 query 一致快於 A（~0.2–1.0s），build 暖輪亦快。**幅度不下精確
結論**——語料在量測間持續被寫入（本 session 自己的 jsonl），A 的 4.22s 離群值
即為現場 ingest 的痕跡。

## 結論

- Q2→EXCEPT（CLI 3×）與 mmap（A/B 方向為正）**保留**。
- **「1 秒以內」在本輪之後仍未達成**（B 的 query ~1.6s @ 當晚語料）。
- 剩餘結構性事實：每 build 有兩個**隨索引總量成長**的固定項（閘的 Q1
  逐列探查、`chunkCount()` 全表 COUNT）。要根治得改成**維護式記帳**（計數器
  ／增量 orphan 簿記），那會動 #44 閘的設計——是新的設計決定，不在 #58 的
  Simple 範圍內偷渡。

## 誠實邊界

- 全部單機單日、樣本小、**語料活著**——同日不同時點的數字（含與
  `2026-09-01-scan-parallelism.md` 的表）不可互比；只有 A/B 那組是同時點對照。
- sample 掛上有延遲，sample3 只涵蓋 build 尾段（24 樣本，僅方向性引用）。
- 「行程內 ~0.9s vs CLI 暖 0.44s」的機理（SQLite 私有頁快取、syscall 佔比）
  未被解釋——修法不依賴它，欠一個解釋（#58 diagnosis 的 Residue）。
- mmap 的幅度貢獻與 Q2 的貢獻**未分離量測**（一起上的 A/B）。
