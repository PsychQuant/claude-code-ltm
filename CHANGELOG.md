# Changelog

本檔記錄非衍生性、對讀者有意義的變更（doc comment、API、架構）。純衍生物（索引、測試覆蓋率報告）不記。

## Unreleased

### Fixed
- doc comment 清掉指向已不存在 API 的引用：`EventStore.allEvents(skippingCorrupt:)` 已改名為
  `allEvents(skippingUnusable:)`，四處殘留舊名稱的引用（`Anchor.swift` / `CanonicalCoding.swift` /
  `EventStore.swift` ×2）已更新為現行名稱；三處刻意的歷史敘述（「先前的簽章是…」）保留不動。
  補回 `QueryOutcome`（被 `RefreshReport` 插在正上方而消失的）doc comment。修正
  `RetrievalEngineTests` 一則過時註解——「band 直接取用名次」正是 #24 拆掉的缺陷（band 現為命中
  通道數，不是名次）。(#24)
