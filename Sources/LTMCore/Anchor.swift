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
    public let hex: String
    public init(hex: String) { self.hex = hex }
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

    public init(source: String, turnID: String, contentHash: ContentHash, span: Range<Int>) {
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
        self.span = try c.decode(Range<Int>.self, forKey: .span)
    }

    /// 由一則 turn 與 span 造出 anchor。
    ///
    /// 雜湊只涵蓋正規化後的 span 文字，**不含** `turn.role` 與 `turn.timestamp`：
    /// 把它們算進去的話，上游改一次 metadata 就會讓所有既有紀錄變成 orphan，
    /// 而那並不是「這段文字變了」。兩段一模一樣的短文字會雜湊相同，靠
    /// `turnID` 與 `span` 區辨。
    public init(source: String, turn: Turn, span: Range<Int>) {
        let sliced = Turn.slice(turn.text, span) ?? ""
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
