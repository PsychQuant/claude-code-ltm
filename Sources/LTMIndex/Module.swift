// LTMIndex — 語料掃描、chunk 切分、與衍生索引。
//
// 這一層產生 `Candidate` 的來源資料。在本 change 之前，seam 的輸入端是空的：
// `MemoryStrategy` 收候選，但樹裡沒有任何東西造得出候選——檢索只活在
// `scripts/probe-tokenizer.swift` 這個量測 spike 與 `docs/measurements/` 的紀錄裡。
//
// 兩條不變式在這一層是**執行點**而不是慣例：
//
// - **語料唯讀**（不變式 1）：所有讀取路徑走 `CorpusLocation` 的 inode 身分檢查；
//   任何解析成語料根底下的輸出路徑在寫入前失敗。
// - **索引是純衍生物**（不變式 2）：這裡不存任何無法從語料 + 建置設定重算的東西。
//   `rm -rf ~/.claude-ltm/derived && ltm build` 的等價性是測試，不是文件。
//
// chunk 粒度是**一則 turn**。anchor 仍然內容定址（見 `LTMCore.Anchor`），所以
// 日後改成 sub-turn 切分不會讓既有的使用歷史變成孤兒——那正是 anchor 不用
// chunk id 的理由。
