import Foundation

/// 查詢的分桶標籤。**封閉五值。**
///
/// 桶的切法直接來自 #2 的檢索基線量測（`docs/measurements/2026-08-08-baseline.md`
/// ——**數字必須指名出處**，否則讀者無法分辨它是有量測支撐的事實還是猜測）：
/// 該份量測記錄中文雙字在其測試的 lexical 配置下 39–42%，而向量融合的整體
/// 增益集中在這個桶。整體數字會把這種集中洗掉，所以報告必須分桶——而分桶需要
/// 一個標籤。
///
/// **那份量測涵蓋的是檢索配置，不是記憶策略。** 策略之間的比較目前沒有任何
/// 量測支撐（見 CLAUDE.md 的誠實邊界），本檔的分桶只是讓未來的策略比較不會
/// 被整體數字洗掉，不構成對策略的任何預測。
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
    /// ## 這個分類法只涵蓋「漢字」與「ASCII 英數」兩種文字，其餘沒有桶
    ///
    /// 五值集合來自 #2 的量測，而那份量測只跑過中文與英文。**假名、諺文、
    /// 西里爾字母等等沒有對應的桶**，它們一律落在 `latin-alnum`——所以那個
    /// 標籤實際的意思是「**不含漢字**」，不是「拉丁英數」。
    ///
    /// 這是誠實記錄的限制，不是設計。要真的替它們分桶就得擴大值域，而值域是
    /// canonical 層的東西（CLAUDE.md：「值域一開，它就從統計變回內容」），
    /// 需要先有那些語言的量測才談得上。追蹤於 #16。
    ///
    /// **先前這裡更糟**（#1 verify R5）：latin 用 `CharacterSet.alphanumerics`
    /// 判定，而那個集合**包含假名與諺文**。於是 doc 逐字寫著「刻意只認漢字，
    /// 不把假名或諺文算進來」，code 卻把它們算成 latin——一般日文查詢
    /// （漢字＋假名混寫，例如「記憶する」）因此被歸進 `mixed`，而 spec 對
    /// `mixed` 的定義是「CJK 與 Latin 同時出現」。標籤說的和發生的不是一回事。
    public static func classify(_ query: String) -> QueryClass {
        var han = 0
        var latin = 0
        for scalar in query.unicodeScalars {
            if isHan(scalar) {
                han += 1
            } else if isASCIIAlphanumeric(scalar) {
                latin += 1
            }
            // 其餘（假名、諺文、標點、emoji…）兩邊都不計。見上方的限制說明。
        }

        if han > 0 && latin > 0 { return .mixed }
        guard han > 0 else {
            // 不含漢字的一切都落在這裡：純英數、純假名、純諺文，以及退化情形
            // （空字串、只有標點）。封閉集合裡沒有「空」這一類，這是刻意的
            // 取捨：多開一類只為了退化輸入，會讓報告多一行永遠沒有觀測的桶。
            return .latinAlnum
        }
        switch han {
        case ...2: return .cjk2char  // 單字查詢併入最短桶
        case 3: return .cjk3char
        default: return .cjk4plus
        }
    }

    /// ASCII 英數。**刻意只認 ASCII**：`CharacterSet.alphanumerics` 涵蓋所有
    /// 文字的字母與數字，用它當「latin」是把整個 Unicode 當拉丁文。
    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }

    /// Han（漢字），**含全部已定義的擴充區**。
    ///
    /// 範圍清單是一個列舉，而列舉會漏——R5 指出擴充 G 之後的漢字先前落到
    /// `latin` 那一支去了。這裡沒有更好的辦法：Swift stdlib 不暴露 script
    /// property，所以只能列範圍。能做的是把上界開到 Unicode 目前為漢字保留的
    /// 整個平面區段（`0x20000...0x3FFFF`），讓未來新增的擴充區自動落在裡面，
    /// 而不是每次都要有人記得補一行。
    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,  // 擴充 A
            0x4E00...0x9FFF,  // 基本區
            0xF900...0xFAFF,  // 相容漢字
            0x20000...0x3FFFF:  // 擴充 B 以後（含 SIP／TIP 的漢字保留區）
            return true
        default:
            return false
        }
    }
}
