import Foundation
import LTMCore

/// 由策略識別碼組出策略實例，**以及**查出那個識別碼被授權做什麼。
///
/// ## 一個檔案回答兩件事，是刻意的
///
/// 「有哪些策略」與「每一檔被授權做什麼」若分兩處，下一個新增策略的人會改他
/// 當下看著的那一份，另一份就此落後——而落後的方向是**新策略沒有授權條目**，
/// 於是它要嘛被拒（好）、要嘛退回自報（壞，取決於實作）。兩份表就是兩份會漂移
/// 的規格，所以這裡只有一份。
///
/// ## 為什麼從 `LTMService` 搬到這裡
///
/// 授權表必須被 seam（`MemoryStrategy.rerank`）讀得到，而 seam 住在本模組；
/// 本模組的依賴刻意只有 `LTMCore`（策略看不到事件儲存）。往上取用會把那個
/// 方向反過來。而原本那份 registry 只 import `Foundation` / `LTMCore` /
/// `LTMQuery`——**它不需要服務層的任何東西**，所以整份搬下來即可，服務層
/// re-export 讓既有呼叫端不受影響。
///
/// ## 為什麼不是 protocol 或註冊機制
///
/// 三檔策略是封閉集合，而且新增一檔要動 spec。一個 `switch` 讓「有哪些策略」
/// 在一個地方讀得完；註冊機制會讓它散開，換來的可擴充性目前沒有需求——而且
/// 「可以在執行期註冊一個策略」正好會重開授權表要關掉的那個洞。
public enum StrategyRegistry {
    /// 目前可用的策略識別碼，供錯誤訊息列舉。
    ///
    /// 與 `authorizedConstraints(for:)` 的鍵集合必須相同——有一條測試斷言這件事，所以
    /// 只改其中一邊會紅，而不是安靜地漂移。
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

    /// 一個識別碼**必定**受哪些位置約束。
    ///
    /// **這是權威，策略的自報不是。** 兩者由 seam 取聯集（見
    /// `MemoryStrategy.rerank`）：策略可以再加，不能減。
    ///
    /// ## 為什麼沒有 `displacementBound` 的欄位
    ///
    /// 本表以**識別碼**為鍵，所以它只能承載識別碼決定得了的東西。而 bound 依
    /// spec 必須可在建構時組態——`human-like(displacementBound: 3)` 與
    /// `human-like(displacementBound: 1)` 是同一個識別碼的兩個實例。那正是
    /// 「幅度不屬於策略身分」的意思（見 `MemoryStrategy.consumedSignals` 的 doc），
    /// 也正是識別碼鍵的表對它無話可說的原因。**bound 的權威問題仍未決。**
    public static func authorizedConstraints(for id: RankingPolicyID)
        -> Set<PlacementConstraint>?
    {
        // **測試註冊優先，而這一行在生產路徑上也會跑。** 誠實記下它的代價：
        // 每次 `rerank` 多一次鎖的取放，查一個在生產中永遠是空的字典。
        //
        // 沒有量測，所以這裡不宣稱它「可忽略」——只說明為什麼接受它：替代方案是
        // 用編譯條件把註冊口從 release build 拿掉，而那會讓**測試跑的 code 與
        // 出貨的 code 不同**，那個代價本 repo 已經付過幾次（stale release binary、
        // SwiftPM 增量假綠）。一條無分支的鎖，換兩者逐字相同。
        if let extra = testAuthorities.withLock({ $0[id] }) { return extra }
        switch id.value {
        case "archival":
            // 它從不重排，所以位置約束對它是多餘的——`displacementBound = 0`
            // 已經讓任何移動都是違規。
            return []
        case "human-like":
            // 它**合法地**跨等分區段重排（帶內），所以不受 tie-run 約束——
            // 一個普世的 tie-run 約束會擋掉正確行為。
            return []
        case "conservative":
            // 這一檔的定義性差異就是「只在等分區段內動」。
            return [.withinTieRuns]
        default:
            // **刻意不提供預設值**：退回「沒有約束」等於留一個「宣告一個新名字
            // 就不受檢」的後門，而那是最容易不小心做到的事。由 seam 具名拒絕。
            return nil
        }
    }

