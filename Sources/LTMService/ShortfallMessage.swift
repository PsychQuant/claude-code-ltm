/// 有界併入沒併完時的那一行（#71）。CLI 的 stderr、recall 區塊、MCP 回應共用這一份措辭。
///
/// 先前這句在 `RecallBlock` 與 CLI 各寫一份、MCP 沒有——兩份會漂移，而少掉的那一份讓 MCP 的讀者（模型）看不出
/// 答案來自落後的索引。觸發條件一律是 `unmergedSources > 0`（被跳過的改寫來源也算，即使期限沒到）。
public enum ShortfallMessage {
    public static func line(unmergedSources: Int) -> String {
        "索引落後 \(unmergedSources) 個來源（有界併入未涵蓋，跑一次 ltm build 補齊）"
    }
}
