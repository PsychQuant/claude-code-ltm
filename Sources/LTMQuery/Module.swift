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
// **「目前沒有執行點」是錯的**，而這裡先前正是那樣寫的。那兩條 spec requirement
// （"Retrieval SHALL NOT read the event store directly, and no strategy SHALL read
// the corpus directly"）想保護的東西**各自都有執行點，只是都不在那句話宣稱的地方**：
//
// - **排序正確性** → seam 的**七道檢查**，每次呼叫都跑。一個偷讀語料的策略仍然
//   交不出這七道接受的輸出，除非那個輸出本來就是合法的重排。
// - **隱私邊界** → **落地的 bytes**：canonical store 的 round-trip 比對。策略讀了
//   什麼不是危害，語料原文**寫進**記憶層的檔案才是，而那在寫入時被擋。
//
// 七道檢查與它們各自的違規逐一列在 `memory-strategy` spec 的
// 「MemoryStrategy is the sole seam between retrieval and memory」requirement。
// **理由只寫在那裡一份**，這裡不重述。
//
// 而「移出 LTMCore 就會成真」同樣是錯的：那只拿掉便利型別，`Data(contentsOf:)`
// 加 `JSONSerialization` 仍可繞過——**推翻原宣稱的那兩個測試都沒有用到要被移走的
// 型別**。依賴圖控制 API 可及性，不控制 capability。
