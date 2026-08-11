// swift-tools-version: 6.0
import PackageDescription

// 依賴方向是單向的，且刻意如此：LTMQuery 拿得到 LTMMemory 的 projection，
// 但 LTMCore 什麼都不依賴，所以 anchor／event 這兩個 canonical 值型別
// 不可能反過來依賴索引或策略。retrieval 繞過 MemoryStrategy 直接讀事件
// 在這個圖裡是編譯錯誤，不是紀律問題。
let package = Package(
    name: "claude-LTM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LTMCore", targets: ["LTMCore"]),
        .library(name: "LTMMemory", targets: ["LTMMemory"]),
        .library(name: "LTMQuery", targets: ["LTMQuery"]),
        .library(name: "LTMEval", targets: ["LTMEval"]),
    ],
    targets: [
        .target(name: "LTMCore"),
        .target(name: "LTMMemory", dependencies: ["LTMCore"]),
        // LTMQuery 刻意不依賴 LTMMemory：策略拿的是 LTMCore 裡的 `Projection`
        // 值型別，看不到 `FileEventStore`。
        //
        // **誠實邊界（#1 verify 2026-08-11，devils-advocate 實測推翻原宣稱）**：
        // 這條依賴宣告擋住的只是那個**便利型別**。JSON Lines 的格式與
        // `Event: Codable` 都住在 LTMCore，所以 LTMQuery 用 Foundation 就能把
        // canonical 事件檔整份讀回來——DA 加了一個沒有 import LTMMemory 的測試，
        // 通過了。原本各處寫的「編譯期事實」是**過度宣稱**，已全數降級為
        // 「依賴宣告上的慣例」。
        //
        // 要讓那個宣稱成真，`Event` 的編碼表示必須移出 LTMCore（或改為
        // LTMMemory-internal）。那是獨立的重構，追蹤於 follow-up issue。
        .target(name: "LTMQuery", dependencies: ["LTMCore"]),
        .target(name: "LTMEval", dependencies: ["LTMCore", "LTMMemory", "LTMQuery"]),
        .testTarget(name: "LTMMemoryTests", dependencies: ["LTMCore", "LTMMemory"]),
        .testTarget(name: "LTMQueryTests", dependencies: ["LTMCore", "LTMQuery"]),
        .testTarget(name: "LTMEvalTests", dependencies: ["LTMCore", "LTMMemory", "LTMQuery", "LTMEval"]),
    ]
)
