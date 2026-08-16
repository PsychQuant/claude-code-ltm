// LTMQuery — 檢索候選與唯一的記憶 seam。
//
// MemoryStrategy 是「使用歷史影響排序」的**約定**唯一入口。兩個方向的約束
// 各自有不同的強度，這裡分開講清楚，因為先前把兩者都寫成「型別擋住」是
// 過度宣稱（#1 verify 2026-08-11，devils-advocate 實測推翻）：
//
// - **策略讀不到語料** —— 部分由型別保證：`rerank` 的簽章只收候選與
//   projection，沒有 CorpusReader。但 `CorpusReader` 與 `Anchor.dereference`
//   都是 LTMCore 的 public API，策略側自己實作一個 reader 仍能把 anchor 還原
//   成原文。DA 實測做到了。
//
// - **retrieval 讀不到事件存放** —— 只是依賴宣告上的慣例：本模組不依賴
//   LTMMemory，所以看不到 `FileEventStore`；但 JSON Lines 格式與
//   `Event: Codable` 住在 LTMCore，用 Foundation 直接讀檔即可繞過。
//
// 兩條 spec requirement（"Retrieval SHALL NOT read the event store directly,
// and no strategy SHALL read the corpus directly"）目前**沒有執行點**。要讓它們
// 成為事實，`Event` 的編碼表示需要移出 LTMCore。追蹤於 follow-up issue；
// 在那之前，這裡寫的是實情而不是願望。
