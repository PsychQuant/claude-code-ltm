import Testing

// 這個 target 的依賴刻意**不含** LTMMemory（見 Package.swift）。所以連測試
// 都無法從 LTMQuery 這一側碰到 `EventStore`——把守衛放在依賴宣告上，比放在
// 註解裡可靠。
@testable import LTMCore
@testable import LTMQuery
