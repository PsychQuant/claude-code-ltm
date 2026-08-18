import CryptoKit
import Foundation

/// 語料裡的一則訊息。
///
/// `role` 與 `timestamp` 是呼叫端本來就有的資訊，這裡照收——但它們**不進**
/// anchor 的內容雜湊。理由見 `Anchor.contentHash`。
public struct Turn: Sendable, Equatable {
    public let id: String
    public let role: String
    public let timestamp: Date
    public let text: String

    public init(id: String, role: String, timestamp: Date, text: String) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.text = text
    }

    /// 依 Unicode scalar 位移取子字串。
    ///
    /// 用 scalar 位移而非 `String.Index`：位移要能被序列化、跨進程比較、
    /// 且不隨 grapheme 分群規則的版本變動而改變意義。越界回 `nil`。
    public static func slice(_ text: String, _ span: Range<Int>) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard span.lowerBound >= 0, span.upperBound <= scalars.count, span.lowerBound <= span.upperBound
        else { return nil }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[span])
        return String(view)
    }
}

/// 讀取語料的最小介面。實作住在 ingest 層（本 change 範圍外）；測試用合成實作。
public protocol CorpusReader: Sendable {
    func turn(id: String, inSource source: String) -> Turn?
}

/// dereference 的結果。orphaned 一定指名原因，且**不附帶**該位置上找到的文字。
public enum Dereference: Sendable, Equatable {
    case resolved(String)
    case orphaned(OrphanReason)

    /// 只有 resolved 才有文字。寫成 property 是為了讓「orphaned 不得回傳文字」
    /// 這件事在呼叫端也是型別層的事實，而不是靠記得去 switch。
    public var resolvedText: String? {
        if case .resolved(let text) = self { return text }
        return nil
    }
}

public enum OrphanReason: Sendable, Equatable {
    case turnMissing
    case spanOutOfBounds
    case contentHashMismatch(expected: ContentHash, found: ContentHash)
    /// 該位置現在的文字正規化之後是空字串。
    ///
    /// 這是 orphan 的一種，不是崩潰。R6 把「空內容摘要不得存在」做成
    /// `ContentHash(hex:)` 的 trap，而 `dereference` 會對**當下的語料文字**算
    /// 雜湊——語料被編輯成純空白時，讀取路徑就中止行程（#1 verify R7，四個
    /// lens 各自報，DA 以 A/B 量到 pre-R6 同一輸入回 `.orphaned`）。
    ///
    /// 建構路徑 trap 是對的（呼叫端給錯了），讀取路徑不行：語料不是我們能
    /// 控制的輸入，而 spec 寫的是「Altered source text dereferences as orphaned」。
    case contentNormalizesToNothing
}

/// 正規化後文字的 SHA-256，十六進位小寫。
public struct ContentHash: Sendable, Hashable, Codable, CustomStringConvertible {
    /// 恰好 64 個小寫十六進位字元。
    ///
    /// #1 verify R2（2026-08-14，logic / security / regression 三個 lens 各自重現）：
    /// R1 的隱私加固逐一列舉了識別碼型別，**漏掉這一個**。`ContentHash` 是
    /// `Anchor` 的欄位、`Anchor` 是每一筆 `Event` 的欄位，所以未驗證的
    /// `ContentHash(hex:)` 等於公開 API 直接把任意第三方文字寫進 canonical store
    /// ——正是那次加固要關掉的失敗模式。解碼路徑同樣無檢查。
    ///
    /// 教訓記在這裡：**逐一列舉是不可靠的加固方式**。當時列了六個型別、漏了第七個，
    /// 而我寫進 CLAUDE.md 的句子把那份清單當成 schema 層保證。真正的判準是
    /// 「這個欄位會不會被原樣序列化」，不是「我想不想得到它」。
    public let hex: String

    public enum ValidationError: Error, Sendable, Equatable {
        case wrongLength(Int)
        case illegalCharacter(Character)
        /// 這是 `sha256("")`。
        case emptyContentDigest
    }

