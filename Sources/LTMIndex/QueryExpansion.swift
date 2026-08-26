import Foundation

/// 查詢端的擴展（#7）。
///
/// ## 為什麼在 query 端而不是索引端
///
/// 索引端擴展會把衍生詞寫進索引——那讓索引不再是語料的純衍生物（不變式 2 說
/// 刪掉重建必須等價，而「重建時的擴展規則」若改過，兩者就不等價），也讓同一段
/// 文字在索引裡有多份表示。query 端擴展只影響這一次查詢，改規則不必重建。
///
/// ## 目前只做繁簡，而那是量出來的範圍
///
/// `#7` 列了四種失效樣態：跨語彙階段、繁簡、中英別名、縮寫。**只有繁簡有機械
/// 解**——其餘三種需要一張沒有人維護的對照表，而那是資料問題不是程式問題。
///
/// 繁簡本身的規模也量過（`docs/measurements/2026-08-26-simplified-share.md`）：
/// 取樣 1,344 個有文字的 turn，**含簡體特徵字的只有 1.3%**。所以這條買到的東西
/// 不大——但它的失效是**安靜的**（查「檢索」召不回「检索」，使用者只會覺得
/// 「沒這回事」），而成本是一次字串轉換。
public enum QueryExpansion {
    /// 一個查詢的等價變體，**原詞永遠在第一個**。
    ///
    /// 回傳的是有序去重：原詞、繁體形、簡體形。三者相同時只回一個。
    ///
    /// 轉換用 `CFStringTransform`——macOS 內建，**離線**。這一點是硬要求：本 repo
    /// 的語料含第三方逐字內容，任何把查詢送出去的擴展方案（雲端翻譯、線上詞庫）
    /// 都違反零對外通道。
    public static func variants(of query: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in [query, converted(query, to: traditional), converted(query, to: simplified)]
        where !candidate.isEmpty && seen.insert(candidate).inserted {
            result.append(candidate)
        }
        return result
    }

    private static let traditional = "Simplified-Traditional"
    private static let simplified = "Traditional-Simplified"

    private static func converted(_ text: String, to transform: String) -> String {
        let mutable = NSMutableString(string: text)
        // 回傳值為 false 代表這個轉換不可用；那時退回原字串，而**不是**回空的
        // ——擴展失敗該讓查詢退化成「只用原詞」，不是讓它少一路還多一個空變體。
        guard CFStringTransform(mutable, nil, transform as NSString, false) else { return text }
        return mutable as String
    }
}
