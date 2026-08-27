import Foundation

/// 建置的兩個可調參數，**以及它們從環境變數解析出來的唯一一份規則**。
///
/// ## 為什麼是一個型別而不是兩個 `Int`
///
/// 這兩個值先前只在 `ltm build` 的參數解析裡存在。而**增量併入主要不發生在
/// `ltm build`**：`LTMService.refreshIncrementally()` 在每一次查詢前都跑一次
/// （`.claude/rules/ltm-analogy.md` 明文：「併入發生在查詢路徑上，不是 session
/// 結束時」），而它建構 `IndexBuilder` 時兩個參數都沒傳——所以記憶體預算
/// 在**它最需要生效的那條路上**從來沒有生效過，包括長駐的 `ltm mcp`。
/// （#46 R2 verify，codex lens。）
///
/// 修法不是在 `refreshIncrementally` 裡再抄一次環境變數解析——那會變成第二份
/// 會漂移的規格（CLAUDE.md：同一件事有兩個寫者，就是兩份會漂移的規格）。
/// 修法是把解析收斂成這一份，兩條路徑都走它。
///
/// ## 誠實邊界
///
/// 收斂到單一位置**不等於**它從此不會漂移，只是把漂移搬到一個沒人看守的地方
/// （CLAUDE.md 對 #14 的紀錄）。看守它的是 `BuildTuningTests`。
public struct BuildTuning: Sendable, Equatable {
    /// 批次切點的**下限**。上界見 `IndexBuilder.batchChunkUpperBound(target:largestSource:)`。
    public var batchChunkTarget: Int
    /// 向量累積的預算（bytes）。`nil` = 不設限。
    ///
    /// **沒有預設值是刻意的**（#46）：本 repo 沒有量測支撐得起一個門檻。
    public var memoryBudgetBytes: Int?

    public static let defaultBatchChunkTarget = 2_000

    public init(batchChunkTarget: Int = BuildTuning.defaultBatchChunkTarget, memoryBudgetBytes: Int? = nil) {
        self.batchChunkTarget = batchChunkTarget
        self.memoryBudgetBytes = memoryBudgetBytes
    }

    /// 環境變數裡一個**壞值**該怎麼辦。
    ///
    /// 兩條路徑的正確答案不同，所以這是呼叫端的決定、不是這裡的：
    /// `ltm build` 要**拒絕並具名**（使用者剛剛打了那個旗標）；查詢路徑要
    /// **忽略並繼續**（拿一個環境變數的 typo 去讓查詢失敗是過度反應，而且
    /// 那個 typo 可能是好幾天前設的）。
    public enum Rejection: Error, Sendable, Equatable {
        case notAPositiveInteger(variable: String, value: String)
        /// MB → bytes 的乘法溢位。`value * 1_048_576` 對足夠大的值會 **trap**，
        /// 所以它必須在這裡被攔下來，不能留給呼叫端算。
        case megabytesOverflow(variable: String, value: String)
    }

    /// 從環境變數解析。**這是唯一一份解析規則。**
    ///
    /// - Parameter environment: 注入而不是直接讀 `ProcessInfo`——測試要能餵值，
    ///   而讓測試改行程環境會讓平行測試互相污染。
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (tuning: BuildTuning, rejections: [Rejection]) {
        var tuning = BuildTuning()
        var rejections: [Rejection] = []

        if let raw = environment["LTM_BUILD_BATCH_CHUNKS"] {
            switch parsePositive(raw, variable: "LTM_BUILD_BATCH_CHUNKS") {
            case .success(let value): tuning.batchChunkTarget = value
            case .failure(let rejection): rejections.append(rejection)
            }
        }
        if let raw = environment["LTM_BUILD_MEMORY_BUDGET_MB"] {
            switch parseMegabytes(raw, variable: "LTM_BUILD_MEMORY_BUDGET_MB") {
            case .success(let bytes): tuning.memoryBudgetBytes = bytes
            case .failure(let rejection): rejections.append(rejection)
            }
        }
        return (tuning, rejections)
    }

    public static func parsePositive(_ raw: String, variable: String) -> Result<Int, Rejection> {
        guard let value = Int(raw), value > 0 else {
            return .failure(.notAPositiveInteger(variable: variable, value: raw))
        }
        return .success(value)
    }

    /// MB → bytes，**溢位當成壞值**而不是讓它 trap。
    public static func parseMegabytes(_ raw: String, variable: String) -> Result<Int, Rejection> {
        guard let megabytes = Int(raw), megabytes > 0 else {
            return .failure(.notAPositiveInteger(variable: variable, value: raw))
        }
        let (bytes, overflowed) = megabytes.multipliedReportingOverflow(by: 1_048_576)
        guard !overflowed else { return .failure(.megabytesOverflow(variable: variable, value: raw)) }
        return .success(bytes)
    }
}
