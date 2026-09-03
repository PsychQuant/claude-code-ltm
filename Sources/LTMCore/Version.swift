import Foundation

/// 這個 repo 的版本，**單一來源**。
///
/// ## 為什麼需要一個「單一來源」的宣告，而不是各處寫各處的
///
/// 版本號在發布路徑上至少出現在四個地方：這裡、MCP server 對 client 自報的
/// `serverInfo.version`、plugin 的 `plugin.json`、以及 wrapper 決定要下載哪個
/// asset 的 `DESIRED_VERSION`。`CLAUDE.md` 記過這個形狀：
///
/// > 一個數字被複述 N 次就是 N 份會漂移的規格，而漂移不會報錯。
///
/// 而它在這裡的漂移**特別難看見**：wrapper 去抓 `v0.1.0` 的 asset、plugin 對
/// 使用者顯示 `0.2.0`、binary 自報 `0.3.0`——三者都「成功」，沒有任何一步失敗。
///
/// ## 收斂到一處不等於它從此不漂移
///
/// 同一則紀錄的下一句是：**收斂只是把漂移搬到一個沒人看守的地方**，要補的是一個
/// 會變紅的檢查。shell 與 JSON 讀不到這個常數，所以那個檢查是
/// `ReleaseVersionSyncTests`——它把另外三處剖出來與這裡逐一比對。
///
/// 改版本時只改這裡，然後跑 `swift test`；哪一處沒跟上，測試會指名它。
public enum LTMVersion {
    /// Semantic version，不帶 `v` 前綴。git tag 是 `v` + 這個值。
    public static let current = "0.4.0"
}
