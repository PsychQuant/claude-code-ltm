// LTMQuery — 檢索候選與唯一的記憶 seam。
//
// MemoryStrategy 是使用歷史能影響排序的唯一入口。兩個方向都由型別擋住：
//
// - 策略拿不到語料：rerank 的簽章只收候選與 projection，沒有 CorpusReader。
// - retrieval 拿不到事件存放：本模組不依賴 LTMMemory（見 Package.swift），
//   所以 `EventStore` 在這裡根本不是一個可見的型別。
