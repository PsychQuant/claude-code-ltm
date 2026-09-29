# no-op build 閘：第一次觸碰的成本跟著 OS 頁快取走（#60）

**日期**：2026-09-29（改寫；第一版 2026-09-07 的機理被 #60 verify R1 推翻，見「第一版錯在哪」）。
**機器**：Apple M5 Max、128 GB、macOS 27。**DB**：`~/.claude-ltm/derived/index.sqlite3`，
2,755,592,192 B（168,188 個 16 KiB 的 OS 頁；SQLite `page_size` 4096），785,879 chunk。

**結論先講**：閘（`sourcesWithoutCursor()` 的 Q1＋Q2）的成本由**索引頁在不在 OS 頁快取裡**決定，
跟連線、行程都無關。OS 快取冷（0 頁常駐）時，Q1＋Q2 第一次 2,984 ms、帶 11,338 次 major fault；
暖時約 0.23 s——同一連線的第二次、同一行程的新連線、新行程的第一次都一樣。SQLite 每連線的私有頁快取
在預設大小下**不保留**這個工作集：第一次與第二次的 cache miss 數相同。

## 為什麼要量

`2026-09-01-noop-build-attribution.md`（#58）把 no-op build 的成本鎖在
`IndexDatabase.sourcesWithoutCursor()`，並記了一個沒解釋的差距：「行程內 ~0.9 s vs CLI 暖 0.44 s」
（#58 的 residue，即 #60）。候選：SQLite 私有頁快取冷熱、`cache_size`、prepared statement 重編、
syscall 佔比、Swift 端逐列 `columnText` 字串建構。

## 方法（可重跑）

探針 `scripts/probes/gate-first-touch.c`：以 `SQLITE_OPEN_READONLY` 開索引，把 Q1、Q2 分開跑，每次呼叫印
耗時、`sqlite3_db_status(SQLITE_DBSTATUS_CACHE_HIT／CACHE_MISS)`（每次歸零）、`getrusage` 的
major／minor fault 差、回傳列數；跑前跑後各印一次 `mincore` 量到的 OS 快取常駐頁數。只印數字。
Q1／Q2 與 `sourcesWithoutCursor()` 同字面，由 `Tests/LTMIndexTests/GateProbeSQLSyncTests.swift` 比對。
它不是測試，不在 `swift test` 裡跑。

```bash
cc -O2 -o "${TMPDIR:-/tmp}/gate-first-touch" scripts/probes/gate-first-touch.c -lsqlite3
P="${TMPDIR:-/tmp}/gate-first-touch"; DB="$HOME/.claude-ltm/derived/index.sqlite3"
"$P" "$DB" --residency                                        # 先看 OS 快取是冷是暖
"$P" "$DB" --conns 2 --reps 3 --mmap                          # P1–P4（表 1；--mmap 與 IndexDatabase 相同）
"$P" "$DB" --conns 2 --reps 3                                 # P5（表 2：無 mmap）
"$P" "$DB" --conns 2 --reps 3 --mmap --cache-size -1000000    # P7（表 2：私有快取約 1 GB）
"$P" "$DB" --conns 1 --reps 3 --cache-size -1000000           # P8（表 2：無 mmap、私有快取約 1 GB）
"$P" "$DB" --conns 1 --reps 3 --mmap --reuse-stmt             # P9（表 2：statement 重用）
"$P" "$DB" --conns 1 --reps 3 --mmap                          # P10（表 2：對照）
```

執行順序就是 P1 到 P10，從 14:23:04 起連續跑（P9、P10 在 14:24:12 開始；P6 是 P5 的重複，數字同級，不列）。表 2 每一列
取該次執行第 1 條連線的第 1、2 次。

前提：索引的 `-wal`、`-shm` 都在（唯讀開檔建不出它們，缺檔時開檔失敗；不要因此改成讀寫開檔）。
讀者會更新 `-shm` 的 read-mark，除此之外不寫任何檔。

**冷態無法強制**：清 OS 快取要 `sudo purge`，本紀錄沒有權限。表 1 的冷態是**自然冷**——14:23:04
探針先印出 0 頁常駐（索引最後寫入 14:09:31）才開跑。要重現冷態，只能先 `--residency` 確認是 0 再跑。

## 結果

### 表 1：同一條查詢，OS 冷 vs 暖；同連線、新連線、新行程（`--mmap`）

2026-09-29 14:23:04 起連跑四個行程（P1–P4），每個行程依序開兩條連線、每條呼叫三次。

| 情形 | Q1 ms | Q2 ms | major fault（Q1＋Q2） | minor fault（Q1＋Q2） | cache miss Q1／Q2 |
|---|---|---|---|---|---|
| P1 第 1 條連線第 1 次（**OS 冷，0 頁常駐**） | **2,187.1** | **797.1** | **6,563＋4,775** | 557＋1 | 33,283／18,419 |
| P1 第 1 條連線第 2、3 次 | 173.0／172.6 | 52.6／51.3 | 0 | 0 | 33,323／18,419、33,316／18,419 |
| P1 第 2 條連線（同行程新連線）第 1 次 | 188.0 | 55.8 | 0 | 7,106＋4,775 | 33,283／18,419 |
| P2／P3／P4 第 1 條連線第 1 次（新行程，OS 暖） | 177.4／183.7／174.3 | 53.1／56.7／51.7 | 0 | 約 7,120＋4,776 | 33,283／18,419 |

