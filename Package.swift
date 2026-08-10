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
        // LTMQuery 刻意**不**依賴 LTMMemory。策略拿的是 LTMCore 裡的
        // `Projection` 值型別，看不到 `EventStore`——於是「retrieval 不得直接
        // 讀事件存放」是編譯期事實，不是靠 code review 記得。
        .target(name: "LTMQuery", dependencies: ["LTMCore"]),
        .target(name: "LTMEval", dependencies: ["LTMCore", "LTMMemory", "LTMQuery"]),
        .testTarget(name: "LTMMemoryTests", dependencies: ["LTMCore", "LTMMemory"]),
        .testTarget(name: "LTMQueryTests", dependencies: ["LTMCore", "LTMQuery"]),
        .testTarget(name: "LTMEvalTests", dependencies: ["LTMCore", "LTMMemory", "LTMQuery", "LTMEval"]),
    ]
)
