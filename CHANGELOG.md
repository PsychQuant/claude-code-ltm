# Changelog

本檔記錄非衍生性、對讀者有意義的變更（doc comment、API、架構）。純衍生物（索引、測試覆蓋率報告）不記。

## Unreleased

### Fixed
- 第四輪修復 `add-spreading-activation-fixes`（#15）：前三輪都是「發現複本 → 改掉那幾份」，這輪改用逐條 SHALL／scenario 稽核，對擴散機制的每一條規範句在 `memory-events`、`memory-strategy`（各含 main spec + archived delta spec）、`docs/memory-systems/README.md` 五個位置比對是否一致：
  - `memory-events` 的「gains reinforcement」scenario 仍斷言無條件「nonzero, strictly less than」，跟上一輪才收斂到 Requirement prose 的「來源貢獻須為正」條件不一致——scenario 補上同一個條件。
  - `memory-strategy` 的 Requirement 本體（`human-like` SHALL treat anchors...）先前完全沒被三輪改過，仍是無條件宣稱，且與 `memory-events` 已有的三個例外（正貢獻、dismissed 排除、群組上限）不一致。這次不是再抄一份條件過去（那正是前三輪一直重演的複本問題），而是把這條 Requirement 改成明確指向 `memory-events` 當唯一權威來源、自己不重述條件——減少未來還能漂移的複本數量。
  - `memory-strategy` 的對應 scenario 同樣補上來源貢獻須為正的條件。
  - `README.md` 這份被 round-2 CHANGELOG 明確點名的追蹤複本，round-3 的系統性掃描仍然漏掉了——這輪補上同一個條件。
  逐一核對後，main spec 與 archived delta spec 的對應 Requirement 區塊現在逐字相同（用 diff 確認，只有 `@trace` 區塊的差異，那是預期的）。(#15)
- 第三輪修復 `add-spreading-activation-fixes`（#15）：前一輪把「假宣稱／過時數字」修在某一處、忘了同一句話的其他複本，這輪對整個 repo 做系統性 grep 掃描，一次把所有複本改掉，而不是逐一頭痛醫頭：
  - `design.md:27` 的「透過 `spreadingActivationFactor < 1` 保證，見既有 precondition」——precondition 是上一輪才補的，這句話寫下的當時是假的，先前只改了 spec 沒改 design.md 本體；
  - `design.md` Decision 4 本文與 `Sources/LTMMemory/Projection.swift` 迴圈上方的程式碼註解仍寫著「50」，跟已改成 2000 的常數矛盾；
  - `design.md` Decision 4 與 `tasks.md` 2.2 仍把「`suppression` 數值非零」與「有 dismissed 事件」寫成等價——這個等價已被上一輪的修法本身證明不成立；
  - `LTMEval.Interleaving.present` 這個符號名是錯的，正確是 `InterleavingHarness.present`，四處文件複製了同一個錯誤引用。
  另外收斂了這輪修補動作自己新引入的兩個問題：memory-events spec 新加的「其他策略以 factor=0 投影」括號豁免範圍過寬（把整條 Requirement 都豁免掉，不只是擴散相關的三條 scenario）；收斂後的「逐筆嚴格小於」SHALL 仍可被合法的 `openedWeight`/`citedWeight`/`pinnedWeight: 0` 推翻——與這輪要修的 fix #4 同一類缺陷，在同一份文件的另一句重演，這次把前提條件（來源貢獻為正）寫進 SHALL 本身。也補上一條真正釘住 cap+1（2001）邊界的測試，並清掉舊測試裡沒整理乾淨的自我更正註解。(#15)
- 修正上一輪 `add-spreading-activation-fixes`（#15）修復本身留下的 6 個 `/idd-verify` 缺陷（第二輪 follow-up verify 發現，修法就地補在同一個 commit 基礎上，未開新 change）：
  (1) `memory-events` spec 的「Impressions alone produce no reinforcement」scenario
  文字本身沒有排除同框有擴散的情形——先前只在 prose 加了例外說明，scenario
  的 GIVEN/THEN 依然逐字被生產行為推翻；現在 scenario 本身帶上排除條件；
  (2) `spreadingActivationFactor < 1` 先前只在文件宣稱、沒有 precondition 執行
  ——與 fix #4 要修正的「假宣稱」同一類缺陷，現在補上 precondition，並把
  spec 的 SHALL 收斂成誠實的逐筆保證（不宣稱總量有上限）；
  (3) 同框群組大小上限從 50 調整為 2000——50 比 `ltm query --k` 支援上限
  （1000）低了 20 倍，正常查詢就會靜默關掉擴散；
  (4) dismissed anchor 排除擴散的判準從「suppression 數值是否非零」改為
  「dismissed 事件是否存在」——`dismissedWeight: 0` 是合法參數值，先前的數值
  判準在這種設定下會靜默失效；
  (5) 補齊 archived design.md 的 AI4o 出處 errata（先前只修了 Open Questions
  段落，Decisions 段落的同一個假宣稱漏了）；
  (6) `docs/memory-systems/README.md` 補上本輪修復的行為變更說明。
  另外把 `LTMEval.InterleavingHarness.present`（A/B 比較 harness）繞過 human-like
  專屬擴散閘門這件事記為已知限制（目前無生產呼叫端，潛伏而非即時生效，完整
  修復需要重新設計比較 harness 的 projection 共用契約，留待後續）。(#15)
- 修正 `add-spreading-activation`（#15）擴散機制的 6 個 `/idd-verify` 缺陷：
  (1) 擴散不再違反 `memory-events` spec 既有「Only deliberate interactions
  reinforce」保證——改為在 spec 裡明文記錄為已知例外，而不是安靜違反它；
  (2) 擴散收斂為 `human-like` 專屬，`MemoryStrategy` 新增
  `appliesSpreadingActivation` 能力宣告，`conservative` 不再意外吃到擴散；
  (3) `ComparisonScorer`（`ComparisonReport.swift`）新增第三種合法略過情形
  （`presentation` 非 nil 但查無對應 `PresentationRecord`），生產查詢不再
  系統性地讓比較路徑拋錯；(4) 擴散不再對已被使用者明確 `dismissed` 的
  anchor 生效，同框群組加防禦性大小上限，避免無界放大；(5) `ltm query --json`
  補上 `presentation` 欄位；(6) 已歸檔的 #15 design.md／proposal.md 補
  errata，更正不成立的 AI4o 出處宣稱。(#15，`add-spreading-activation-fixes`)
- doc comment 清掉指向已不存在 API 的引用：`EventStore.allEvents(skippingCorrupt:)` 已改名為
  `allEvents(skippingUnusable:)`，四處殘留舊名稱的引用（`Anchor.swift` / `CanonicalCoding.swift` /
  `EventStore.swift` ×2）已更新為現行名稱；三處刻意的歷史敘述（「先前的簽章是…」）保留不動。
  補回 `QueryOutcome`（被 `RefreshReport` 插在正上方而消失的）doc comment。修正
  `RetrievalEngineTests` 一則過時註解——「band 直接取用名次」正是 #24 拆掉的缺陷（band 現為命中
  通道數，不是名次）。(#24)