OS 快取常駐頁：P1 前 0 ／ 168,188，P1 後 46,126。P2–P4 前後都是 46,126。

### 表 2：可調的連線設定（OS 暖，14:23–14:24，單一連線的第 1 次 vs 第 2 次）

| 設定 | Q1 第 1／2 次 ms | Q2 第 1／2 次 ms | 第 2 次的 cache miss Q1／Q2 |
|---|---|---|---|
| P10：mmap、預設 `cache_size`（2000 頁）、每次 prepare | 194.4／177.3 | 53.8／51.2 | 33,323／18,419 |
| P9：mmap、statement 重用（prepare 一次、`sqlite3_reset`） | 199.6／183.8 | 60.4／52.7 | 33,323／18,419 |
| P5：無 mmap、預設 `cache_size` | 190.1／198.0 | 67.6／58.7 | 43,426／29,246 |
| P7：mmap、`cache_size=-1000000`（約 1 GB） | 191.5／153.4 | 57.2／32.6 | **0／0** |
| P8：無 mmap、`cache_size=-1000000` | 296.5／211.2 | 96.7／69.4 | **0／0** |

### 表 3：`sqlite3` CLI（OS 暖，每次新行程，`/usr/bin/time -p` 的 real，含行程啟動）

```bash
sqlite3 "file:$DB?mode=ro" "SELECT COUNT(*) FROM chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_sources);"
sqlite3 "file:$DB?mode=ro" "<同上>" "SELECT COUNT(*) FROM (SELECT source_key FROM chunk_sources EXCEPT SELECT source_key FROM scan_state);"
```

| | 三次 |
|---|---|
| Q1 | 0.27／0.27／0.23 s |
| Q1＋Q2 | 0.30／0.28／0.30 s |

## 判讀

1. **一個數量級的差別來自 OS 頁快取。** 同一個 Q1＋Q2，OS 冷時 2,984 ms、暖時 226–240 ms（約 13×）。
   冷的那一次有 11,338 次 major fault（頁從磁碟讀進來），暖的都是 0。成本跟著「頁在不在記憶體」走：
   OS 暖時，同一行程裡的新連線（P1 第 2 條）與新行程（P2–P4）第一次都不慢，只多約 1.2 萬次 minor
   fault（把已常駐的頁映進新連線的 mmap），比同一連線的第二次多約 5–30 ms（單次量測，噪音大）。
2. **SQLite 私有頁快取在預設大小下不是機理。** 預設 `cache_size` 2000 頁 × 4 KiB ≈ 8 MiB，而 Q1 一次
   約 33k miss、Q2 約 18k miss；第二次的 miss 數與第一次相同——私有快取沒有保留工作集。冷態的第一次與
   之後的差別，不是它造成的。把 `cache_size` 調到約 1 GB 後，同一連線第二次的 miss 變 0、Q1 快約 13%、Q2 快約 35%，
   **第一次不變**。所以 `cache_size` 只影響**同一條連線**的第二次以後（表 2，OS 暖）；`ltm` 每次查詢都
   開新連線（`LTMService.withEngine` 與 `IndexBuilder.build` 各開一條、用完即關），閘在 build 的連線上只跑一次，
   常駐的 `ltm mcp` 也一樣——它長駐，但每次查詢仍開新連線。
3. **statement 重用、mmap、`columnText`、syscall 都不是數量級的來源。** statement 重用與每次 prepare
   同級；關掉 mmap（改走 `pread`）在暖態讓 Q1＋Q2 慢約一成（表 2 的 P5 對表 1），仍是同一個量級；
   no-op 狀態下 Q2 回 0 列，`columnText` 根本沒被呼叫。
4. **同一 OS 快取狀態下，行程內與 CLI 同級。** 暖態 in-process 第一次 Q1＋Q2 約 0.23 s，CLI（含行程
   啟動）0.28–0.30 s。沒有「行程內比 CLI 慢 2×」的現象。

## #58 的「~0.9 s vs 0.44 s」：沒有重現，也不重新解釋

那兩個數字不是同一種量測。0.9 s 出自 #58 Diagnosis 候選表的「Q1 行程內 ~0.7–0.9s（sample 推算）」
——以 `sample`（1 ms 間隔）的樣本數推算，不是計時；當時是修法**之前**（舊的 DISTINCT＋LEFT JOIN Q2、
沒有 mmap），取樣當下的 OS 快取狀態沒有紀錄。0.44 s 在 #58 的 comment 與紀錄裡都沒有寫出怎麼來的；
最接近的是同一張表的 CLI 暖跑 Q1 0.21 s 與舊 Q2 0.20 s，相加是 0.41 s。（查法：issue 58 的 Diagnosis
comment，「候選」那張表與 Residue 段。）本紀錄能說的只有：同一 OS 快取狀態下量時間，兩條路徑同級；而閘的成本隨 OS 快取狀態差一個數量級，#58 沒有記錄那個狀態。
所以兩次量測之間的快取狀態不同是**候選**解釋，不是已證實的解釋。本表與 #58 的表不同日、不同語料、
不同設定，不互比。

