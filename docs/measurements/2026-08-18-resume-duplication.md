# session resume 造成的 turn 重複（全語料）

2026-08-18。issue #24 / change `fix-band-semantics-and-turn-identity`。

## 為什麼量這個

`Anchor.source` 從 `sessionId` 換成 project 指紋，以及 chunk 身分從 `uuid` 換成
`(project 指紋, uuid)`，兩者的整個理由都建立在一個經驗宣稱上：

> 同一則 turn 會出現在多個 session 檔裡，內容相同，但 sessionId 不同。

那個宣稱先前以「300 檔 5,722 筆」的形式散在七處程式碼與文件裡，而
`docs/measurements/` 下**沒有任何紀錄**——CLAUDE.md 的誠實邊界要求可指名的紀錄，
所以那七處在當時都不合規。本檔補上，並把樣本從 300 檔擴到全語料。

## 方法

唯讀掃描 `~/.claude/projects/**/*.jsonl`（不變式 1：語料唯讀，本次只讀不寫）。

對每一行 JSON，取 `uuid` / `sessionId` / `message`，把 `message.content`
正規化成字串後取 SHA-256。三者任一缺失或型別不符就跳過並計數。

「重複」的定義是**同一個 `uuid` 出現在一個以上的檔案**——同一檔內的重複不算，
那是另一回事。

腳本：[`scripts/measure-resume-duplication.py`](../../scripts/measure-resume-duplication.py)
（無外部依賴，可重跑）。核心邏輯：

```python
seen[uuid].append((path, sessionId, sha256(content)))
multi = {u: v for u, v in seen.items() if len({p for p, _, _ in v}) > 1}
same_content = sum(1 for v in multi.values() if len({h for _, _, h in v}) == 1)
diff_session = sum(1 for v in multi.values() if len({s for _, s, _ in v}) > 1)
```

## 結果

| 量 | 值 |
|---|---|
| 語料檔數 | 8,324 |
| 解析出的 turn 紀錄 | 677,913 |
| 跳過的行 | 583,924 |
| 不同的 `uuid` | 663,901 |
| **出現在一個以上檔案的 `uuid`** | **12,488** |
| 其中內容完全相同 | 12,488（**100.0%**） |
| 其中 `sessionId` 不同 | 12,351（**98.9%**） |

**語料快照**：這份數字對應 2026-08-18 當下的 `~/.claude/projects/`。語料每天都在長，
所以重跑會得到不同的絕對數字——**應該對照的是比例**（跨檔 uuid 的內容相同率、
sessionId 相異率），那兩個才是這份紀錄要支撐的性質。

## 這份紀錄支撐什麼

1. **重複是真的，而且規模不小**：12,488 個 turn 識別碼跨檔出現。
2. **重複的內容 100% 相同**——沒有一個反例。所以「同一則 turn 被複製進新檔」
   這個解釋成立，而「兩個不同的 turn 剛好撞到同一個 uuid」不成立。
3. **98.9% 帶著不同的 `sessionId`**。這是 `sessionId` 不能當定址成分的直接證據：
   內容沒變，它卻變了。

## 這份紀錄**不**支撐什麼

- ~~**不涵蓋時間戳是否相同**~~ —— **2026-08-22 補量，此限制已解除**（見下方「時間戳
  相異率」一節）。原文保留於此，因為 #25 的 spec 與程式碼註解曾在這個缺口尚未補上
  時就引用本紀錄宣稱「已量測」；那是誠實邊界的違規，補量是修法，刪掉這行則會湮滅
  它發生過。
- **不涵蓋檢索品質**。這裡量的是語料的形狀，不是任何排序或 recall 的比較。
- **跳過的 583,924 行不是損壞**。它們多半是工具呼叫、結果、摘要這類非對話紀錄
  ——本專案目前不索引它們（issue #6 追蹤這件事）。這個數字在這裡只是說明樣本
  涵蓋範圍，不是錯誤率。

## 與先前那個數字的關係

先前散在程式碼裡的是「300 檔 5,722 筆」。那次是抽樣，本次是全量，兩者不衝突
——但**先前那次沒有留下紀錄**，所以它不可查證。引用時一律指向本檔。


## 補量：跨檔複製的時間戳相異率（2026-08-22）

`#25` 讓 `chunks.timestamp` 保留為對來源集合取極值的純量（`MAX(chunk_sources.timestamp)`），
其安全性完全依賴一個前提：**同一則 turn 的所有 resume 複製帶相同的原始時間戳**，於是那個
極值是常數、不會隨集合成長而移動。上一節原本明文不涵蓋這件事，而 spec 與程式碼註解卻已
引用本紀錄宣稱它「已量測」。這一節補上該量測。

| 量 | 值 |
|---|---|
| 掃描檔案數 | 8,680 |
| 出現在一個以上檔案的 uuid | 23,908 |
| 其中時間戳相異者 | **0** |
| 相異率 | **0.00%** |

**方法**：唯讀掃 `~/.claude/projects/**/*.jsonl`，逐行解析，對每個 `uuid` 收集
`(檔案路徑, timestamp)`；跨檔 uuid 定義為出現在 ≥2 個不同檔案者；相異定義為該 uuid 的
timestamp 集合大小 > 1。

**這份補量涵蓋什麼**：目前這份語料裡，resume 複製確實不改時間戳。因此
`refreshNavigation` 的 `MAX(timestamp)` 目前退化為常數，不具備 `session_id` 那種
「極值隨集合成長而移動」的不穩定性。

**不涵蓋什麼**：這是**當下語料的形狀**，不是 Claude Code 的寫入契約。若未來版本改為
在複製時重寫 timestamp，這個前提就失效，而 `chunks.timestamp` 會退化成與被移除的
`session_id` 同一個形狀。屆時的修法與 #25 相同：不挑極值，讓 `chunk_sources` 保留
逐來源的值。
