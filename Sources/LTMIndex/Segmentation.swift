import Foundation
import NaturalLanguage

/// 斷詞：把文字轉成以空白分隔的詞序列，供 `unicode61` 這類「靠空白切詞」的
/// tokenizer 使用。
///
/// 配置依 `docs/measurements/2026-08-10-fts5-tokenizer.md`（#2）的決定：
/// **lexical 採 `trigram` + 斷詞雙欄位**。斷詞這一路單獨的中文 recall 是
/// 31–52%，而未斷詞的 `unicode61` 在中文各桶是 0%——這兩個數字是那份紀錄的，
/// 不是這裡新宣稱的。
///
/// **只對 CJK 段呼叫 `NLTokenizer`**（同一份紀錄的決定）：拉丁文字本來就有空白，
/// 交給 tokenizer 只是多一次沒有收益的呼叫；而混排文字整段丟進去會讓拉丁詞被
/// 拆成預期外的形狀。
public enum Segmentation {
    /// 把文字斷成以單一半形空白分隔的詞序列。
    public static func segment(_ text: String) -> String {
        var output: [String] = []
        for run in scriptRuns(text) {
            if run.isCJK {
                output.append(contentsOf: cjkTokens(run.text))
            } else {
                // 非 CJK 段照原樣帶過去：它自己的空白就是詞界。
                let trimmed = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { output.append(trimmed) }
            }
        }
        return output.joined(separator: " ")
    }

    /// 依 script 把文字切成 CJK / 非 CJK 交錯的段。
    static func scriptRuns(_ text: String) -> [(text: String, isCJK: Bool)] {
        var runs: [(text: String, isCJK: Bool)] = []
        var current = ""
        var currentIsCJK: Bool?
        for character in text {
            let isCJK = isCJKCharacter(character)
            if currentIsCJK == nil {
                currentIsCJK = isCJK
                current.append(character)
            } else if isCJK == currentIsCJK {
                current.append(character)
            } else {
                runs.append((text: current, isCJK: currentIsCJK!))
                current = String(character)
                currentIsCJK = isCJK
            }
        }
        if let flag = currentIsCJK, !current.isEmpty {
            runs.append((text: current, isCJK: flag))
        }
        return runs
    }

    /// 中日韓的表意文字與假名。**不含**標點與全形符號——它們不是詞的內容，
    /// 夾在中間只會讓 `NLTokenizer` 多切幾刀。
    static func isCJKCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,  // 平假名、片假名
            0x3400...0x4DBF,  // CJK 擴充 A
            0x4E00...0x9FFF,  // CJK 統一表意文字
            0xF900...0xFAFF,  // 相容表意文字
            0xAC00...0xD7AF,  // 韓文音節
            0x20000...0x2FA1F:  // 擴充 B 以後
            return true
        default:
            return false
        }
    }

    /// 對一段純 CJK 文字取詞。
    ///
    /// `NLTokenizer` 會丟字（`docs/measurements/2026-08-10-fts5-tokenizer.md` 量到的
    /// 行為）。**本函式只回傳斷出的詞，不額外附上整段原文**——被丟掉的字由 trigram
    /// 那一條通道涵蓋，那正是雙欄位配置的用意。
    ///
    /// （先前這則註解寫著「額外把整段原文也放進輸出」，而實作從來沒有那樣做。
    /// 那句話還被用來當作「丟字沒關係」的理由，於是一個不存在的機制變成了一個
    /// 決定的依據。）
    static func cjkTokens(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range])
            if !token.isEmpty { tokens.append(token) }
            return true  // 繼續列舉；回 false 會提前停在第一個詞
        }
        return tokens
    }
}
