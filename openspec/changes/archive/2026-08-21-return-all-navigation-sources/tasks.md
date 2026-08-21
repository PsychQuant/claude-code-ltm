## 1. 查詢投影撈出全部來源（Decision 1: `sessionID` 純量欄位保留，另加一個來源集合欄位；Decision 2: 純量值由來源集合導出，不獨立計算）

- [x] 1.1 RED：在 `Tests/LTMIndexTests/IndexDatabaseTests.swift` 新增測試，建構兩份來源檔含同一則 turn（內容相同、時間戳**完全相同**，模擬 session resume），斷言查詢該 chunk 時取得的來源集合有兩個元素且兩個 session id 都在裡面。確認此測試在目前程式碼下為紅（現況只回傳字典序挑出的單一值）。這條測試補的正是 issue #25 明文指出的缺口：既有測試刻意給不同時間戳，驗的是真實語料中不會發生的分支。
- [x] 1.2 GREEN：`Sources/LTMIndex/IndexDatabase.swift` 的查詢投影新增對 `chunk_sources` 的讀取，把每個 chunk 的全部來源列（各自的 session id）撈出來。用單次 JOIN 或批次讀取，不要逐 chunk 查詢（避免 N+1）。`refreshNavigation` 與 `chunks` 表的純量欄位不動。1.1 轉綠，既有 `IndexDatabaseTests` 全部維持通過。
- [x] 1.3 GREEN：`Sources/LTMIndex/RetrievalEngine.swift` 的 `ScoredChunk` 新增承載來源 session id 集合的欄位，由 1.2 的投影填入；`sessionID` 純量改為由該集合依 `source_key` 字典序取第一個導出（不再獨立計算），並在欄位 doc comment 明寫它是「來源集合的代表值，不帶觀察順序含意」。驗證：`swift test --filter LTMIndexTests` 全綠。

## 2. 集合貫穿到 facade 與 CLI（Decision 4: CLI 兩種輸出的形狀）

- [x] 2.1 GREEN：`Sources/LTMService/LTMService.swift` 的 `QueryHit` 新增同名（與 `ScoredChunk` 一致）的來源集合欄位，由 `query()` 從 `ScoredChunk` 傳遞。驗證：`swift test --filter LTMServiceTests` 全綠。
- [x] 2.2 RED：在 `Tests/LTMServiceTests/CLICommandTests.swift` 新增測試，語料含一則被兩份檔持有的 turn 與一則只被一份檔持有的 turn，斷言 `ltm query --json` 的輸出中前者的 `sessions` 陣列有 2 個元素、後者有 1 個，且兩者的 `sessionId` 都出現在自己的 `sessions` 裡。確認測試在目前程式碼下為紅（`sessions` 欄位尚不存在）。
- [x] 2.3 GREEN：`Sources/ltm/Commands.swift` 的 `printJSON` 為每個 hit 物件**無條件**加入 `sessions` 字串陣列（即使只有一個元素也輸出）。在該處程式碼註解寫明為什麼不沿用「只在有意義時才附加欄位」的既有慣例（條件式輸出會製造只在單來源時才走到、最不容易被測到的 fallback 分支）。2.2 轉綠。
- [x] 2.4 RED→GREEN：human-readable 輸出——先在 `Tests/LTMServiceTests/CLICommandTests.swift` 新增測試斷言「單一來源時指標行逐字不變、多來源時該行以複數標籤列出全部 session id」（確認為紅），再改 `Sources/ltm/Commands.swift` 印指標行的那段：單來源維持既有形式，多來源改為列出全部。測試轉綠。

## 3. Spec 與文件（Decision 5: 三份 spec 的措辭統一由 `corpus-indexing` 定義來源集合；Decision 3: `timestamp` 不多值化）

- [x] 3.1 內容審查：確認 `openspec/changes/return-all-navigation-sources/specs/` 底下三份 delta spec 的分工正確——`corpus-indexing` 的 Requirement "Chunk granularity is one conversation turn with full pointer metadata" 是來源集合的唯一定義處（含 Decision 3 的 `timestamp` 維持純量及其量測依據），`retrieval` 的 "Every result carries the four-field pointer" 與 `ltm-cli` 的 "ltm query prints pointered hits in human and JSON forms" 只引用它、各自規範自己那一層的形狀，兩者都沒有重述集合的定義。若發現任何重述，刪掉重述改為引用。
- [x] 3.2 內容審查：確認三份 delta spec 的 scenario 與第 1、2 組的測試逐一對應（`corpus-indexing` 的兩份來源／單一來源 scenario ↔ 1.1；`retrieval` 的 source set 隨每個 hit 出現 ↔ 2.1；`ltm-cli` 的 JSON 與 human 兩條 scenario ↔ 2.2/2.4），沒有無對應測試的 scenario、也沒有無 scenario 支撐的測試。
- [x] 3.3 `CHANGELOG.md` 新增條目，描述導航從「挑一個來源」改為「回傳全部來源」的行為變更，並註明純量 `sessionId` 保留為代表值、`timestamp` 維持純量及其理由。驗證：內容審查。

## 4. 全量驗證

- [x] 4.1 既有的不變式 2 性質測試（增量建置與全量重建可觀察狀態相同）維持通過，確認新增的查詢投影沒有破壞它。驗證：`swift test --filter IncrementalEquivalenceTests` 全綠。
- [x] 4.2 全量驗證：`swift build` 無錯誤、`swift test` 全綠（涵蓋 `LTMIndexTests`、`LTMServiceTests` 等全部 target）。驗證：終端機輸出確認測試總數與全綠狀態。
