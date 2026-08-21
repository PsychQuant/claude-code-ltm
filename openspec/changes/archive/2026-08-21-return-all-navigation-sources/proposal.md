## Problem

`chunks.session_id` 的規則是「存**最近觀察到**的那一份」，但在真實語料裡這條規則從未真正生效：session resume 複製出來的兩份 turn 帶著**同一個原始時間戳**，所以時間戳比較永遠平手，勝負實際由 `source_key` 字典序決定（`refreshNavigation` 的 `ORDER BY s.timestamp DESC, s.source_key DESC LIMIT 1`）。

平手是常態不是例外：`docs/measurements/2026-08-18-resume-duplication.md` 量到全語料 8,324 檔中有 12,488 筆內容 100% 相同的 turn，其中 98.9% 的 sessionId 不同。

`session_id` 是導航資訊——使用者拿它去開對應的 session 檔。指到字典序碰巧最大的那一份不會報錯，只會讓「打開來看上下文」落在一份可能已被 resume 取代的對話裡，而讀者無從得知還有其他來源。

## Root Cause

「最近觀察到」需要一個觀察順序的代理指標，而現有欄位都不是：訊息時間戳在 resume 複製時不變（永遠平手）、檔案 mtime 會被備份／同步工具改動、檔案大小方向可能相反。挑任何一個單一來源都是在一組等價的來源裡做無依據的選擇。

`refreshNavigation` 的 doc comment 已誠實記載這一點（「這仍然是任意的」「**這不是 #25 的解答**」），它只保證**確定性**（同一組連結必然算出同一結果，所以增量與全量重建一致），不保證正確性。

## Proposed Solution

**不再挑一個。** `chunk_sources` 連結表（#24 加入）已經記著每個 chunk 出現在哪些來源、各自的 `session_id` 與 `timestamp`，資料層基礎完備。導航改為回傳**全部**來源，讓消費端知道這則 turn 存在於哪幾份 session 檔，而不是收到一個沒有依據的挑選結果。

三份 spec 目前都把指標寫成四元組 `(project, sessionId, uuid, timestamp)` 純量。本次改動把其中的 `sessionId` 擴充成一組來源，並在 spec 明文記錄這是對既有不變式措辭的實質變更，而不是靜默擴充。CLAUDE.md 已記載的「`sessionId` 不是身分，是導航資訊」是這個方向的支持論據。

`chunks` 表的純量 `session_id` / `timestamp` 欄位如何處置、CLI 兩種輸出格式的具體形狀、以及 `timestamp` 是否一併多值化，都是有實質取捨的決定，在 design.md 逐條裁決。

## Non-Goals

- **不改 `chunk_sources` 的 schema**。該表已存 `(chunk_id, source_key, session_id, timestamp)`，本次只是把既有資料暴露出去。
- **不引入新的觀察順序代理指標**（mtime／掃描序／檔案大小）。那是「挑一個」路線的變體，已在 issue #25 討論中被否決——回傳全部來源之後就不需要挑。
- **不處理跨 project 的同一 turn**。anchor 的 source 是 project 指紋，跨 project 的相同文字是不同的 anchor，不在本次範圍。

## Success Criteria

- 兩份 resume 複製、時間戳完全相同的 turn 被檢索到時，回傳的導航資訊包含**兩個**來源，而不是字典序挑出的那一個。這一條需要一個新測試——既有測試刻意給了不同時間戳，驗的是真實語料中不會發生的分支。
- 增量建置與全量重建對同一語料產生相同的導航結果（不變式 2 不被破壞）。
- `ltm query --json` 的輸出對「單一來源」與「多來源」兩種情形都有明確且已測試的形狀。
- 三份 spec（`retrieval`、`corpus-indexing`、`ltm-cli`）對指標的描述互相一致，且與實作一致。

## Impact

- Affected specs: retrieval, corpus-indexing, ltm-cli
- Affected code:
  - Modified:
    - Sources/LTMIndex/IndexDatabase.swift
    - Sources/LTMIndex/RetrievalEngine.swift
    - Sources/LTMService/LTMService.swift
    - Sources/ltm/Commands.swift
    - Tests/LTMIndexTests/IndexDatabaseTests.swift
    - Tests/LTMIndexTests/RetrievalEngineTests.swift
    - Tests/LTMServiceTests/LTMServiceTests.swift
    - Tests/LTMServiceTests/CLICommandTests.swift
    - CHANGELOG.md
  - New: （無）
  - Removed: （無）
