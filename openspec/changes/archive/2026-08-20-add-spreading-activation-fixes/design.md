## Context

`add-spreading-activation`（#15）已實作並歸檔（`openspec/changes/archive/2026-08-19-add-spreading-activation/`）。`/idd-verify #15`（6-AI ensemble：4 lens 完成、Devil's Advocate 因執行環境睡眠中斷未完成）回報 `verdict: FINDINGS`，37 筆原始 findings 去重後是 6 個獨立缺陷，其中 1 個 CRITICAL、5 個 HIGH。這份 design 記錄修這些缺陷的技術決策，是本次 `spectra-discuss` 收斂的正式落地。

擴散機制目前活在共用的 `project(_:at:resolvedBy:parameters:)`（`Sources/LTMMemory/Projection.swift`）：每筆 `opened`/`cited`/`pinned` 事件的（已衰減）貢獻，乘上 `parameters.spreadingActivationFactor`，分給同框呈現（`event.presentation` 相同）裡其他存活的 anchor——即使那些 anchor 自己完全沒有直接互動紀錄。這與 `memory-events` spec 既有 Requirement「Only deliberate interactions reinforce」的逐字 scenario（二十筆 `shown` 事件的統計應等同零事件的 anchor）產生衝突；擴散又因為裝在共用函式而滲透到 `conservative` 策略；`LTMService.query()` 為此對每次記錄查詢配發 `PresentationID`，而 `ComparisonReport.swift` 的 `ComparisonScorer` 把「presentation 非 nil」當成「這筆屬於一次正式比較實驗」的證據，在找不到對應 `PresentationRecord` 時直接拋錯——生產查詢因此系統性地讓比較路徑失敗。

## Goals / Non-Goals

**Goals:**

- 讓擴散機制與 `memory-events` spec 的既有保證在文字上一致，不是靠實作悄悄違反它。
- 把擴散的作用範圍收斂回 spec 原本只授權的 human-like，且不新增與 `project()` 平行的第二份摺疊邏輯。
- 讓 `ComparisonScorer` 能正確處理「presentation 非 nil 但不屬於本次比較」這個 #15 引入的新的合法情境，同時誠實記錄因此接受的偵測力損失。
- 修正歸檔文件裡不成立的 AI4o 出處宣稱。
- 補上一條會在擴散違反其宣稱性質時真的變紅的回歸測試。

**Non-Goals:**

- 不重構 `PresentationID` 成雙命名空間（分離「擴散分組」與「比較實驗歸屬」兩種身分）。
- 不校準 `spreadingActivationFactor` 的預設值 0.3。
- 不改動 CLI JSON 輸出的整體格式（`{ "hits": [...], "diagnostics": {...} }` 那個既有已知缺口留給 #24 Stage 2）。

## Decisions

### Decision 1: Document spreading as a documented exception in `memory-events`, not a violation

`memory-events` spec 的「Only deliberate interactions reinforce」Requirement 保留不動，另外新增一條擴散專屬的新 scenario，明確記錄：在同一次呈現（presentation）群組裡，只要群組內有任一 anchor 收到 `opened`/`cited`/`pinned` 事件，群組內其他存活、未被使用者明確 dismissed 的 anchor，即使自己只有 `shown` 事件（或完全沒有事件），也可能因擴散拿到非零 reinforcement。

> **修正（2026-08-20，fix-round-3）**：上一句原本接著寫「且這個非零值嚴格小於直接互動本身會產生的 reinforcement（透過 `spreadingActivationFactor < 1` 保證，見既有 `precondition`）」——**這句話當時是假的**：那個 precondition 直到 fix-round-2（commit `0f0dfdf`）才補上，"見既有" 的措辭卻宣稱它原本就在。這是與 fix #4（AI4o 出處假宣稱）同一類缺陷，在同一份文件裡發生。且即使 precondition 已補上，它保證的只是**逐筆**貢獻嚴格小於其衍生自的那筆直接互動貢獻，不是一個 anchor 的**總**擴散量有上限——這條較弱的保證還可以被合法的 `openedWeight`/`citedWeight`/`pinnedWeight: 0` 推翻（直接貢獻本身為 0 時，`0 < 0` 不成立）。完整、誠實的措辭見 `openspec/specs/memory-events/spec.md` 的對應 Requirement（fix-round-3 已收斂）。

