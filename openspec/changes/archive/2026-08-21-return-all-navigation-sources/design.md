## Context

`refreshNavigation`（`Sources/LTMIndex/IndexDatabase.swift`）從 `chunk_sources` 挑一個來源填進 `chunks.session_id` / `chunks.timestamp`，排序規則是 `ORDER BY s.timestamp DESC, s.source_key DESC LIMIT 1`。因為 session resume 複製 turn 時不改訊息時間戳，第一個排序鍵在真實語料裡永遠平手，實際決定勝負的是第二個鍵（`source_key` 字典序）。該函式的 doc comment 已誠實記載這一點，並明寫它只保證確定性、不保證正確性，且「這不是 #25 的解答」。

指標一路從 `chunks` 表 → `ScoredChunk`（`Sources/LTMIndex/RetrievalEngine.swift`）→ `QueryHit`（`Sources/LTMService/LTMService.swift`）→ CLI 兩種輸出（`Sources/ltm/Commands.swift`）都是純量 `sessionID: String`。三份 spec（`retrieval` 的「Every result carries the four-field pointer」、`corpus-indexing` 的「Chunk granularity is one conversation turn with full pointer metadata」、`ltm-cli` 的 `ltm query` 輸出 Requirement）都把它寫成四元組純量。

`chunk_sources` 表已有 `(chunk_id, source_key, session_id, timestamp)`，每個持有該 chunk 的來源檔一列。

## Goals / Non-Goals

**Goals:**

- 讓導航資訊回傳**全部**來源，取代在一組等價來源裡做無依據挑選。
- 在 spec 明文處理「四元組指標」措辭的實質變更，而不是靜默把一個欄位改成集合。
- 保留 `chunks` 表對排序／範圍查詢的既有用途不受影響。
- 補上 issue #25 明文要求的測試：時間戳相同時回傳全部來源，而非字典序挑一個。

**Non-Goals:**

- 不改 `chunk_sources` 的 schema。
- 不引入新的觀察順序代理指標（mtime／掃描序／檔案大小）。
- 不處理跨 project 的同一 turn。

## Decisions

### Decision 1: `sessionID` 純量欄位保留，另加一個來源集合欄位

`ScoredChunk` 與 `QueryHit` 保留既有的 `sessionID: String`，另外新增一個具名的來源集合欄位（承載每個來源的 session id）。`sessionID` 的語意明確改寫為「這組來源裡的代表值」，而不是「最近觀察到的那一份」——它是**穩定的顯示用單值**，不再宣稱任何觀察順序含意。

**理由**：三份 spec 與所有既有消費端（含 `--json` 的既有欄位契約、CLI human 輸出、多條既有測試）都依賴這個純量欄位存在。把它直接刪掉會讓本次改動從「補上遺漏的資訊」變成「破壞既有介面」，而 issue #25 要的是前者。

**替代方案考慮過**：直接把 `sessionID` 換成陣列。**未採用**——它讓每個消費端都必須同時改，而其中一個（`ltm query --json` 的既有欄位）是對外契約。本 repo 已記錄的「同一件事有兩個寫者，就是兩份會漂移的規格」風險在此以另一種方式化解：純量欄位**不再自己決定值**，它由來源集合導出（見 Decision 2），所以不存在兩個獨立的寫者。

### Decision 2: 純量值由來源集合導出，不獨立計算

純量 `sessionID` 的值定義為「來源集合依 `source_key` 字典序排序後的第一個元素的 session id」。這是一個**明確標示為任意但確定**的選擇，且與來源集合是同一份資料——不是第二個真相來源。

實作上 `refreshNavigation` 維持現狀（`chunks` 表照常有純量欄位供排序／範圍查詢），但查詢投影同時撈出該 chunk 的全部 `chunk_sources` 列。

**理由**：`chunks.timestamp` 不只是導航，它同時被範圍查詢與排序使用，動它的成本遠大於本次範圍。把 `session_id` 的多值化做在**查詢投影層**而不是儲存層，兩者都不受影響。

**誠實邊界**：純量值仍然是任意的（字典序與「較晚觀察到」沒有因果關係）。差別在於**它不再是唯一被回傳的資訊**——消費端拿得到完整集合，可以自己決定要不要用那個代表值。

### Decision 3: `timestamp` 不多值化

`timestamp` 維持純量。resume 複製不改訊息時間戳，所以同一則 turn 的所有來源的 `timestamp` 在真實語料裡是**相同的值**——多值化它會產生一個永遠只有一個相異值的集合，是純粹的介面複雜度。

**誠實邊界**：這個論證依賴「resume 複製不改時間戳」這個已量測的事實（`docs/measurements/2026-08-18-resume-duplication.md`）。若未來出現時間戳確實不同的多來源情形，這個決定要重新檢視——屆時 `chunk_sources` 已經存著各自的 timestamp，不需要改 schema。

### Decision 4: CLI 兩種輸出的形狀

