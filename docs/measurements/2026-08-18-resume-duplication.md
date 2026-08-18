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

腳本：`/tmp` 下的一次性 python，邏輯逐字如下（無外部依賴，可重跑）：

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

## 這份紀錄支撐什麼

1. **重複是真的，而且規模不小**：12,488 個 turn 識別碼跨檔出現。
2. **重複的內容 100% 相同**——沒有一個反例。所以「同一則 turn 被複製進新檔」
   這個解釋成立，而「兩個不同的 turn 剛好撞到同一個 uuid」不成立。
3. **98.9% 帶著不同的 `sessionId`**。這是 `sessionId` 不能當定址成分的直接證據：
   內容沒變，它卻變了。

## 這份紀錄**不**支撐什麼

- **不涵蓋時間戳是否相同**。issue #25 關切的是「最近觀察到」在平手時退化，本次
  沒有量時間戳的分佈。目前的實作用「時間戳最新者勝、平手取 source key 最小者」，
  平手規則的正確性不依賴這份量測。
- **不涵蓋檢索品質**。這裡量的是語料的形狀，不是任何排序或 recall 的比較。
- **跳過的 583,924 行不是損壞**。它們多半是工具呼叫、結果、摘要這類非對話紀錄
  ——本專案目前不索引它們（issue #6 追蹤這件事）。這個數字在這裡只是說明樣本
  涵蓋範圍，不是錯誤率。

## 與先前那個數字的關係

先前散在程式碼裡的是「300 檔 5,722 筆」。那次是抽樣，本次是全量，兩者不衝突
——但**先前那次沒有留下紀錄**，所以它不可查證。引用時一律指向本檔。
