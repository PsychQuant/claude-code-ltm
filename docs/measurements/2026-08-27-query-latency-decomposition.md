# `ltm query` 的延遲分解（#48 之後、ANN 重議、SessionEnd hook 三者共用）

**日期**：2026-08-27
**機器**：MacBook Pro M5 Max（18 核、128 GB）
**binary**：`.build/release/ltm`，commit `666c332`
**索引**：當天首次成功的全量 build——640,760 chunk、`vectors.bin` 1.3 GB、
`index.sqlite3` 1.8 GB、語料 9,958 檔／5.67 GB

## 為什麼量這個

`docs/measurements/2026-08-08-baseline.md` 說「暴力 cosine 是毫秒級、不需要 ANN，
等超過幾百萬 chunk 再議」，而那是在 **280,000 chunk 的估計**上做的判斷。實際建出來
是 **640,760**，估計低了 2.29 倍，所以那個結論的前提要重新檢查。

同時 `.claude/rules/ltm-analogy.md` 明寫：要重開「SessionEnd hook 預先併入」的討論，
必須先有一份「查詢前的增量併入耗時」紀錄。本檔就是那一份。

## 方法：四點差分

每個條件連跑 3–5 次取 min/median/max。各條件之間只差一段工作：

| 條件 | 包含 | median |
|---|---|---|
| C. `ltm query --help` | 純行程啟動 | **0.01 s** |
| D. 空語料 `ltm build --quiet` | ＋開索引（＋可能的模型載入，見誠實邊界）| **0.08 s** |
| A. `ltm build --quiet`（索引已最新）| ＋掃 9,958 檔／5.67 GB 的增量併入 | **6.58 s**（min 6.11）|
| B. `ltm query <字串> --all-projects` | ＋查詢字串 embedding ＋讀 1.3 GB 側車 ＋ FTS ＋暴力 cosine | **6.19 s**（min 6.12）|

## 結果一：向量檢索不是瓶頸

**B − A 落在雜訊以下。** A 自己的執行間變異是 6.11–8.23 s，而 B 的中位數比 A 的
中位數還低。也就是說「讀 1.3 GB 側車 ＋ 對 640,760 個 512 維向量算暴力 cosine ＋
FTS 查詢」這一整段，在這個量測的解析度下**量不出來**。

**這回答了 ANN 的問題，而且答案與規模無關**：不是「chunk 還不夠多所以還撐得住」，
是**被優化的對象根本不在這裡**。baseline 的重議門檻（`:72`「chunk 數逼近百萬」）
問錯了維度——chunk 數再翻一倍，這一段仍然不是主要成本。

**這份紀錄不支持**「暴力 cosine 是 X 毫秒」這種陳述。它只支持「它相對於 6 秒小到
量不出來」。要那個數字得做 in-process 計時，本檔沒做。

## 結果二：6 秒幾乎全在掃描，而其中只有 39% 有歸屬

A − D ≈ **6.5 秒**，全部是「掃 9,958 檔的增量併入」。

已歸屬的部分：續讀檢查會把每個檔案的已處理前綴**整段重讀並算 SHA-256**
（`CorpusScanner` 的 `prefixHash`）。當天實測：

| | |
|---|---|
| 檔數 | 9,958 |
| 位元組 | 5,665,527,427（5.67 GB）|
| 全讀 + SHA-256 | **2.39 秒** |
| 吞吐 | 2,371 MB/s |

查法（可重跑）：

```bash
python3 -c "
import hashlib,time,pathlib
fs=list((pathlib.Path.home()/'.claude/projects').rglob('*.jsonl'))
t=time.time(); n=0
for f in fs:
    with open(f,'rb') as fh:
        h=hashlib.sha256()
        while (b:=fh.read(1<<20)): h.update(b); n+=len(b)
print(len(fs), n, time.time()-t)"
```

**2.39 / 6.5 ≈ 37–39%。剩下約 4 秒沒有歸屬。** 候選（未隔離量測，不得當成結論）：
目錄走訪與 `stat`、尾段 JSON 解析、`ScanState` 的 9,935 筆讀寫、SQLite 的
`chunk_sources` 查詢。**哪一項佔多少，本檔答不出來。**

`2026-08-26-resume-prefix-hash-cost.md` 量到的是 3.96 s／1,373 MB/s，本檔是
2.39 s／2,371 MB/s。差異方向與 page cache 一致（本檔在全量 build 剛結束時量，
cache 是熱的），但**沒有做冷／熱對照**，所以那個歸因也是推測。實際的續讀成本
應落在兩者之間，視 cache 狀態而定。

## 這份紀錄改變了什麼

`2026-08-26-resume-prefix-hash-cost.md` 的結論是「現在不換 Merkle，上界才 4 秒」。
那個判斷把它當成**啟動成本**在評估。本檔指出它是**每次查詢**都要付的——`LTMService`
在每次 `query()` 前跑 `refreshIncrementally()`，而 MCP server 是常駐行程，所以
行程啟動與模型載入被攤掉了，**掃描沒有**。

「4 秒的一次性啟動成本」與「每次記憶查詢固定 4 秒」是兩個不同的決定問題，而先前
只評估過前者。那份紀錄自己寫明了 Merkle 買的是「成本隨改動量而非總量成長」——
那正是這個使用形態需要的東西。

## 不支持的結論

- 任何「暴力 cosine 是 X 毫秒」的數字。
- 「那 6 秒是 SHA-256 造成的」——只有 39% 有歸屬。
- 「換 Merkle 會讓查詢快 N 倍」——未歸屬的那 4 秒可能不受 Merkle 影響。
- 冷 cache 下的任何數字。本檔全部在熱 cache 下量。
