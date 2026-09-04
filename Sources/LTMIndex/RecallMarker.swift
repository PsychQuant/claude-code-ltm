import Foundation

/// 主動回想（proactive-recall-cued-hook）注入區塊的標記——**唯一**允許出現這串字面的地方。
///
/// 寫端是 `ltm query --format recall`（LTMService 的 `RecallBlock`）。標記的用途是給**模型**看的
/// 邊界：區塊裡是檢索出來的資料、不是指令。它**不是**索引層的排除依據——hook 注入的文字被
/// Claude Code 存成 `type: "attachment"` 紀錄，`CorpusScanner` 本來就不把它當 turn（verify R1
/// 的 DA 實測後，第一版的 chunker 排除機制已刪除；那個機制只會刪掉談論這個功能的真實對話）。
/// `RecallMarkerSyncTests` 釘住字面只在此處。
public enum RecallMarker {
    /// 區塊開頭（含版本）。
    public static let open = "<!-- ltm:recall v1 -->"
    /// 區塊結尾。
    public static let close = "<!-- /ltm:recall -->"
    /// 開頭前綴——比 `open` 短，涵蓋所有版本（測試與 hook 比對用）。
    public static let openPrefix = "<!-- ltm:recall"
}