## 第一版錯在哪

第一版（`e9f5dec`）寫「差距在同一連線的第一次觸碰——SQLite 每連線私有頁快取從零暖起，每個 `ltm`
行程都付一次」，並據此寫「`cache_size` 救不了、只有 #61 會消掉它」「#60 到此可以關」。它自己的表就
推翻了這一點：新連線（(c)(d)）第一次只要 0.141／0.127 s；CLI 每次是新行程，第 2、3 次卻只要
0.16／0.17 s。它 1.86 s 的那一次最可能是 Q2 的頁在 OS 層還冷——暖快取用的 CLI 只跑過 Q1——但那個
順序本紀錄沒有重跑。它的誠實邊界說機理「沒有 `cache_stats` 類的計數支撐」，而 `sqlite3_db_status`
一直都在；它也說「唯讀開啟」，但 (a)(b) 走的 `IndexDatabase(path:)` 只有讀寫模式。這些由 #60 verify R1
抓到（issue #60 的 verify comment，`issuecomment-5884588066`）。

## 與 #61 的關係（設計輸入）

- 閘的成本有兩個狀態：**暖**約 0.23 s（每次查詢都付，與連線、行程無關）；**冷**約 3 s（索引頁被 OS
  逐出之後的第一次）。#61 的設計若要量效果，冷態與暖態都要量——只量暖態會漏掉大的那一份。
- 冷態多常出現（見下一節）決定了哪一份主導實際使用：這次觀測到的是兩到四分鐘內就變冷。
- 冷態的成本是讀盤；哪一種改寫能降低它、降多少，本紀錄**沒有量**。第一版「換 SQL 寫法、調
  `cache_size` 都救不了」撤回：`cache_size` 對第一次沒有作用是表 2 量到的（OS 暖），其餘沒有量。

## OS 快取多快變冷（觀測，未歸因）

探針最後一次觸碰索引是 14:24:15 左右（P10 結束）。之後每分鐘跑一次 `--residency`，索引這段期間沒有被寫入
（mtime 一直是 14:09:31）：

| 時間 | 常駐頁（／168,188） |
|---|---|
| 14:24:27、14:25:27 | 35,367、35,186 |
| 14:26:27 | **0** |
| 14:27:27–14:29:28 | 10,721（有別的行程在 14:26–14:27 之間讀了索引，本紀錄沒有追是誰） |
| 14:30:28–14:53:29（24 次） | **0** |

另外兩個獨立觀測：14:23:04（本紀錄開跑前）是 0；#60 verify R1 的 DA 在 13:51 也量到 0。
**0 頁不是 `mincore` 的假象**：14:23:04 的 0 之後，第一次查詢真的帶了 11,338 次 major fault（表 1）。

所以在這台機器、這段時間的使用狀態下，索引頁在最後一次觸碰後**兩到四分鐘內**就被逐出，而且兩次都
是如此。逐出的原因**沒有歸因**——這段期間本 session 跑過 `swift test`（建置吃記憶體），另有 13 個
`ltm` 行程與其他 session 在跑；換一台機器或另一種負載，
時間尺度可能完全不同。這段只說明：冷態在實際使用裡不是罕見情形，量 #61 的效果時不能只量暖態。

## 誠實邊界

- 單機、單日；每個情形 1–3 次，沒有分佈統計。語料活著，數字只在本紀錄內可比。
- **冷態只有一個樣本**（P1 第 1 條連線第 1 次），而且是自然冷；冷態下 `cache_size`、mmap 開關的影響
  沒有量。
- major fault 只計得到 **mmap 視窗內**的頁：`SQLITE_MAX_MMAP_SIZE` 是 1 GiB，DB 約 2.76 GB，視窗外的
  頁走 `pread`，讀盤不算 page fault。所以 11,338 是讀盤次數的下界，不是全部；無 mmap 的冷態也沒有這個
  訊號。
- `mincore` 以 16 KiB 的 OS 頁計；P1 後常駐 46,126 頁，比 Q1＋Q2 實際需要的多（含預讀），不要拿它當
  工作集大小。
- 探針以 `SQLITE_OPEN_READONLY` 開檔；生產路徑 `IndexDatabase(path:)` 以
  `READWRITE | CREATE` 開、另下 WAL／`synchronous`／`mmap_size` PRAGMA。閘查詢本身只讀，但開檔旗標
  不同對讀取路徑的影響沒有量。
- 第一版表上的 `chunkCount()`（7 ms）這一版沒有量，也不沿用。
