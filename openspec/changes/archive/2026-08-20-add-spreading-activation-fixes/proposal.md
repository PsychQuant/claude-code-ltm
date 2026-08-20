## Why

`/idd-verify #15` 對已歸檔的 `add-spreading-activation` 改動回報 `verdict: FINDINGS`（37 筆，去重後 6 個獨立缺陷）：擴散機制的實際落地與它自己引用的既有 spec 保證衝突、滲透到不該套用的策略、污染了另一個 capability 的驗證器，而歸檔文件留著與程式碼矛盾的宣稱。這些不是實作疏漏，是 design.md 風險分析本身的漏洞（最明確的例子：一句「grep 確認過沒有消費端把 `presentation == nil` 當 load-bearing 檢查」沒有被認真驗證就寫進了文件）。#15 在這批缺陷修好前不能視為完成。

## What Changes

- 收斂擴散的目標範圍為既有的 `memory-events` spec 的例外，而非違反：`memory-events` 的「Only deliberate interactions reinforce」Requirement 增加一條擴散專屬的新 scenario，明確記錄「同框但自身零直接互動的 anchor，可能因擴散拿到非零 reinforcement」這個已知例外——機制不改（保留 Definition A：同框呈現即使自己未被開啟也拿到擴散加分）。
- 擴散收斂為 human-like 專屬：不新增獨立後處理模組，改為讓 `LTMService.makeProjection` 依策略傳遞不同的 `ProjectionParameters.spreadingActivationFactor`（human-like 用預設值，其餘策略傳 0，沿用「0 等於關閉擴散」既有文件語意）。`MemoryStrategy` protocol 新增一個能力宣告，讓服務層知道該傳哪個值。**BREAKING**：`conservative` 策略先前（非預期地）會吃到擴散，本次改動後不再吃到——這是修正，回到 spec 原本只授權 human-like 的範圍。
- `ComparisonScorer`（`Sources/LTMEval/ComparisonReport.swift`）新增一條合法略過路徑：`presentation` 非 nil 但查無對應 `PresentationRecord` 時視為「不屬於本次比較」而略過，不再無條件拋 `unknownPresentationReference`。`LTMService.query()` 配發 `PresentationID` 的既有範圍（有記錄事件就配）維持不變——擴散依賴這個分組才能運作，收窄範圍會讓擴散在一般查詢下失效。這個修法**接受一個明確記錄的偵測力損失**：因為 `PresentationID` 是隨機 UUID、與比較實驗撞號機率趨近於零，這條路徑目前無法再區分「這筆本來就不屬於任何比較」與「這筆本該屬於某次比較、但 harness 內部寫壞導致 record 遺失」——兩者現在都會被視為合法略過。
- `ltm query --json` 輸出補上 `presentation` 欄位（有值時才出現，比照 `displacement`/`history`/`movement` 只在有意義時才附加的既有慣例）。
- 擴散的兩個尚未收斂的行為：對已被使用者明確 `dismissed` 的 anchor 不再套用正向擴散（排除為擴散目標）；對同框群組大小加一個防禦性上限（超過門檻的群組視為可疑，跳過該次擴散，不無界放大）。
- `openspec/changes/archive/2026-08-19-add-spreading-activation/design.md` 與 `proposal.md` 補一段「Deviation / Errata」，更正「`spreadingActivationFactor` 參數沿用 AI4o」這個不成立的宣稱——附加、不改寫既有內容。
- `Tests/LTMMemoryTests/ProjectionTests.swift` 新增一條回歸測試：同框全部都是 `.shown` 事件時 reinforcement 仍為 0（既有的 `impressionsAloneProduceNoReinforcement` 因為 fixture helper 不設 `presentation`，測不到這條路徑）。
- `CHANGELOG.md` 補上本次改動的條目。

## Non-Goals

- 不重構 `PresentationID` 成雙命名空間（分離「擴散分組」與「比較實驗歸屬」兩種身分）。這是 `ComparisonScorer` 判準修法唯一能保留全部偵測力的做法，但範圍遠超本次「修 #15 遺留缺陷」的動機，留給未來若這個偵測力損失被證實有實際代價時再開新 change。
- 不校準 `spreadingActivationFactor` 的預設值 0.3。它已在程式碼註解誠實記錄「找不到 AI4o 出處、未經本語料驗證」（#1 verify 既有紀律），本次不新增校準工作——校準需要 #16 的評估集，目前不存在。
- 不處理 CLI JSON 輸出改成 `{ "hits": [...], "diagnostics": {...} }` 的既有已知缺口（見 `Commands.swift:489` 註解）——那屬於 #24 Stage 2 的範圍，本次只補 `presentation` 這一個欄位到既有陣列格式裡。

## Capabilities

### New Capabilities

（無）

### Modified Capabilities

- `memory-events`：「Only deliberate interactions reinforce」Requirement 新增擴散專屬例外 scenario。
- `memory-strategy`：擴散明確收斂為 human-like 專屬（新增 Requirement 或修改既有 Requirement，明訂其他策略不受擴散影響）。
- `strategy-comparison`：`ComparisonScorer` 對「presentation 非 nil 但查無 record」的處置從拒絕改為合法略過，並記錄接受的偵測力取捨。
- `ltm-cli`：`--json` 輸出新增 `presentation` 欄位。

## Impact

- Affected specs: memory-events, memory-strategy, strategy-comparison, ltm-cli
- Affected code:
  - Modified:
    - Sources/LTMMemory/Projection.swift
    - Sources/LTMQuery/MemoryStrategy.swift
    - Sources/LTMService/LTMService.swift
    - Sources/LTMEval/ComparisonReport.swift
    - Sources/ltm/Commands.swift
    - Tests/LTMMemoryTests/ProjectionTests.swift
    - Tests/LTMServiceTests/LTMServiceTests.swift
    - Tests/LTMEvalTests/ComparisonReportTests.swift
    - openspec/changes/archive/2026-08-19-add-spreading-activation/design.md
    - openspec/changes/archive/2026-08-19-add-spreading-activation/proposal.md
    - CHANGELOG.md
  - New: （無）
  - Removed: （無）
