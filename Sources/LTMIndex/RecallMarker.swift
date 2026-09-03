import Foundation

/// 主動回想（proactive-recall-cued-hook）注入區塊的標記——**唯一**允許出現這串字面的地方。
///
/// 寫端是 `ltm query --format recall`（LTMService 的 `RecallBlock`），讀端是 chunker
/// （`CorpusScanner.indexableText(from:)` 依 `openPrefix` 排除整段）。兩端共用同一個常數，
/// 否則就是兩份會漂移的規格；`RecallMarkerSyncTests` 掃 `Sources/` 釘住這件事。
///
/// 為什麼要排除：官方 hooks 文檔明寫 hook 注入的文字會**存進 session transcript**，
/// 也就是會進 jsonl、進索引——注入的命中若被再索引，下一次查詢就把自己的輸出召回來
/// （性質 4：同一段經歷不因被重述而變成兩段記憶）。
public enum RecallMarker {
    /// 區塊開頭（含版本）。版本升級時 `openPrefix` 不變，舊索引仍會排除新版區塊。
    public static let open = "<!-- ltm:recall v1 -->"
    /// 區塊結尾。
    public static let close = "<!-- /ltm:recall -->"
    /// 讀端比對用的開頭前綴——比 `open` 短，故涵蓋所有版本。
    public static let openPrefix = "<!-- ltm:recall"

    /// 移除文字中每一段 `openPrefix … close`（含標記本身、跨行、非貪婪）。
    /// 有開頭沒結尾的區塊一律移除到**文字結尾**——半個區塊被索引與整個被索引一樣糟。
    public static func strippingRecallSpans(from text: String) -> String {
        guard text.contains(openPrefix) else { return text }
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: openPrefix) {
            result += rest[rest.startIndex..<start.lowerBound]
            let afterOpen = rest[start.upperBound...]
            guard let end = afterOpen.range(of: close) else { return result }
            rest = afterOpen[end.upperBound...]
        }
        result += rest
        return result
    }
}
