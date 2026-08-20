## 1. Gate spreading to the human-like tier only（Decision 2: Gate spreading per-strategy via `ProjectionParameters.spreadingActivationFactor`, not a new module）

- [x] 1.1 RED：在 `Tests/LTMServiceTests/LTMServiceTests.swift` 新增一條測試，斷言用 `conservative` 策略查詢時，同框呈現群組內一個只有 `.shown` 事件的 anchor 收到零 reinforcement（即使群組內另一 anchor 被 `opened`）——先確認這條測試在目前程式碼下會失敗（conservative 目前意外吃到擴散）。
- [x] 1.2 GREEN：在 `Sources/LTMQuery/MemoryStrategy.swift` 的 `MemoryStrategy` protocol 新增一個 `Bool` 能力宣告（例如 `appliesSpreadingActivation`），透過 protocol extension 給預設值 `false`；`Sources/LTMQuery/Strategies/HumanLikeStrategy.swift` 覆寫為 `true`。`ConservativeStrategy`／`ArchivalStrategy` 不需改動（繼承預設 `false`）。1.1 的測試轉綠，且既有 `Tests/LTMQueryTests/*.swift` 全部維持通過。
- [x] 1.3 GREEN：`Sources/LTMService/LTMService.swift` 的 `makeProjection` 依 `strategy.appliesSpreadingActivation` 組出對應的 `ProjectionParameters`（`true` 時用預設 `spreadingActivationFactor`，`false` 時傳 `0`），取代目前永遠使用 `.default` 的行為。驗證：`swift test --filter LTMServiceTests` 全綠，且 1.1 的測試持續為綠。
- [x] 1.4 內容審查：`openspec/specs/memory-strategy/spec.md` 的 Requirement "The human-like tier spreads reinforcement to co-presented anchors, one hop only" 內容與本次 delta 一致（"conservative 不受擴散影響" 的 scenario 已在 spec 中）——確認無需再改動 delta spec 本身。

## 2. Document the spreading exception and its edge cases in `memory-events`（Decision 1: Document spreading as a documented exception in `memory-events`, not a violation; Decision 4: Exclude dismissed anchors as spread targets, and cap presentation-group size）

- [x] 2.1 RED：在 `Tests/LTMMemoryTests/ProjectionTests.swift` 新增測試 `dismissedAnchorDoesNotReceiveSpreadingReinforcementFromCoPresentedOpenedAnchor`：同框群組中一個 anchor 被 `opened`、另一個 anchor 有自己的 `.dismissed` 事件，斷言後者的 reinforcement 仍為 0——先確認在目前程式碼下失敗（現有實作對 dismissed 目標一樣套用擴散）。
- [x] 2.2 GREEN：`Sources/LTMMemory/Projection.swift` 的擴散迴圈（`for entry in deliberateContributions ... for other in members`）新增排除條件：`other` 若有自己的 `.dismissed` 事件則跳過。2.1 轉綠，既有「擴散激發」段落全部測試維持通過。**修正（fix-round-3）**：本行原本寫「`other` 若在 `suppression` 裡有非零值（即有自己的 `.dismissed` 事件）則跳過」，把數值非零與事件存在宣告為等價——這個等價不成立（`dismissedWeight: 0` 合法），fix-round-2 已把實作改成獨立追蹤事件存在性（`dismissedAnchors: Set<Anchor>`，見對應測試 `dismissedExclusionHoldsEvenWhenDismissedWeightIsZero`）。
- [x] 2.3 RED：在 `Tests/LTMMemoryTests/ProjectionTests.swift` 新增測試 `oversizedPresentationGroupDoesNotSpread`：建構一個超過門檻大小的同框群組，斷言群組內只有 `.shown` 事件的成員 reinforcement 為 0——先確認在目前程式碼下（無群組大小上限）該測試若群組確實超大，其實已經是 0（因為沒有 opened 就沒有 deliberateContributions），所以測試需改為在群組內放一個 opened 成員，驗證超大群組時「本應收到擴散」的其他成員仍為 0；確認此測試在加上限之前為紅（因為目前無上限、正常情況會是非零）。
- [x] 2.4 GREEN：`Projection.swift` 為同框群組大小加一個防禦性上限常數（實作時定名，程式碼註解標記「防禦性上限，非校準值」），超過上限的群組整體跳過擴散。2.3 轉綠。
- [x] 2.5 GREEN（Decision 7: New regression test for co-presented shown-only anchors）：`Tests/LTMMemoryTests/ProjectionTests.swift` 新增測試 `coPresentedShownOnlyAnchorsProduceNoReinforcementWithoutADeliberateEventInTheGroup`：同框群組內所有事件皆為 `.shown`，斷言群組內每個 anchor 的 reinforcement 皆為 0；驗證：該測試在 `impressionsAloneProduceNoReinforcement` 之後新增，且與既有擴散測試（`coPresentedAnchorWithNoDirectInteractionGainsReinforcement` 等）同時保持全綠，證明 Requirement "Only deliberate interactions reinforce" 的新 scenario 與擴散機制沒有矛盾。
- [x] 2.6 內容審查：確認 `openspec/specs/memory-events/spec.md` 本次 delta 的三條新 scenario（co-presented 拿到擴散、dismissed 不拿擴散、oversized group 不擴散）與上述 2.1–2.5 的測試逐一對應，不需要再修改 delta spec。

