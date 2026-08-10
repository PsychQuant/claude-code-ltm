import Foundation

/// 查詢的分桶標籤。**封閉五值。**
///
/// 桶的切法直接來自 #2 的量測：中文雙字在所有 lexical 配置下最好也只有
/// 39–42%，而向量融合的 +1pp 整體增益 100% 落在這個桶裡。整體數字會把這種
/// 集中的效果洗掉，所以報告必須分桶——而分桶需要一個標籤。
///
/// 標籤是**統計不是內容**：五值集合對 query 內容幾乎不帶資訊，因此它可以進
/// canonical 層，而 query 原文不行。
public enum QueryClass: String, Sendable, Hashable, Codable, CaseIterable {
    case cjk2char = "cjk-2char"
    case cjk3char = "cjk-3char"
    case cjk4plus = "cjk-4plus"
    case latinAlnum = "latin-alnum"
    case mixed
}

/// 從 query 算出標籤。
///
/// **query 原文到此為止**：呼叫端把字串交進來、拿一個標籤回去，字串不被保存、
/// 不被回傳、也不進任何紀錄。這是「用於 routing 而非 answering」的同一條線——
/// 從內容導出一個決定，但不把內容留下。
public enum QueryClassifier {
    public static func classify(_ query: String) -> QueryClass {
        var han = 0
        var latin = 0
        for scalar in query.unicodeScalars {
            if isHan(scalar) {
                han += 1
            } else if CharacterSet.alphanumerics.contains(scalar) {
                latin += 1
            }
        }

        if han > 0 && latin > 0 { return .mixed }
        guard han > 0 else {
            // 純英數，以及退化情形（空字串、只有標點）都落在這裡。封閉集合
            // 裡沒有「空」這一類，這是刻意的取捨：多開一類只為了退化輸入，
            // 會讓報告多一行永遠沒有觀測的桶。
            return .latinAlnum
        }
        switch han {
        case ...2: return .cjk2char  // 單字查詢併入最短桶
        case 3: return .cjk3char
        default: return .cjk4plus
        }
    }

    /// Han（漢字）。刻意只認漢字：#2 的桶就是照漢字長度切的，把假名或諺文
    /// 算進來會讓桶的意義與那份量測對不起來。
    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,  // 擴充 A
            0x4E00...0x9FFF,  // 基本區
            0xF900...0xFAFF,  // 相容漢字
            0x20000...0x2A6DF,  // 擴充 B
            0x2A700...0x2EBEF:  // 擴充 C–F
            return true
        default:
            return false
        }
    }
}