    /// 空字串的 SHA-256。
    ///
    /// 一個雜湊等於這個值的 anchor 綁的是「沒有內容」，因此對任何文字都
    /// resolve 成功——萬用 anchor。R3 用「span 不得為空」擋它、R4 補了漏掉的
    /// 入口、R6 又找到第三條路徑（純空白的 span：`normalize` 去掉空白之後仍是
    /// 空字串）。前兩次擋的是入口，這次擋的是那個值本身。
    public static let emptyContentDigestHex =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// 顯式宣告：`rejectUnknownKeys` 需要 `allCases`，而 `init(from:)` 逐一具名
    /// 引用每個 key，所以少一個 case 是編譯錯誤而不是靜默少一個欄位。
    enum CodingKeys: String, CodingKey, CaseIterable { case hex }

    /// 字面值常數用（測試 fixture、內部計算結果）。非法值是程式錯誤 → trap。
    public init(hex: String) {
        do {
            try ContentHash.validate(hex)
        } catch {
            preconditionFailure("ContentHash 收到非法值（\(error)）——雜湊欄位不得夾帶自由文字")
        }
        self.hex = hex
    }

    public init(validating hex: String) throws {
        try ContentHash.validate(hex)
        self.hex = hex
    }

    public init(from decoder: any Decoder) throws {
        // R5：`Event` 的未知鍵檢查只裝在頂層，於是 `contentHash` 這一層可以夾帶
        // `"leak":"…原文…"` 而整筆解碼成功。修法不是「再列舉一個入口」——那是
        // 前四輪的做法——而是**每一個我們自己寫的 keyed decoder 都呼叫它**，
        // 外加 bytes 層的判準檢查（見 `CanonicalCoding`）。
        try CanonicalCoding.rejectUnknownKeys(
            in: decoder, declared: Set(CodingKeys.allCases.map(\.stringValue)),
            type: "ContentHash")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validating: try c.decode(String.self, forKey: .hex))
    }

    public static func validate(_ hex: String) throws {
        guard hex.count == 64 else { throw ValidationError.wrongLength(hex.count) }
        guard hex != ContentHash.emptyContentDigestHex else {
            throw ValidationError.emptyContentDigest
        }
        for character in hex {
            guard character.isASCII, character.isHexDigit, !character.isUppercase else {
                throw ValidationError.illegalCharacter(character)
            }
        }
    }

    public var description: String { hex }
}

/// 指向語料某一段文字的 canonical 位址。
///
/// ## 定址的判準
///
/// **四元組的每一個成分都不得是「內容沒變它卻會變」的值。** 判準寫成性質，
/// 不是寫成一份「哪些識別碼不能用」的清單——因為清單會漏，而它已經漏了兩次：
///
/// 1. **chunk id**（索引產生的）。chunker 一調，紀錄就**安靜地**指向別的文字。
///    改用內容雜湊之後，同一個失敗變成明確的 `.orphaned(.contentHashMismatch)`。
/// 2. **`sessionId`**（不是索引產生的，所以不在第一次那份清單上——卻一樣會變）。
///    session resume 把同一則 turn 複製進新檔並換上新 id，既有事件的 anchor
///    因此全部變成 orphan，而 orphan 原因會誤報成「turn 不見了」。
///
/// 第二次發生時，本註解的舊版本正寫著「不含任何**索引產生的**識別碼」並列出
/// 三個例子——那句話讀起來像判準，實際上是一份清單，而 `sessionId` 落在清單外。
/// 所以現在這裡放的是性質，例子只作為它被違反的紀錄，不作為它的定義。
///
/// 現行的 `source` 是 project 指紋，理由與它自己的誠實邊界見 `ProjectFingerprint`。
public struct Anchor: Sendable, Hashable, Codable {
    public let source: String
    public let turnID: String
    public let contentHash: ContentHash
    public let span: Range<Int>

    /// 顯式宣告，理由同 `ContentHash.CodingKeys`。
    enum CodingKeys: String, CodingKey, CaseIterable {
        case source, turnID, contentHash, span
    }

