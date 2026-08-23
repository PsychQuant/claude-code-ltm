import Foundation
import LTMCore
import LTMQuery

/// 由策略識別碼組出策略實例。
///
/// ## 為什麼在服務層，不在 CLI
///
/// 這個對照表先前只活在 CLI 的 `CommandSupport.strategy(named:)`。那在只有
/// `--strategy` 時沒有問題——一個介面，一份表。但比較模式要用**兩個**策略，
/// 而比較模式住在服務層（見 `wire-evaluation-machinery` 的 Decision
/// 「Comparison mode lives in the service layer, not the CLI」）：服務層若拿不到
/// 這張表，就只能收現成的實例，於是「策略由誰組出來」的答案變成兩個
/// （CLI 一個、未來的 MCP 一個），而新增一檔策略要記得改兩處。
///
/// 現在服務層收的是**識別碼**，實例由這裡產生。CLI 只轉述使用者打的字。
///
/// ## 為什麼不是 protocol 或註冊機制
///
/// 三檔策略是封閉集合，而且新增一檔要動 spec。一個 `switch` 讓「有哪些策略」
/// 在一個地方讀得完；註冊機制會讓它散開，換來的可擴充性目前沒有需求。
public enum StrategyRegistry {
    /// 目前可用的策略識別碼，供錯誤訊息列舉。
    public static let known = ["archival", "human-like", "conservative"]

    /// 由識別碼組出策略。未知識別碼回 `nil`——**不回一個預設值**：靜默改用
    /// archival 會讓一個打錯的名字看起來像成功執行了使用者要的策略。
    public static func make(_ id: RankingPolicyID) -> (any MemoryStrategy)? {
        switch id.value {
        case "archival": return ArchivalStrategy()
        case "human-like": return HumanLikeStrategy()
        case "conservative": return ConservativeStrategy()
        default: return nil
        }
    }
}