**替代方案考慮過**：narrow 機制本身（Definition B：擴散只調整「兩者皆已有直接互動」的 anchor 之間的相對強度），讓舊 Requirement 完全不用動。**未採用**——這會推翻使用者在 #15 spectra-discuss 明確選過的 Definition A（同框呈現即使自己未被開啟也拿到擴散加分），且會讓擴散這個機制的實際效果大幅弱化（只在「多筆都被直接互動」的窄情境下才有作用，違背擴散激發本身要模擬的「聯想促發」語意，見 `ltm-analogy.md` 的類比判準）。

### Decision 2: Gate spreading per-strategy via `ProjectionParameters.spreadingActivationFactor`, not a new module

不把擴散邏輯抽出 `project()`。改為讓 `MemoryStrategy` protocol 新增一個能力宣告（例如 `var appliesSpreadingActivation: Bool { get }`，透過 protocol extension 預設 `false`，只有 `HumanLikeStrategy` 覆寫為 `true`），`LTMService.makeProjection` 依這個宣告決定要不要把非零的 `spreadingActivationFactor` 傳進 `ProjectionParameters`——不適用擴散的策略一律傳 `0`（沿用 `Projection.swift` 現有文件語意「0 等於關閉擴散」）。

**替代方案考慮過**：把擴散邏輯整段抽成獨立檔案／模組，只由 human-like 呼叫。**未採用**——CLAUDE.md 已記錄的教訓「同一件事有兩個寫者，就是兩份會漂移的規格」直接適用：擴散依賴的 `presentationGroups`/`deliberateContributions` 蒐集邏輯與主迴圈共用同一份事件過濾（未來時間戳、orphan），拆成獨立模組要嘛重新過濾一次（違反上述教訓）、要嘛把 `project()` 拆成兩段可各自呼叫的函式（增加介面複雜度換不到實質好處）。`ProjectionParameters` 本來就是為「衍生層可調參數」設計的既有 seam，把它接上服務層是最小且最貼合既有架構的修法，副作用是同時補上 MEDIUM finding（服務層先前沒有任何路徑能設定這個值）。

**副作用**：`ConservativeStrategy` 先前（非預期地）因為與 human-like 共用 `consumedSignals` 而吃到擴散，本次之後不再吃到——這是修正，`memory-strategy` spec 需要一條新 Requirement 明訂擴散只授權 human-like。

### Decision 3: `ComparisonScorer` treats unmatched non-nil `presentation` as a legal skip

`ComparisonReport.swift:238` 現有的 `guard let record = byID[presentationID] else { throw ComparisonDataError.unknownPresentationReference(presentationID) }` 改為合法略過（併入 `skippedNotFromAPresentation` 計數,或另開一個獨立計數器如 `skippedPresentationNotTracked`,擇一在實作時依既有計數命名慣例決定）——只有當 `byID[presentationID]` 確實找到record、但 `record.generation` 與事件自報的 generation 不符，或 anchor 不在該次呈現裡，才視為真正的資料不一致而拋錯（這兩條既有的拒絕路徑不動）。

**接受的取捨**：`PresentationID` 是 `UUID` backed 的隨機值（`PresentationID.random()`），一般生產查詢與比較實驗撞號的機率趨近於零。所以在實務上，「presentation 非 nil 但查無 record」幾乎必然代表「這筆本來就不屬於任何比較實驗」，而不是「這次實驗的 record 因某種內部錯誤遺失」。本次修法**不再區分**這兩種情況——都視為合法略過。這代表：若 comparison harness 未來真的發生「產生了 presentation ID、寫了帶該 ID 的事件，卻沒能持久化對應 `PresentationRecord`」這種內部一致性錯誤，這個錯誤不會再被 `ComparisonScorer` 偵測到。

