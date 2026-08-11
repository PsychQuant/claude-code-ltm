import Testing

// 這個 target 的依賴刻意不含 LTMMemory（見 Package.swift），所以碰不到
// `FileEventStore`。但這只是**依賴宣告上的慣例**，不是型別層的封鎖：
// `Event: Codable` 在 LTMCore，任何人用 Foundation 都能自行讀寫 canonical 檔。
// 詳見 Package.swift 的誠實邊界說明（#1 verify 2026-08-11）。
@testable import LTMCore
@testable import LTMQuery
