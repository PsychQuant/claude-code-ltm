# no-op build 閘：行程內 vs CLI 的 2× 差距在哪（#60）

**日期**：2026-09-07（量測在 2026-09-06T23:53Z 的 #60 Diagnosis 當下，臺北 07:53）。
**機器**：Apple M5 Max、128 GB、macOS 27。**DB**：`~/.claude-ltm/derived/index.sqlite3`，
唯讀開啟，647,408 chunk；**OS 頁快取暖**（之前跑過 CLI）。**結論先講**：差距不在 SQL 執行，
在**同一連線的第一次觸碰**——每個 `ltm` 行程都是新連線、都付一次。

## 為什麼要量

`2026-09-01-noop-build-attribution.md`（#58）把 no-op build 的成本鎖在
`IndexDatabase.sourcesWithoutCursor()`（Q1＋Q2），但同一組查詢在 `sqlite3` CLI（OS 快取暖）
約 0.44 s、在 `ltm` 行程內約 0.9 s——那份紀錄把這個 2× 記在誠實邊界、沒有追（#58 的 residue，
即 #60）。候選（都未量）：SQLite 私有頁快取冷熱、`cache_size` 預設、prepared statement 重編、
syscall 佔比、Swift 端逐列 `columnText` 字串建構。

## 方法（可重跑）

一個暫時的 probe 測試——**跑完即刪、不進 repo**（理由：它唯讀開真索引，而本 repo 的測試
不碰真索引；probe 的內容只剩本段的描述，重建它就是照這四條路徑再寫一次）。在**同一行程內**
對真索引分別計時，每條路徑各跑三次：

- (a) 走 `IndexDatabase` 包裝的 `sourcesWithoutCursor()`（Q1＋Q2）
- (b) 走同一個包裝的 `query()` 跑裸 Q1（同一連線，已被 (a) 暖過）
- (c) 繞過包裝、直接 `sqlite3_open_v2` + `sqlite3_prepare_v2`／`step` 跑 Q1（新連線）
- (d) 同 (c) 但先 `PRAGMA mmap_size=1073741824`（新連線）

對照：`sqlite3 "file:$HOME/.claude-ltm/derived/index.sqlite3?mode=ro"` 對同一句 Q1 用
`/usr/bin/time -p` 連跑三次（每次新行程）。Q1／Q2 的原文在
`Sources/LTMIndex/IndexDatabase.swift` 的 `sourcesWithoutCursor()`。

## 結果

| 路徑 | 第 1 次 | 第 2、3 次 |
|---|---|---|
| (a) in-process `sourcesWithoutCursor()`（Q1＋Q2） | **1.862 s** | 0.151 / 0.162 s |
| (b) in-process `IndexDatabase.query` 裸 Q1（同連線，已暖） | 0.118 s | 0.117 s |
| (c) in-process 裸 C API Q1（新連線） | 0.141 s | 0.143 s |
| (d) in-process 裸 C API + mmap Q1（新連線） | 0.127 s | 0.120 s |
| `sqlite3` CLI Q1（每次新行程） | 0.60 s | 0.16 / 0.17 s |
| `chunkCount()` | 0.007 s | 0.006 s |

## 判讀

1. **SQL 本身沒有行程內 vs CLI 的差距。** 暖態下四條 in-process 路徑（0.12–0.16 s）與 CLI
   （0.16 s）同級；`IndexDatabase` 的包裝（prepare + step 迴圈）與裸 C API 量不出差別。
   所以候選裡的「Swift 端逐列 `columnText` 字串建構」與「prepared statement 重編」可以排除：
   COUNT 只回一列，且包裝與裸 API 同速。
2. **差距全在第一次呼叫。** 同一連線第一次跑 Q1＋Q2 要 1.86 s、第二次 0.15 s（12×）。這是
   SQLite **每連線私有頁快取從零暖起**的成本：Q1 要探 `sqlite_autoindex_chunk_sources_1` 的
   b-tree 全部葉頁、Q2 走 `chunk_sources_by_source`，第一次全部要從 OS 頁快取拉進私有快取
   （mmap 省掉一次拷貝，仍要 page-fault 映射）。CLI 的「0.44 s 暖」是**重複跑同一支 CLI**
   得到的——每次新行程也各自付這筆，0.60 → 0.16 的形狀與 in-process 完全一樣，只是 CLI
   每次只跑一句。
3. **所以 #58 記的「行程內 ~0.9 s vs CLI 暖 0.44 s」是拿一個冷連線去比一個被反覆跑到暖的
   CLI。** `ltm query` 每次都是新行程＝新連線，永遠是第一次觸碰。同條件下兩者一致；差距的
   主成分不是任何可改的連線設定——`cache_size` 調大只會讓**第二次**更快，而 `ltm query`
   沒有第二次。`chunkCount()` 7 ms，與 #61 診斷的更正一致。

## 與 #61 的關係

既然固定項是「第一次觸碰 N 個 b-tree 葉頁」，任何仍要掃 N 的做法（換 SQL 寫法、調
`cache_size`）都救不了；只有**不掃 N**（#61 的結構性計數＋partial index）才會消掉它。
#60 到此可以關：缺口被解釋、修法在 #61。

## 誠實邊界

- 單機、單日、每條路徑三次，無分佈統計。語料活著，數字只在同一時點內可比；**不要拿本表與
  `2026-09-01-noop-build-attribution.md` 的表互比**（不同日、不同語料大小；那份是 sample 歸因
  與 A/B，本份是同行程對照）。
- 只量了**暖 OS 頁快取**。冷 OS 快取下第一次會更慢，但那對兩條路徑一視同仁，不改變「差距
  來自連線冷熱」的結論。
- **沒有量 `PRAGMA cache_size` 調大的效果**——理由是 `ltm query` 沒有第二次呼叫可受益；
  若 MCP 常駐行程日後重用連線（#65 的方向之一），這個旋鈕才有意義，屆時再量。
- probe 未進 repo，數字無法從 repo 內重跑；能重跑的是方法段的 CLI 對照那一列與
  `chunkCount()`。判讀 2 的機理（私有頁快取）是對「第一次 12×、第二次同級」這個形狀的解釋，
  不是直接量到快取命中率——沒有 `PRAGMA cache_stats` 類的計數支撐。