**替代方案考慮過**：把 `PresentationID` 拆成兩個命名空間（擴散專用 vs. 比較實驗專用），讓 `ComparisonScorer` 只對「比較實驗命名空間」的 ID 強制要求 record 存在。**未採用**（列在 proposal 的 Non-Goals）——這是結構上唯一能保留完整偵測力的做法，但需要貫穿 `Event`／`LTMService.query()`／comparison harness 三處的介面變更，遠超本次修復範圍；且目前沒有任何已知事故顯示這個偵測力損失有實際代價。若未來出現這類事故，屆時再開新 change 處理。

**替代方案考慮過（次要）**：讓 `LTMService.query()` 收窄 `PresentationID` 配發範圍，只在真正的比較實驗查詢才配。**未採用**——擴散機制（Decision 1、2）依賴每次查詢都配發 `PresentationID` 才能分辨同框群組，收窄配發範圍會讓擴散在一般生產查詢下完全失效，等於砍掉 #15 的核心功能。

### Decision 4: Exclude dismissed anchors as spread targets, and cap presentation-group size

`Projection.swift` 的擴散迴圈（`for entry in deliberateContributions { ... for other in members ... }`）新增兩個條件：

1. **排除已被明確 dismissed 的目標**：若 `other` 這個 anchor 在同一份事件序列裡有 `.dismissed` 事件，擴散不對它生效——使用者的明確負面訊號不該被同框的正面訊號部分抵銷。**修正（2026-08-20，fix-round-3）**：上一句原本接著寫「即 `suppression[other]` 非零」，把「事件是否存在」與「抑制量數值是否非零」宣告為等價——這個等價不成立（`dismissedWeight: 0` 是合法參數值，此時 `suppression` 恆為 0，但 dismissed 事件確實存在），fix-round-2 已把實作改成獨立追蹤事件存在性（`dismissedAnchors: Set<Anchor>`），這裡把描述一併更正。
2. **同框群組大小上限**：`presentationGroups[group]` 的成員數超過一個防禦性門檻時，該群組整體跳過擴散（不對組內任何 anchor 套用），視為異常大小、可能是竄改或非典型使用模式的訊號，而非無界放大。**修正（2026-08-20，fix-round-3）**：門檻的值已從最初的建議值 50 調整為 2000（fix-round-2）——50 對齊的是「一般查詢 `limit` 參數的合理上界數倍」，但 `ltm query --k` 有文件支援的上限是 1000，50 比它低了 20 倍，任何用到 `--k` 中段以上的正常查詢都會在合規使用下靜默關掉整組擴散。2000 高於文件支援上限，讓這個上限只防禦超出 CLI 能產生範圍的群組。

**替代方案考慮過**：對擴散總量做動態正規化（例如依組大小反比縮放 `spreadingActivationFactor`）。**未採用**——會讓「單一 anchor 收到的擴散量」不再只依賴自己的鄰居狀態，而依賴整個群組大小這個間接、難以在 `RankingReason.History` 裡誠實描述的量，違反 `MemoryStrategy.swift` 已經記錄的「provenance 不得說謊」紀律；門檻式跳過（skip）比連續縮放更容易誠實描述在 provenance 裡（不套用就是不套用，不需要解釋一個縮放係數）。

### Decision 5: Archive errata as an append-only note

在 `openspec/changes/archive/2026-08-19-add-spreading-activation/design.md` 與 `proposal.md` 各自的檔案末尾，附加一段標題為「## Errata (added by add-spreading-activation-fixes, 2026-08-19)」的區塊，內容更正「`spreadingActivationFactor` 參數沿用 AI4o」這句不成立的宣稱，指回 `Projection.swift` 程式碼註解的誠實記錄與本次 change 的 proposal。不刪除、不改寫既有內容——歸檔文件是既成事實的歷史記錄。

### Decision 6: Expose `presentation` in `ltm query --json`

