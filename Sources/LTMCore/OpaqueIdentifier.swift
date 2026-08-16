import Foundation

/// 識別碼的合法字元集與長度上限。
///
/// 存在的理由：`Event` 的 doc 宣稱「只存指標與統計，這條靠 schema 保證，不靠
/// 自律」——但只要 ID 型別吃任意字串，這句話就是假的。#1 的 verify（2026-08-11）
/// 用公開 API 把整段語料原文塞進 `GenerationID` / `RankingPolicyID` /
/// `NoteReference` / `PresentationID` 並序列化落地，隱私測試完全沒抓到，因為它
/// 只搜尋了自己挑的那幾個 fixture 字串。
///
/// 這個字元集刻意窄：ASCII 英數與 `.`、`_`、`-`，長度 ≤ 64。它擋掉的正是會出現在
/// 第三方逐字內容裡的東西——CJK、空白、標點、換行。**這不是萬能的**（有人硬要
/// 用 ASCII 編碼原文仍能繞過），但它把「不小心把原文塞進識別碼」從無聲變成
/// 建構期失敗，而那是實際會發生的失敗模式。
public enum OpaqueIdentifier {
    public static let maxLength = 64

    public enum ValidationError: Error, Sendable, Equatable {
        case empty
        case tooLong(length: Int)
        case illegalCharacter(Character)
    }

    public static func validate(_ raw: String) throws {
        guard !raw.isEmpty else { throw ValidationError.empty }
        guard raw.count <= maxLength else { throw ValidationError.tooLong(length: raw.count) }
        for character in raw {
            let ok = character.isASCII
                && (character.isLetter || character.isNumber || "._-".contains(character))
            guard ok else { throw ValidationError.illegalCharacter(character) }
        }
    }

    /// 給呼叫端在編譯期就該知道值合法的場合（字面值常數）。非法值是程式錯誤，
    /// 大聲 trap；外來資料一律走 `validate` 的 throwing 路徑。
    public static func require(_ raw: String, _ label: StaticString) -> String {
        do {
            try validate(raw)
        } catch {
            preconditionFailure("\(label) 收到非法識別碼（\(error)）——識別碼不得夾帶自由文字")
        }
        return raw
    }
}