## 3. `ComparisonScorer` treats an unmatched presentation as a legal skip（Decision 3: `ComparisonScorer` treats unmatched non-nil `presentation` as a legal skip）

- [x] 3.1 RED：實作 Requirement "An event is either scored, legitimately skipped, or rejected" 修訂後的第三種合法略過情形——在 `Tests/LTMEvalTests/ComparisonReportTests.swift` 新增測試：構造一個 `presentation` 非 nil、但其 ID 不在 `ComparisonReport` 供給的 `records` 裡的事件，斷言 `report(events:)` 不拋錯、且該事件被計入合法略過的計數——先確認目前程式碼下會拋 `ComparisonDataError.unknownPresentationReference`（測試為紅）。
- [x] 3.2 GREEN：`Sources/LTMEval/ComparisonReport.swift:238` 的 `guard let record = byID[presentationID] else { throw ... }` 改為合法略過（計入既有或新增的計數器），只有 record 存在但 anchor 不在其歸屬裡或 generation 不符時才維持拋錯。3.1 轉綠，且既有 `ComparisonReportTests.swift` 全部測試（含 "An event naming an unknown presentation is rejected" 對應的既有測試,若存在需同步更新為「合法略過」的斷言）維持通過或按新語意更新。
- [x] 3.3 GREEN：確認 `Legitimate skips are counted` 對應的既有測試（若存在）更新為涵蓋三種合法略過原因（無 presentation／null comparison／presentation 不在 records 裡），驗證：`swift test --filter ComparisonReportTests` 全綠。

## 4. Expose `presentation` in `ltm query --json`（Decision 6: Expose `presentation` in `ltm query --json`）

- [x] 4.1 RED：實作 Requirement "ltm query prints pointered hits in human and JSON forms" 修訂後新增的 `presentation` 欄位——在 `Tests/LTMServiceTests/CLICommandTests.swift`（或既有涵蓋 `printJSON` 的測試檔）新增測試：`recordEvents: true` 且事件成功寫入時，`--json` 輸出的每個物件含 `presentation` 欄位（字串、非空）；`recordEvents: false` 時輸出物件不含該欄位——先確認在目前程式碼下前半段斷言為紅（`presentation` 欄位不存在）。
- [x] 4.2 GREEN：`Sources/ltm/Commands.swift` 的 `printJSON(_:)` 依 `hit.presentation` 是否非 nil 決定要不要加入 `"presentation": hit.presentation!.description` 欄位。4.1 轉綠。

## 5. Archive errata（Decision 5: Archive errata as an append-only note）

- [x] 5.1 在 `openspec/changes/archive/2026-08-19-add-spreading-activation/design.md` 檔案末尾附加一段「## Errata (added by add-spreading-activation-fixes, 2026-08-19)」，更正「spreadingActivationFactor 參數沿用 AI4o」的宣稱，指回 `Projection.swift` 程式碼註解與本次 change 的 proposal；驗證：內容審查，確認原有內容一字未刪、新段落可辨識地附加在檔案結尾。
- [x] 5.2 在 `openspec/changes/archive/2026-08-19-add-spreading-activation/proposal.md` 做相同的附加；驗證：同 5.1。

## 6. Housekeeping

- [x] 6.1 `CHANGELOG.md` 新增本次改動的條目；驗證：內容審查，條目描述涵蓋 Decision 1–6 的行為變更摘要。
- [x] 6.2 全量驗證：`swift build` 無錯誤、`swift test` 全綠（涵蓋 `LTMMemoryTests`、`LTMQueryTests`、`LTMServiceTests`、`LTMEvalTests` 四個 target）；驗證：終端機輸出貼在本次 apply 的 session 記錄中確認。