`Sources/ltm/Commands.swift` 的 `printJSON(_:)` 在建構每個 hit 物件時，若 `hit.presentation` 非 nil，加入 `"presentation": hit.presentation!.description`（`PresentationID` 已 conform `CustomStringConvertible`）。比照既有 `displacement`/`history`/`movement` 只在有意義時才附加欄位的慣例（archival 策略不附加位移相關欄位；本欄位則是「有記錄事件」才附加，與策略無關）。

### Decision 7: New regression test for co-presented shown-only anchors

`Tests/LTMMemoryTests/ProjectionTests.swift` 新增測試 `coPresentedShownOnlyAnchorsProduceNoReinforcementWithoutADeliberateEventInTheGroup`：建構一個同框呈現群組，群組內所有事件皆為 `.shown`（使用 #15 那批擴散測試已引入的、會設定 `presentation` 的 event helper），斷言群組內每個 anchor 的 reinforcement 皆為 0。此測試與 Decision 1 的新 spec scenario 是同一件事的兩種記錄方式：spec scenario 描述「圍籬在哪裡」（有直接互動的存在與否），這條測試驗證「圍籬真的守住」。

## Implementation Contract

**行為**：
- `human-like` 策略的排序結果：同框呈現群組內的擴散行為**完全依 `openspec/specs/memory-events/spec.md` 的「Only deliberate interactions reinforce」Requirement 為準，本契約不重述任何條件**（2026-08-21 fix-round-4 修正：本行原本寫「若組內有任一 anchor 被 `opened`/`cited`/`pinned`，其餘存活、未被 dismissed 的組員的 `netStrength` 會反映一個非零但嚴格小於直接互動貢獻的增量」——那是無條件宣稱，缺了 `spreadingActivationFactor > 0`、來源權重須為正、群組大小上限、來源事件須帶 presentation 識別碼四個閘門，而它以「實作契約」身分出現、比 spec prose 更接近驗收條件。重述條件正是 #15 反覆漂移的根因，所以改成單向指過去）。
- `conservative` 與 `archival` 策略的排序結果：與擴散無關，不因同框呈現而改變（`conservative` 相對於本次修復前的行為是**變更**：先前意外吃到的擴散消失）。
- `ltm query --json` 的每個 hit 物件：`recordEvents=true` 且成功寫入事件時，物件多一個 `"presentation"` 字串欄位（UUID 字面量）；`recordEvents=false` 或事件寫入被跳過時該欄位不存在。
- `ComparisonReport.report(events:)`：`presentation` 非 nil 但無對應 `PresentationRecord` 的事件不再拋 `ComparisonDataError.unknownPresentationReference`，改為計入合法略過的計數，其餘行為（`generationMismatch`／`anchorNotInPresentation` 仍拋錯）不變。

**介面 / 資料形狀**：
- `MemoryStrategy` protocol 新增一個 `Bool` 型別的能力宣告 requirement（表達「這個策略要不要套用擴散」），`HumanLikeStrategy` 回傳 `true`，`ConservativeStrategy`／`ArchivalStrategy` 回傳 `false`（透過 protocol extension 給預設值,避免既有 conformer 因新增 requirement 而編譯失敗）。
- `LTMService.makeProjection` 依該宣告組出對應的 `ProjectionParameters`（而非永遠使用 `.default`）。
- `ltm query --json` 輸出陣列的每個物件，新增可選欄位 `presentation: String`。

**失敗模式**：
- 同框群組大小超過上限：靜默跳過該群組的擴散（不拋錯、不記錄事件層級的診斷——這是排序層的內部決策，不是使用者需要被告知的錯誤；若之後證實需要能見度，可在 `RankingReason` 或別處另開一條記錄，屬未來工作）。
- `ComparisonScorer` 找不到 record：計入合法略過計數（不拋錯），與現有 `skippedNotFromAPresentation`／`skippedNullComparison` 同一類別。