    /// 套件內的註冊口。**模組外不可達**（`internal`）。
    ///
    /// ## 為什麼需要它
    ///
    /// 這個 seam 的每一道檢查，都是靠一個**刻意違規**的測試用 conformer 鎖住的
    /// ——回傳非排列、謊報位移、跨等分區段。那些 conformer 必須有自己的識別碼，
    /// 正因為它們不能是任何一檔出貨策略。封閉的表會拒絕它們，於是 seam 自己的
    /// 違規測試變成寫不出來。
    ///
    /// ## 為什麼這不是把洞重新打開
    ///
    /// `internal` 對匯入本套件的模組不可達，所以第三方 conformer 註冊不了自己的
    /// 授權——封閉性對外仍然成立。這與 `ValidatedCandidates` 的 internal `init`
    /// 是同一條邊界，而那條邊界 spec 已經記過它是什麼（capability，不是 proof）。
    /// **本條也寫進 spec**：沒有被記錄的信任邊界與疏漏無法區分。
    static func registerForTesting(_ id: RankingPolicyID, constraints: Set<PlacementConstraint>) {
        testAuthorities.withLock { $0[id] = constraints }
    }

    /// 撤銷一筆測試註冊。測試之間不互相污染。
    static func unregisterForTesting(_ id: RankingPolicyID) {
        testAuthorities.withLock { _ = $0.removeValue(forKey: id) }
    }

    /// seam 的違規測試所用的假識別碼，**逐一具名**。
    ///
    /// 刻意不用萬用字元或前綴規則：一份具名清單在讀的時候就看得出「哪些假身分
    /// 存在」，而規則會讓下一個人以為隨便取名都會被放行。
    ///
    /// 每一個都授權「無額外約束」，因為這些 conformer 要驗的是 seam 的**普世**
    /// 檢查（排列性、帶、位移上限、provenance 誠實性），不是位置約束。要驗位置
    /// 約束的測試自己宣告 `placementConstraints`，走聯集那條路。
    static let testIdentifiers = [
        "identity-probe", "lying", "band-crossing", "set-changing",
        "far-jumping", "movement-liar", "negative-bound", "misbehaving",
        "rogue", "truncating",
    ]

    /// 碰這個屬性即完成註冊。回傳值無意義，重點是初始化的副作用。
    ///
    /// ## 為什麼住在生產模組而不是某個測試 target
    ///
    /// 這些 conformer 分佈在**兩個** test target（`LTMQueryTests` 與
    /// `LTMEvalTests`），而兩個 target 平行跑。把 bootstrap 放在其中一個，另一個
    /// 就得靠「剛好先被跑到」——實測過那個形狀：整批跑全綠，`--filter` 單跑
    /// `LTMEvalTests` 的那條就紅。**那是「偶爾成功」，不是通過。**
    ///
    /// `static let` 的初始化在 Swift 是執行緒安全且恰好一次的，所以放在雙方都
    /// 看得到的這裡，誰先跑都一樣。
    static let readyForTesting: Bool = {
        for name in testIdentifiers {
            registerForTesting(RankingPolicyID(name), constraints: [])
        }
        return true
    }()

    /// 註冊表本體。用 `Mutex` 而不是裸 `static var`：本型別的成員從並行的
    /// 查詢路徑被讀，而 Swift 6 的並行檢查不接受可變的全域狀態。
    private static let testAuthorities = Mutex<[RankingPolicyID: Set<PlacementConstraint>]>([:])
}

/// 極小的互斥包裝。
///
/// 只為 `registerForTesting` 存在，不對外暴露——生產路徑（`authorizedConstraints`
/// 的 switch）不需要它，讀一次 `withLock` 的成本落在一個永遠是空表的查詢上。
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
