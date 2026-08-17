// swift-tools-version: 6.0
import PackageDescription

// 依賴方向是單向的，且刻意如此：LTMCore 什麼都不依賴，所以 anchor／event
// 這兩個 canonical 值型別不可能反過來依賴索引或策略。
//
// **但依賴圖擋不住「retrieval 繞過 seam 讀事件」**——見下方 LTMQuery 那條的
// 誠實邊界。這個檔頭先前寫的是「在這個圖裡是編譯錯誤，不是紀律問題」，那句話
// 已被實測推翻（#1 verify R1），而 R1 的更正只改了下面的 target 註解、漏了這裡，
// 於是同一個檔案自相矛盾（R2 的 logic 與 regression 兩個 lens 各自指出）。
// **依賴圖的執行點就在下面這份宣告，沒有別的地方。**
//
// 先前每個測試 target 各有一個 `ModuleGraphTests.swift`，內容只有 import 與
// 註解，其中一份宣稱「這些 import 本身就是斷言：若模組依賴圖被改壞，這個檔案
// 會編譯失敗」。不成立（#1 verify R5）：反向依賴 LTMCore 會在套件解析／建置時
// 失敗，與那個檔案無關；import 兩個 target 本來就依賴的模組，斷言不了任何
// `swift build` 沒做的事。唯一可能載重的那份（LTMQuery 不得看到 LTMMemory）
// 從未嘗試那個 import，所以同樣什麼都沒斷言。三份已刪除，理由留在這裡。
//
// Swift 沒有「斷言某個 import 會失敗」的機制，所以這條約束的執行點只能是
// 下面的 `dependencies:` 清單本身——它是編譯期強制的，只是強制它的是 SwiftPM
// 而不是一個測試檔。
let package = Package(
    name: "claude-LTM",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LTMCore", targets: ["LTMCore"]),
        .library(name: "LTMMemory", targets: ["LTMMemory"]),
        .library(name: "LTMQuery", targets: ["LTMQuery"]),
        .library(name: "LTMEval", targets: ["LTMEval"]),
        .library(name: "LTMIndex", targets: ["LTMIndex"]),
        .library(name: "LTMService", targets: ["LTMService"]),
        .executable(name: "ltm", targets: ["ltm"]),
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
        // 索引層：語料掃描、chunk、FTS5 + 向量。只依賴 LTMCore 的值型別
        // （`Turn` / `Anchor` / `CorpusReader`），看不到策略也看不到事件儲存。
        //
        // 依賴清單刻意只有 LTMCore：索引不得因為「順手」而讀使用歷史——那會讓
        // 不變式 2（索引是純衍生物）在型別層失去依據。系統庫（SQLite3、
        // NaturalLanguage、Accelerate）由平台提供，不是套件依賴。
        .target(name: "LTMIndex", dependencies: ["LTMCore"]),
        // Facade：唯一同時看得到索引、策略與事件儲存的地方。CLI 與（Stage 2 的）
        // MCP 都只是它的薄 adapter——邏輯寫進 adapter 就是缺陷，因為那會讓兩個
        // 介面的行為漂移，而不變式測試只蓋得到其中一邊。
        .target(name: "LTMService", dependencies: ["LTMCore", "LTMIndex", "LTMQuery", "LTMMemory"]),
        // CLI。**不引入 swift-argument-parser**：零第三方依賴是隱私邊界的一部分
        // （每一個依賴都是一條需要自己審的供應鏈），手寫解析的成本遠低於那個代價。
        .executableTarget(name: "ltm", dependencies: ["LTMService", "LTMCore"]),
        .testTarget(name: "LTMMemoryTests", dependencies: ["LTMCore", "LTMMemory"]),
        .testTarget(name: "LTMQueryTests", dependencies: ["LTMCore", "LTMQuery"]),
        .testTarget(name: "LTMEvalTests", dependencies: ["LTMCore", "LTMMemory", "LTMQuery", "LTMEval"]),
        .testTarget(name: "LTMIndexTests", dependencies: ["LTMCore", "LTMIndex"]),
        .testTarget(
            name: "LTMServiceTests",
            dependencies: ["LTMCore", "LTMIndex", "LTMService", "LTMQuery", "LTMMemory", "ltm"]),
    ]
)