**驗收條件**：
- `swift test` 全綠，且 Decision 7 的新測試、既有 `impressionsAloneProduceNoReinforcement`、既有全部擴散測試（`ProjectionTests.swift` 的「擴散激發」段落）、`LTMServiceTests.swift` 的呈現識別碼測試、`ComparisonReportTests.swift` 的既有測試全部通過。
- 新增一條 `ComparisonReportTests.swift` 測試：presentation 非 nil、byID 查無對應 record 的事件，`report()` 不拋錯且該事件計入略過計數。
- 手動或測試驗證：`ltm query --json --record` 的輸出含 `presentation` 欄位；`ltm query --json`（不 `--record`）的輸出不含該欄位。
- `openspec/changes/archive/2026-08-19-add-spreading-activation/{design,proposal}.md` 各自含一段可辨識的「## Errata」區塊。

**範圍邊界**：
- 範圍內：上述四個檔案的行為修改、兩個歸檔文件的 errata 附加、對應測試、`memory-events`／`memory-strategy`／`strategy-comparison`／`ltm-cli` 四份 delta spec、CHANGELOG 條目。
- 範圍外：`PresentationID` 雙命名空間重構、`spreadingActivationFactor` 數值校準、CLI JSON 整體格式改版——三者皆已列在 proposal 的 Non-Goals。

## Risks / Trade-offs

- **[Risk]** Decision 3 接受的偵測力損失（見上）→ **Mitigation**：在 `strategy-comparison` 的 delta spec 與 `ComparisonReport.swift` 的程式碼註解都明確記錄這個取捨,讓未來的維護者知道這是刻意決定,不是遺漏。
- **[Risk]** `conservative` 行為變更（不再吃到擴散）可能讓依賴舊行為（即使是非預期的）的下游比較實驗結果不可比 → **Mitigation**：這是修正一個未經 spec 授權的滲透,不是引入新行為;`docs/memory-systems/` 若有引用 conservative 排序特性的既有文字,一併檢查是否需要更新（不在本次 Impact 清單但屬於實作時的合理連帶檢查）。
- **[Risk]** 同框群組大小上限（Decision 4）的常數是本次自選、未經校準 → **Mitigation**：比照 `spreadingActivationFactor` 既有的誠實記錄慣例,在程式碼註解裡明確標記「防禦性上限,非校準值」,不宣稱它是最佳門檻。上限本身已從最初的 50 調整為 2000（2026-08-20 補：50 比 `ltm query --k` 有文件支援的上限 1000 低了 20 倍,任何用到 `--k` 中段以上的正常查詢都會在合規使用下靜默關掉整組擴散——2000 高於文件支援上限,讓這個上限只防禦超出 CLI 能產生範圍的群組）。
- **[Risk，2026-08-20 新增，fix-round-2 verify finding]** `appliesSpreadingActivation` 的閘門只裝在 `LTMService.makeProjection`——單策略查詢路徑。`LTMEval.InterleavingHarness.present(query:candidates:projection:a:b:startingSide:)`（A/B 比較 harness）對兩個被比較的策略共用**同一個** `Projection` 物件（`memory-strategy` spec 既有 Requirement「兩臂共用同一個 projection」要求如此），所以這條路徑結構上繞過了 human-like 專屬閘門：若拿來比較 `human-like` 與 `conservative` 的那個共用 projection 帶了非零 `spreadingActivationFactor`，`conservative` 那一臂也會吃到擴散貢獻。→ **Mitigation（部分，非完整修復）**：這是已知限制而非新引入的缺陷——`Sources/` 目前沒有任何生產呼叫端使用 `InterleavingHarness.present`，只有測試呼叫它，所以這條路徑目前是潛伏而非即時生效。完整修法需要重新設計比較 harness 的介面（讓兩臂能各自帶不同的 spreading 設定，或明確定義「比較擴散開/關兩種條件」的語意），這是架構層決定，超出本次修復範圍，留給 #16（評估指標基礎設施）真正啟用這條路徑時再處理——**在那之前，任何用這條路徑比較 human-like／conservative 的結果都不能假設擴散已被正確隔離**。
