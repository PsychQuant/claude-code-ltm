import Foundation

/// canonical store 的序列化紀律。
///
/// ## 判準：檔裡不得存在 schema 沒有定義的東西
///
/// 這句話寫在 `Event` 的 doc 裡已經三輪了，而三輪的實作都比它窄：
///
/// - **R2**：逐一列舉「識別碼型別」，漏掉 `ContentHash`。
/// - **R3**：判準縮成「字串欄位」，漏掉 `span`（空 span 成為萬用 anchor）。
/// - **R4**：加了 `rejectUnknownKeys`，但只裝在 `Event` 的**頂層** decoder 上。
/// - **R5**：三個 lens 都報「巢狀物件也要補」，而 devils-advocate 實測推翻了那個
///   處方——它修不掉另外兩條：
///   1. `"span":[2,6,"…原文…"]` 解碼成功。`Range<Int>` 的 `init(from:)` 住在
///      **Swift stdlib**，decode 兩個 Bound 之後從不檢查 `isAtEnd`。那不是巢狀
///      物件，而且那個 decoder 不是我們的。
///   2. `"policy":"archival","policy":"…原文…"` 解碼成功（取第一個），re-encode
///      與原本逐字相同。key 在 `CodingKeys.allCases` 裡，未知鍵檢查看不見它。
///
/// 每一輪的修法都是**再列舉一次入口**，於是每一輪都有下一種。CLAUDE.md 自己那句
/// 「列舉會漏，判準不會」在這裡已經第四次適用。
///
/// ## 所以判準要在它自己說的那個層級上執行：bytes
///
/// `decodeCanonicalLine` 解碼之後**重新編碼、與原始 bytes 逐字比對**，不同就當
/// 損壞。它不列舉任何入口，因此以下全部一次擋掉，包括我沒想到的：
/// 巢狀未知鍵、陣列多餘元素、重複鍵、`\uXXXX` 逃脫、多餘空白、鍵序不同。
///
/// ## 代價（必須說清楚，這不是免費的）
///
/// canonical 檔從此**綁定編碼器的輸出形式**。Foundation 若改變數字格式或跳脫規則，
/// 既有的每一行都會變成 corrupt——不是靜默讀錯，是全部讀不出來。這個方向是刻意選的
/// （fail loud 勝過靜默接受夾帶內容），而 `allEvents(skippingUnusable:)` 會逐行報出
/// 是哪幾行，所以真的發生時是可診斷、可重寫的。
///
/// 判準級的檢查在**位元組**層，我擁有的 decoder 仍各自嚴格化（下方
/// `rejectUnknownKeys` 與 `Anchor` 的 span 長度驗證）：兩層的成本都是幾行，而
/// 只有 bytes 那層能涵蓋 stdlib 的 decoder。
public enum CanonicalCoding {
    /// canonical 編碼器。**寫入與比對必須用同一個**——這是 bytes 比對成立的前提。
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public enum Violation: Error, Sendable, Equatable {
        /// 重新編碼的結果與原始 bytes 不同。
        ///
        /// 不附上差異內容：那段 bytes 正是可能含第三方原文的東西，把它放進錯誤
        /// 訊息等於讓外洩管道改走 log（R5 也對未知鍵的錯誤訊息提了同一件事）。
        case bytesNotCanonical(byteCount: Int)
        /// 某個 keyed 容器帶了 schema 沒有定義的鍵。
        ///
        /// 只回報**數量**，不回報鍵名——鍵名由攻擊者控制。
        case undeclaredKeys(type: String, count: Int)
        /// 陣列的元素數不符。
        case unexpectedArrayLength(field: String, expected: Int)
    }

    /// 解碼一行 canonical JSON，並要求它的 bytes 就是這個值的 canonical 形式。
    ///
    /// 泛型而不是只給 `Event`：判準適用於**每一個** canonical 型別，寫成泛型才不會
    /// 在加入 presentation store（design.md 已列為必補）時又要有人記得複製一次。
    public static func decodeCanonicalLine<T: Codable & Equatable>(
        _ type: T.Type, from line: Data
    ) throws -> T {
        let value = try JSONDecoder().decode(type, from: line)
        let reencoded = try encoder.encode(value)
        guard reencoded == line else {
            throw Violation.bytesNotCanonical(byteCount: line.count)
        }
        return value
    }

    /// 任意鍵容器，用來看見宣告之外的 key。
    public struct AnyKey: CodingKey {
        public let stringValue: String
        public let intValue: Int? = nil
        public init?(stringValue: String) { self.stringValue = stringValue }
        public init?(intValue: Int) { nil }
    }

    /// 拒絕宣告之外的鍵。**每一個我們自己寫的 keyed decoder 都要呼叫**。
    ///
    /// 它擋不掉重複鍵（key 在清單內）與陣列夾帶（不是 keyed 容器）——那兩者由
    /// bytes 比對負責。這裡的價值是讓錯誤發生在更靠近欄位的位置。
    public static func rejectUnknownKeys(
        in decoder: any Decoder, declared: Set<String>, type: String
    ) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        let unknown = all.allKeys.map(\.stringValue).filter { !declared.contains($0) }
        guard unknown.isEmpty else {
            throw Violation.undeclaredKeys(type: type, count: unknown.count)
        }
    }
}