    public enum SpanValidationError: Error, Sendable, Equatable {
        case empty(Range<Int>)
        case negativeLowerBound(Range<Int>)
        /// `lower > upper`。這個值連 `Range` 都組不出來，只在原始整數上驗得到。
        case inverted(lower: Int, upper: Int)
    }

    /// span 的形狀約束，所有建構路徑共用。
    public static func validate(span: Range<Int>) throws {
        try validate(lower: span.lowerBound, upper: span.upperBound)
    }

    /// 同上，但驗的是**還沒組成 `Range` 的兩個整數**。
    ///
    /// 解碼路徑必須用這一個：`lower..<upper` 在 `lower > upper` 時觸發 stdlib 的
    /// precondition 並中止行程，所以 `validate(span:)` 看不到反序的輸入——它要
    /// 驗的值構造不出來。#1 verify R6 以編譯後的 probe 實測，包含
    /// `allEvents(skippingCorrupt:)` 這條修復路徑也一起崩。
    public static func validate(lower: Int, upper: Int) throws {
        guard lower <= upper else {
            throw SpanValidationError.inverted(lower: lower, upper: upper)
        }
        guard lower != upper else { throw SpanValidationError.empty(lower..<upper) }
        guard lower >= 0 else { throw SpanValidationError.negativeLowerBound(lower..<upper) }
    }

    public init(source: String, turnID: String, contentHash: ContentHash, span: Range<Int>) {
        do {
            try Anchor.validate(span: span)
        } catch {
            preconditionFailure("anchor 的 span 不合法（\(error)）——空 span 沒有內容可綁定")
        }
        // `source` 與 `turnID` 會原樣序列化進 canonical store，所以它們跟其他
        // 識別碼受同一條約束——不得夾帶自由文字。#1 verify 指出這兩個欄位是
        // 「schema 保證」宣稱的破口之一。
        self.source = OpaqueIdentifier.require(source, "Anchor.source")
        self.turnID = OpaqueIdentifier.require(turnID, "Anchor.turnID")
        self.contentHash = contentHash
        self.span = span
    }

