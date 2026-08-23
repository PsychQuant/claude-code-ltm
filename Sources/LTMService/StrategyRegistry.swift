import Foundation
import LTMCore
import LTMQuery

/// `StrategyRegistry` 已搬到 `LTMQuery`（見
/// `Sources/LTMQuery/StrategyAuthority.swift`）。這裡只 re-export。
///
/// ## 為什麼搬
///
/// 它現在與**授權表**住在同一個檔案，而授權表必須被 seam
/// （`MemoryStrategy.rerank`）讀得到——seam 住 `LTMQuery`，且該模組的依賴刻意
/// 只有 `LTMCore`。往上取用會把依賴方向反過來。
///
/// 另一個選項是在 `LTMQuery` 另立一份授權表、把 registry 留在這裡，但那會讓
/// 「有哪些策略」有兩份定義，而下一個新增策略的人只會改他看著的那一份。
///
/// ## 為什麼留一個 typealias 而不是讓呼叫端改 import
///
/// `LTMService` 的呼叫端（本模組的 `compare`、CLI、測試）不需要知道這件事搬過家
/// ——它們要的是「由識別碼組出策略」，那個能力沒有變。留一行讓 diff 停在這裡。
public typealias StrategyRegistry = LTMQuery.StrategyRegistry
