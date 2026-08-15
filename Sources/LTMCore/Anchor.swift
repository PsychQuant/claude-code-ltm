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
    }

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
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(validating: try c.decode(String.self, forKey: .hex))
    }

    public static func validate(_ hex: String) throws {
        guard hex.count == 64 else { throw ValidationError.wrongLength(hex.count) }
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
/// 四元組刻意不含任何索引產生的識別碼（chunk id、rowid、向量位移）。chunker
/// 一調，用 chunk id 的紀錄會**安靜地**指向別的文字；改用內容雜湊之後，同一
/// 個失敗會變成明確的 `.orphaned(.contentHashMismatch)`。
public struct Anchor: Sendable, Hashable, Codable {
    public let source: String
    public let turnID: String
    public let contentHash: ContentHash
    public let span: Range<Int>

    public enum SpanValidationError: Error, Sendable, Equatable {
        case empty(Range<Int>)
        case negativeLowerBound(Range<Int>)
    }

    /// span 的形狀約束，**所有建構路徑共用這一個**。
    ///
    /// #1 verify R4 的 CRITICAL：R3 抓到「空 span 的雜湊是 `sha256("")`，於是對
    /// 任何文字都 resolve 成功」之後，我的修法是逐一補入口——補了 `init(from:)`
    /// 與 `init(source:turn:span:)`，**漏掉 memberwise 這一個**。萬用 anchor 仍然
    /// 造得出來。
    ///
    /// 這與 R1「列舉六個識別碼型別、漏掉 ContentHash」是同一個形狀，而
    /// CLAUDE.md 自己寫著「列舉會漏，判準不會」——我第二次違反自己寫的那句話。
    /// 所以這次不是再補一個入口，是把判準抽成一個函式，讓「新增建構路徑卻忘了
    /// 驗證」在結構上更難發生。
    public static func validate(span: Range<Int>) throws {
        guard !span.isEmpty else { throw SpanValidationError.empty(span) }
        guard span.lowerBound >= 0 else { throw SpanValidationError.negativeLowerBound(span) }
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
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let source = try c.decode(String.self, forKey: .source)
        let turnID = try c.decode(String.self, forKey: .turnID)
        try OpaqueIdentifier.validate(source)
        try OpaqueIdentifier.validate(turnID)
        self.source = source
        self.turnID = turnID
        self.contentHash = try c.decode(ContentHash.self, forKey: .contentHash)
        let span = try c.decode(Range<Int>.self, forKey: .span)
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
        let found = Anchor.hash(normalized)
        guard found == contentHash else {
            return .orphaned(.contentHashMismatch(expected: contentHash, found: found))
        }
        return .resolved(normalized)
    }
}