    /// 外來資料（解碼）用：非法值 throw 而不是 trap。
    public init(from decoder: any Decoder) throws {
        try CanonicalCoding.rejectUnknownKeys(
            in: decoder, declared: Set(CodingKeys.allCases.map(\.stringValue)),
            type: "Anchor")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let source = try c.decode(String.self, forKey: .source)
        let turnID = try c.decode(String.self, forKey: .turnID)
        try OpaqueIdentifier.validate(source)
        try OpaqueIdentifier.validate(turnID)
        self.source = source
        self.turnID = turnID
        self.contentHash = try c.decode(ContentHash.self, forKey: .contentHash)
        // **不用 `Range<Int>` 的 stdlib 解碼**。它 decode 兩個 Bound 之後從不檢查
        // `isAtEnd`，所以 `"span":[2,6,"…第三方原文…"]` 會解碼成功、原文永久留在
        // canonical 檔的 bytes 裡（#1 verify R5 實測，1,600 字照樣過）。那個
        // decoder 在 Swift stdlib，不是我能改的——所以這裡自己讀 unkeyed 容器
        // 並要求長度恰為 2。
        var spanBounds = try c.nestedUnkeyedContainer(forKey: .span)
        let lower = try spanBounds.decode(Int.self)
        let upper = try spanBounds.decode(Int.self)
        guard spanBounds.isAtEnd else {
            throw CanonicalCoding.Violation.unexpectedArrayLength(field: "span", expected: 2)
        }
        // **先驗整數，再組 `Range`。** 反序的 span 會讓 `lower..<upper` 中止行程。
        do {
            try Anchor.validate(lower: lower, upper: upper)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .span, in: c, debugDescription: "\(error)")
        }
        let span = lower..<upper
        // 解碼邊界同樣擋空 span 與負位移：外來檔案裡一筆 `span: [3,3]` 的紀錄
        // 會是一個對任何文字都成立的萬用 anchor。span 是會被原樣序列化的欄位，
        // 所以它跟識別碼一樣需要形狀約束——R3 指出「每個被原樣序列化的欄位」
        // 這個判準被我縮成了「字串欄位」，而缺口正好落在縮掉的地方。
        do {
            try Anchor.validate(span: span)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .span, in: c, debugDescription: "\(error)")
        }
        self.span = span
    }

    /// 由一則 turn 與 span 造出 anchor。
    ///
    /// 雜湊只涵蓋正規化後的 span 文字，**不含** `turn.role` 與 `turn.timestamp`：
    /// 把它們算進去的話，上游改一次 metadata 就會讓所有既有紀錄變成 orphan，
    /// 而那並不是「這段文字變了」。兩段一模一樣的短文字會雜湊相同，靠
    /// `turnID` 與 `span` 區辨。
    public init(source: String, turn: Turn, span: Range<Int>) {
        // 越界或空 span 是**呼叫端的錯**，不是語料的狀態，所以 trap 而不是
        // 靜默產生一筆紀錄。先前寫的是 `Turn.slice(...) ?? ""`，兩個後果都很糟
        // （#1 verify R3 實測）：
        //
        // 1. 越界時建構子替它**沒讀到的內容**算出 `sha256("")`，造出一筆永遠
        //    orphan 的紀錄，而 orphan 原因會顯示成 `.spanOutOfBounds`——看起來
        //    像語料變了，實際上是呼叫端給錯了。
        // 2. 空 span（`n..<n`）讓內容綁定整個失效：它的雜湊是 `sha256("")`，
        //    於是**對任何一段第三方文字都 resolve 成功**。`memory-events` spec
        //    的「Altered source text dereferences as orphaned」對空 span 不成立。
        do { try Anchor.validate(span: span) } catch {
            preconditionFailure("anchor 的 span 不合法（\(error)）")
        }
        guard let sliced = Turn.slice(turn.text, span) else {
            preconditionFailure(
                "anchor 的 span \(span) 對長度 \(turn.text.unicodeScalars.count) 的 turn 越界"
                    + "——越界 span 綁的是不存在的內容")
        }
        self.init(
            source: source,
            turnID: turn.id,
            contentHash: Anchor.hash(Anchor.normalize(sliced)),
            span: span)
    }

    /// 正規化：NFC → 所有 Unicode 空白（含換行）收成單一半形空白 → 去頭尾。
    ///
    /// 為什麼要正規化：轉錄檔重新序列化時尾端空白與換行常有出入，那不該算
    /// 「文字變了」。代價是內部空白差異被抹平——對 CJK 幾乎無影響，對英文
    /// 則是刻意接受的取捨。
    public static func normalize(_ text: String?) -> String {
        guard let text else { return "" }
        let composed = text.precomposedStringWithCanonicalMapping
        let parts = composed.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    public static func hash(_ normalized: String) -> ContentHash {
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return ContentHash(hex: digest.map { String(format: "%02x", $0) }.joined())
    }

    /// 解析這個 anchor。雜湊不符時回 `.orphaned`，**不**回傳該位置上找到的文字。
    public func dereference(in corpus: some CorpusReader) -> Dereference {
        guard let turn = corpus.turn(id: turnID, inSource: source) else {
            return .orphaned(.turnMissing)
        }
        guard let sliced = Turn.slice(turn.text, span) else {
            return .orphaned(.spanOutOfBounds)
        }
        let normalized = Anchor.normalize(sliced)
        // **算雜湊之前先擋空字串。** `Anchor.hash` 走 `ContentHash(hex:)`，而它對
        // 空內容摘要 trap；那個 trap 屬於建構路徑，不該出現在讀取路徑上。
        guard !normalized.isEmpty else {
            return .orphaned(.contentNormalizesToNothing)
        }
        let found = Anchor.hash(normalized)
        guard found == contentHash else {
            return .orphaned(.contentHashMismatch(expected: contentHash, found: found))
        }
        return .resolved(normalized)
    }
}
