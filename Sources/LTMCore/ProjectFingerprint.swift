import CryptoKit
import Foundation

/// 一個 project 的穩定指紋，用作 `Anchor.source`。
///
/// ## 為什麼 source 不能是 sessionId
///
/// `Anchor` 的既有註解已經寫過「不要用會變的東西定址」，但它把判準寫成了一份清單
/// （不得使用索引產生的識別碼：chunk id、rowid、向量位移）。`sessionId` 不在那份
/// 清單上——它不是索引產生的——**卻一樣會變**：使用者 resume 或 fork 一個 session
/// 時，同一則 turn 會被複製進新檔案並帶上新的 sessionId。
///
/// 量測（`docs/measurements/2026-08-18-resume-duplication.md`，全語料 8,324 檔）：
/// 12,488 個 turn 識別碼出現在一個以上的檔案，內容 **100%** 相同，其中 98.9%
/// 的 sessionId 不同。以 sessionId 為 source 的 anchor
/// 在 resume 之後全部解析不到，而 orphan 原因會報「turn 不見了」——但那則 turn
/// 明明還在。使用歷史因此隨著每一次 resume 安靜蒸發。
///
/// 這是同一個失敗模式的第二次。判準因此改寫成性質而不是清單：**定址的每一個成分
/// 都不得是「內容沒變它卻會變」的值**。
///
/// ## 為什麼是指紋而不是 project 名本身
///
/// 兩個獨立的理由，任一都足夠：
///
/// 1. **長度**：`OpaqueIdentifier` 上限 64 字元，而實測 311 個 project 目錄有 173 個
///    名稱超過 64（median 71、max 152）。直接存名稱會讓超過一半的 project 索引不了。
/// 2. **隱私**：project 目錄名是路徑轉寫（`-Users-<使用者>-Developer-…`），而 source
///    會被原樣寫進 canonical event store。記憶層的硬約束是只存指標、統計與封閉集合的
///    類別標籤——本機路徑不屬於其中任何一類。
///
/// ## 誠實邊界
///
/// 指紋對 **project 被搬到別的路徑**不穩定：路徑一變，目錄名變，指紋跟著變，那個
/// project 的既有使用歷史會變成 orphan。這是接受的代價——搬動專案比 resume session
/// 罕見得多，而且是使用者的明確動作，不像 resume 那樣天天發生且無感。
public enum ProjectFingerprint {
    /// 指紋長度（十六進位字元數）。
    ///
    /// 32 個 hex = 128 bits。以本機語料的 project 數量（數百）而言，碰撞機率遠低於
    /// 任何實際關切；同時遠在 `OpaqueIdentifier` 的 64 字元上限之內。
    public static let hexLength = 32

    /// 這個值是不是**當前規則**產生的指紋形狀。
    ///
    /// 用於事件層的拒絕路徑（memory-events 的 "Anchors recorded under a superseded
    /// source-fingerprint form are refused, not reinterpreted"）。指紋本身不帶
    /// 「我是哪個規則算的」，所以只能從形狀判定：當前規則是 32 個小寫十六進位字元，
    /// 而被它取代的舊規則（sessionId）是 36 字元、含連字號——兩者不可能混淆。
    ///
    /// **誠實邊界**：這是形狀判定，不是版本判定。若日後某個新規則也產生 32 hex，
    /// 它與現行規則在這裡分不出來——屆時必須改成在紀錄裡帶明確的規則標記，
    /// 而不是把這個函式再加一條分支。
    public static func hasCurrentRuleShape(_ value: String) -> Bool {
        value.count == hexLength && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// 由 project 目錄名算出指紋。
    ///
    /// 輸入是**目錄名**而不是完整路徑：語料根的位置可以被環境變數覆寫，把它算進去
    /// 會讓同一個 project 在不同的語料根下得到不同指紋。
    public static func of(_ projectDirectoryName: String) -> String {
        let digest = SHA256.hash(data: Data(projectDirectoryName.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(hexLength))
    }
}
