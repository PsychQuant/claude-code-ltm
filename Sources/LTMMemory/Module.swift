// LTMMemory — canonical 使用歷史：append-only 事件存放與其 projection。
//
// 這一層是「索引是純衍生物」這條不變式的唯一例外：jsonl 記不得使用歷史，
// 所以這裡的資料不可重建、必須備份。代價是它受一條獨立硬約束：
// 只存指標與統計，不存 chunk 原文、query 原文、note 原文。
