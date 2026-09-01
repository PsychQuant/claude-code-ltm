# 掃描並行化前後的查詢延遲（#56）

**日期**：2026-09-01。**機器**：Apple M5 Max（18 邏輯核）、128 GB。**語料**：
scan_state 9,498 個活躍來源、合計 5.42 GB、最大單檔 127.5 MB；索引 644,750 chunks。
**建置**：release。語料是**活的**（本機 session 持續寫入），同日內兩輪量測之間
語料有成長——比較以「暖快取、無新內容」的穩態輪為準。

## 方法（可重跑）

no-op 增量 `ltm build` 與查詢前的 `refreshIncrementally()` 走同一條掃描＋併入
路徑，兩者相減即檢索路徑成本：

```bash
for i in 1 2 3; do /usr/bin/time -p .build/release/ltm build 2>&1 >/dev/null | grep real; done
for q in …; do /usr/bin/time -p .build/release/ltm query "$q" --k 5 2>&1 >/dev/null | grep real; done
```

## Before（循序逐檔雜湊，commit `86c9246` 時點）

| 量測 | 時間 |
|---|---|
| no-op build（冷 page cache） | 14.46s |
| no-op build（暖）×2 | 3.44s / 3.37s |
| query ×3 | 3.62s / 3.52s / 3.85s |

歸因：`CorpusScanner` 對每檔重讀＋重雜湊整段 prefix（每查詢 5.42 GB），
**逐檔循序**。掃描 ≈ 3.4s ≈ 查詢的 92%。

## After（並行雜湊：`ScanWorkBox`＋walk 序合併，width＝`activeProcessorCount`＝18）

| 量測 | 時間 |
|---|---|
| no-op build（第一輪，含消化累積的新 session 內容＋rebuild 後快取） | 32.88s（**不列入比較**：該輪做了真實 ingest） |
| no-op build（暖）×2 | **1.26s / 0.99s** |
| query ×6 | 1.31 / 1.68 / 1.05 / 1.39 / 1.05 / 1.00 |

## 結論

- 掃描段 **3.4s → ~1.0–1.3s**；查詢穩態 **3.5–3.9s → ~1.0–1.7s**（中位 ~1.2s）。
- 「1 秒以內」**未穩定達成**：最好樣本 1.00s、最差 1.68s。剩餘成本大宗仍是
  掃描段（~1.0s 下限），檢索段 ~0.3s 不變。
- 加速比 ≈ 3×，**遠低於 18 個 worker 的核心數**。本紀錄**不歸因**——沒有做
  profiling，候選解釋（記憶體頻寬、E-core、page cache、鎖）一個都沒被驗證。
  要再往下壓，先 profile 再談。

## 誠實邊界

- 單機、單日、樣本數小（build ×2、query ×6），無分佈統計。
- 全部在暖 page cache 下量；冷快取的 before 只有一筆（14.46s）、after 零筆
  ——冷路徑受磁碟 I/O 主導，本紀錄不涵蓋。
- 語料在兩輪之間成長（同一台機器的活語料），before/after 的語料非逐 byte
  相同；差異方向是 after 的語料**更大**，故低估而非高估改善幅度——但幅度
  數字仍以「約」理解。
- 等價保證來自 `parallelScanMatchesSequentialScanExactly`（width 4 vs 1 全等）
  與變異驗證（完成序寫入／漏合 tally／漏 invalidated 三個變異各自變紅）；
  「width 硬改 1」的變異行為全等、測試抓不到——效能差異由本紀錄守。
