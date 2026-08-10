import Testing

// 這些 import 本身就是斷言：若模組依賴圖被改壞（例如有人讓 LTMCore 反向
// 依賴上層），這個檔案會編譯失敗，`swift test` 隨之失敗。實際的行為測試由
// 後續 task 加進本 target。
@testable import LTMCore
@testable import LTMMemory
