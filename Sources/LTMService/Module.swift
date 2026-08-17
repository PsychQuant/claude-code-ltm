// LTMService — 唯一同時看得到索引、策略與事件儲存的地方。
//
// CLI 與（Stage 2 的）MCP server 都是它的薄 adapter：adapter 只翻譯輸入輸出，
// 契約住在這裡。判準是刪除測試——刪掉 facade，每個介面都斷；刪掉一個 adapter，
// 只少一個介面。邏輯若寫進 adapter，兩個介面的行為會漂移，而不變式測試只蓋
// 得到其中一邊。
//
// facade 擁有四件事：staleness 政策（prefix hash 對得上就續讀；embedding
// revision 不符就**拒答**）、檢索、經 seam 的策略套用、以及事件發射。
//
// 拒答而非降級是刻意的：跨 revision 的 cosine 不會報錯，只會安靜地給出無意義
// 的距離。一個警告旁邊擺著看起來合理的結果，不會阻止那些結果被採用。
