# 掃描並行化前後的查詢延遲（#56）

**日期**：2026-09-01。**機器**：Apple M5 Max（18 邏輯核）、128 GB、macOS 27。
**語料**：before 量測時 scan_state 9,498 個活躍來源、合計 5.42 GB、最大單檔
127.5 MB；索引 644,750 chunks。**建置**：release。**commit**：before 在
`86c9246`、after 在 `cfa5170`。語料是**活的**（本機 session 持續寫入），兩輪
之間語料有成長；warm 樣本間未逐一確認零 ingest（見誠實邊界）。

## 方法（可重跑）

no-op 增量 `ltm build` 與查詢前的 `refreshIncrementally()` 走**同一條共享
refresh/build 路徑**（掃描＋併入＋process 啟動＋鎖＋DB 開啟）。量測比較的是
這條共享路徑的端到端時間與查詢的端到端時間——**不是** `CorpusScanner.scan()`
的獨立時間：no-op build 的數字是掃描元件的**上界**，不是它本身。

```bash
for i in 1 2 3; do /usr/bin/time -p .build/release/ltm build 2>&1 >/dev/null | grep real; done
for q in "${QUERIES[@]}"; do /usr/bin/time -p .build/release/ltm query "$q" --k 5 2>&1 >/dev/null | grep real; done
```

查詢集（逐字）：before 用「tokenizer 討論」「flock inode 鎖」「資格考」；after
先跑同三則、再加「band 相關度」「memory strategy」「並行雜湊」共六筆。

## Before（循序逐檔雜湊，`86c9246`）

| 量測 | 時間 |
|---|---|
| no-op build（冷 page cache） | 14.46s |
| no-op build（暖）×2 | 3.44s / 3.37s |
| query ×3 | 3.62s / 3.52s / 3.85s |

歸因（code 事實＋上界推論）：`CorpusScanner` 對每檔重讀＋重雜湊整段 prefix
（每查詢 5.42 GB），**逐檔循序**。共享 refresh/build 路徑（≤3.4s）佔查詢
（3.6–3.9s）的大宗；掃描是該路徑裡唯一隨語料總量成長的項，但本紀錄**沒有**
元件級計時，不對「掃描本身佔幾 %」給數字。

## After（並行雜湊：`ScanWorkBox`＋walk 序合併，width＝`activeProcessorCount`＝18，`cfa5170`）

| 量測 | 時間 |
|---|---|
| no-op build（第一輪，含消化累積的新 session 內容） | 32.88s（**不列入比較**：該輪做了真實 ingest） |
| no-op build（暖）×2 | **1.26s / 0.99s** |
| query ×6 | 1.31 / 1.68 / 1.05 / 1.39 / 1.05 / 1.00 |

## 結論

- 共享 refresh/build 路徑 **≤3.4s → ≤1.3s**；查詢端到端 **3.5–3.9s →
  ~1.0–1.7s**（六筆中位 ~1.2s）。
- 「1 秒以內」**未穩定達成**：最好樣本 1.00s、最差 1.68s。
- 檢索段（查詢減共享路徑）**本紀錄不給數字**：build 與 query 樣本未成對、
  各有不同 CLI 開銷，相減不可靠——第一版曾寫「檢索段 ~0.3s 不變」，被
  #56 verify 以本表自己的數字反駁，撤回。
- 加速比 ≈ 3×，**遠低於 18 個 worker**。本紀錄**不歸因**——沒有做
  profiling，候選解釋（記憶體頻寬、E-core、page cache、鎖、單一大檔長尾）
  一個都沒被驗證。要再往下壓，先 profile 再談。

## 誠實邊界

- 單機、單日、樣本數小（build ×2、query ×6），無分佈統計。
- 全部在暖 page cache 下量；冷快取的 before 只有一筆（14.46s）、after 零筆。
- 語料在兩輪之間成長且量測期間持續被寫入；warm 樣本之間**沒有**逐一確認零
  ingest。成長的方向效應**不下結論**（第一版寫「故低估改善」——總量變大
  通常增加工作，但並行時間也受檔案分佈、cache 命中、負載平衡影響，單靠
  總量推不出方向；且 after 側沒有記錄自己的語料數字可比）。
- **記憶體未量測**：並行讓暫態峰值最壞放大到 width × 最大單檔（18 ×
  127.5 MB ≈ 2.3 GB 的算術上界，加上 outcome 陣列）——本紀錄只量牆鐘，
  `2026-08-26-build-peak-memory.md` 的 RSS 模型是在循序掃描下擬合的，
  對並行版**不再適用**，重量測前不引用。
- 等價保證：`parallelScanMatchesSequentialScanExactly`（width 4 vs 1 全等）
  證的是**寬度不敏感**；「與舊迴圈等價」由既有測試扛（skip-tally 明確數值、
  改寫重解、增量等價 property test——後者以預設寬度跑，即並行路徑在其
  涵蓋內）。變異與扛它的測試：完成序寫入 → 等價測試（DA 8/8 紅）；漏合
  tally 欄位 → `ParallelScanTests` 的明確數值斷言（verify-fix 補上前，
  刪 `noIndexableText` 合併行曾 557 全綠）；漏 invalidated → 既有改寫重解
  測試。「width 硬改 1」行為全等、任何測試抓不到——效能由本紀錄守。