- **human-readable**：既有的指標行（`↳ session <id>  turn <uuid>`）在**只有一個來源**時逐字不變。多於一個來源時，該行改為列出全部 session id，形式為 `↳ sessions <id1>, <id2>  turn <uuid>`（複數字 `sessions` 讓「這則 turn 存在於多份檔案」在輸出上直接看得見）。
- **`--json`**：既有 `sessionId` 欄位保留（值為 Decision 2 的代表值），另**無條件**新增 `sessions` 陣列欄位，即使只有一個元素也照樣輸出。

**`sessions` 為什麼無條件輸出**：`Commands.swift` 的既有慣例是「只在有意義時才附加欄位」（`displacement` 只在重排策略下、`presentation` 只在有記錄事件時）。這裡刻意**不**沿用——那個慣例適用於「這次查詢沒有這個概念」的欄位，而每個 hit 永遠有至少一個來源。條件式輸出會讓消費端必須寫「欄位不存在時 fallback 到 `sessionId`」的分支，而那個分支只有在單來源時才走到，也就是最不容易被測到、最容易寫錯的路徑。

### Decision 5: 三份 spec 的措辭統一由 `corpus-indexing` 定義來源集合

`corpus-indexing` 的「Chunk granularity」Requirement 是指標語意的來源（它定義 chunk 存什麼）。本次在該 Requirement 定義「一個 chunk 可以有多個來源，每個來源帶自己的 session id」，`retrieval` 與 `ltm-cli` 的 Requirement 引用它、各自只規範自己那一層的形狀（回傳/輸出），**不重述來源集合的定義**。

**理由**：#15 連續五輪 verify 的主要 finding 全是「同一句話多處複本，改一處漏另一處」。這次一開始就把「哪一份 spec 擁有這個概念」定下來，其餘只引用。

## Implementation Contract

**行為**：
- 一則被 resume 複製到 N 份 session 檔的 turn 被檢索到時，回傳的來源集合有 N 個元素，各帶該檔的 session id；`sessionID` 純量是其中字典序最小 `source_key` 對應的那一個。
- 只出現在一份檔案的 turn：來源集合有 1 個元素，`sessionID` 就是它。
- `ltm query`（human）：單來源時輸出逐字不變；多來源時該行以 `sessions` 開頭並列出全部。
- `ltm query --json`：每個物件都有 `sessionId`（字串）與 `sessions`（字串陣列，至少 1 元素）。
- 增量建置與全量重建對同一語料產生相同的來源集合。

**介面 / 資料形狀**：
- `ScoredChunk` 與 `QueryHit` 各新增一個承載來源 session id 集合的欄位（具體命名在實作時定，需在兩處一致）。
- `IndexDatabase` 的查詢投影新增一次對 `chunk_sources` 的讀取，把每個 chunk 的來源列撈出來。
- CLI JSON 每個 hit 物件新增 `sessions: [String]`。

**失敗模式**：
- 一個 chunk 在 `chunk_sources` 裡沒有任何列：這是資料損壞（`refreshNavigation` 的 `EXISTS` 條件已假設至少一列）。本次不新增靜默 fallback——若查詢投影撈不到任何來源列，該 hit 依 `retrieval` spec 既有的「A result that cannot be attributed to a pointer tuple SHALL be dropped, not emitted partially」處置，並計入既有的診斷計數。

**驗收條件**：
- 新測試：兩份來源檔含同一則 turn、時間戳完全相同，查詢後回傳的來源集合有兩個元素且包含兩個 session id（不是字典序挑一個）。此測試在改動前必須為紅。
- 新測試：`ltm query --json` 的輸出對單來源與多來源兩種情形，`sessions` 陣列元素數分別為 1 與 2。
- 既有的不變式 2 性質測試（增量 = 全量重建）維持通過。
- `swift build` 無錯誤、`swift test` 全綠。

**範圍邊界**：
- 範圍內：`IndexDatabase` 查詢投影、`ScoredChunk`／`QueryHit` 欄位、CLI 兩種輸出、三份 delta spec、對應測試、CHANGELOG。
- 範圍外：`chunk_sources` schema、`refreshNavigation` 的排序規則本身、`chunks.timestamp` 的多值化、跨 project 的同一 turn。

## Risks / Trade-offs

- **[Risk]** 純量 `sessionID` 保留下來，未來仍可能被消費端當成「唯一來源」誤用 → **Mitigation**：spec 與欄位 doc comment 都明寫它是「來源集合的代表值，字典序選出，不帶觀察順序含意」；`sessions` 無條件輸出（Decision 4）讓完整資訊永遠在手邊，不需要特意去找。
- **[Risk]** 查詢投影多一次對 `chunk_sources` 的讀取 → **Mitigation**：不宣稱任何效能結論（本 repo 誠實邊界紀律：無量測支撐的效能宣稱不得出現）。實作時採單次 JOIN／批次讀取而非逐 chunk 查詢，避免 N+1；若之後量到問題，`chunk_sources_by_source` 索引已存在可供優化，屆時再以量測為依據處理。
- **[Risk]** Decision 3（`timestamp` 不多值化）依賴一個已量測但可能變的前提 → **Mitigation**：前提與其出處（`docs/measurements/2026-08-18-resume-duplication.md`）寫進 design 與 spec，且 `chunk_sources` 已存各自的 timestamp——改變決定時不需要 schema 遷移。
