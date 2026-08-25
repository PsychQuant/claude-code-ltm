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
        // **註冊的條目與 switch 的條目相加，不取代**（見 `registerForTesting`）。
        //
        // 這一行在生產路徑上也會跑。誠實記下它的代價：每次 `rerank` 多一次鎖的
        // 取放，查一個在生產中永遠是空的字典。沒有量測，所以不宣稱它「可忽略」
        // ——只說明為什麼接受它：替代方案是用編譯條件把註冊口從 release build
        // 拿掉，而那會讓**測試跑的 code 與出貨的 code 不同**，那個代價本 repo
        // 已經付過幾次（stale release binary、SwiftPM 增量假綠）。
        let registered = testAuthorities.withLock { $0[id] }
        let shipped = shippedConstraints(for: id)
        // 兩者皆無 → 這個識別碼不存在，由 seam 具名拒絕。
        guard registered != nil || shipped != nil else { return nil }
        return (shipped ?? []).union(registered ?? [])
    }

    /// 這個識別碼**至少**會消費哪些訊號。
    ///
    /// `consumedSignals` 先前是純自報，而 seam 拿它當**檢查開關**：
    /// `if !consumedSignals.isEmpty` 才驗 projection 形狀。於是外部策略宣告
    /// 空集合即可拿到一份未經驗證的 projection——**讓被約束者提供約束值**
    /// （#21 item 5）。
    ///
    /// 合成方向與 `placementConstraints` 相同、理由也相同：**取聯集，策略只能
    /// 往上加，不能減**。一個宣告空集合的 conformer 仍然吃到表裡的那一份，
    /// 而那個保證來自合成的形狀，不是靠記住它上次宣告過什麼。
    ///
    /// 未登錄的識別碼回空集合而不是 `nil`：識別碼本身的授權由
    /// `authorizedConstraints` 判定並具名拒絕，這裡不重複那個判斷。
    static func authorizedSignals(for id: RankingPolicyID) -> Set<EventKind> {
        switch id.value {
        case "archival":
            // 它的契約逐字是「不論給它什麼 projection 都產出相同輸出」，所以它
            // **不該**因為一份它從不讀取的 projection 而失敗（#1 verify R6）。
            return []
        case "human-like", "conservative":
            return [.opened, .cited, .pinned, .dismissed]
        default:
            return []
        }
    }

    /// switch 那一半。分出來只是為了讓上面的聯集讀得出來。
    private static func shippedConstraints(for id: RankingPolicyID)
        -> Set<PlacementConstraint>?
    {
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
    /// ## 它與表**相加**，不覆蓋（#34 verify，security + DA 各自指出）
    ///
    /// 初版是無條件 `$0[id] = constraints`，而 lookup 的第一行就 return——於是
    /// 註冊 `conservative` 為空集合會**減掉**表裡的 tie-run 約束。實測確認過：
    /// 註冊後 `authorizedConstraints(for: "conservative")` 回 `[]`。那讓這個
    /// 「只為測試」的鉤子成為本次改動要關掉的那個洞的一條新路徑。
    ///
    /// 修法不是加一道 `precondition`（trap 抓不進測試，那條守衛會沒有回歸鎖——
    /// 實測拿掉它零測試變紅），而是**把同一條合成紀律套用到鉤子自己身上**：
    /// 查詢時取「switch 的條目 ∪ 註冊的條目」。於是
    ///
    /// - 測試識別碼（switch 裡沒有）→ 註冊值就是它的授權，測試寫得出來；
    /// - 出貨識別碼（switch 裡有）→ 聯集保住表的約束，**減不掉**。
    ///
    /// 一條規則，兩種身分，而且它的違反是可斷言的行為而不是行程中止。
    static func registerForTesting(_ id: RankingPolicyID, constraints: Set<PlacementConstraint>) {
        testAuthorities.withLock { $0[id] = constraints }
    }

    /// 撤銷一筆測試註冊。
    ///
    /// ## 「測試之間不互相污染」這句話對 bootstrap 名單不成立（#36 階段 5）
    ///
    /// 先前這裡只寫那一句，而它有一個未寫明的例外：`readyForTesting` 是
    /// `static let`，**在一個 process 裡只跑一次**。所以撤銷 `testIdentifiers`
    /// 裡的任何一個之後，它**不會**被重新註冊——後續測試看到的是「那個識別碼
    /// 沒有授權條目」，而它們預期的是空集合。
    ///
    /// 目前沒有測試這樣做，所以這是**潛伏的**而非現行的。但那句無限定的宣稱
    /// 正是下一個人會依賴的東西：他會以為 `defer { unregisterForTesting(...) }`
    /// 對任何識別碼都安全。
    ///
    /// **成立的較窄陳述**：對測試**自己註冊**的識別碼，撤銷即回到未註冊狀態；
    /// 對 `testIdentifiers` 名單裡的，撤銷是**不可逆的**——那些請直接用，不要
    /// 撤銷。
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
        "rogue", "truncating", "history-fabricator",
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
    private static let testAuthorities = TestRegistryBox<[RankingPolicyID: Set<PlacementConstraint>]>([:])
}

/// 極小的互斥包裝。**刻意不叫 `Mutex`**——stdlib 的 `Synchronization.Mutex` 同名，
/// 一個 file-scope 的同名泛型會讓匯入該模組的檔案解析到意外的型別（#34 verify）。
///
/// 只為 `registerForTesting` 存在，不對外暴露。
///
/// **但生產路徑會經過它**——`authorizedConstraints` 的第一行就查這張表，所以每次
/// `rerank` 都有一次鎖的取放（查一個在生產中永遠是空的字典）。先前這段註解寫著
/// 「生產路徑不需要它」，與同一檔上方那段誠實的說明**直接矛盾**（#34 verify）。
final class TestRegistryBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
