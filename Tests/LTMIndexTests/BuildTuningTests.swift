import Foundation
import Testing

@testable import LTMIndex

/// `BuildTuning` 是調校參數解析的**唯一一份規則**，而收斂到單一位置不等於它從此
/// 不會漂移——只是把漂移搬到一個沒人看守的地方（CLAUDE.md 對 #14 的紀錄）。
/// 這個檔就是那個看守。

@Test("MB → bytes 的溢位是壞值，不是 trap")
func megabytesOverflowIsRejectedRatherThanTrapping() {
    // `Int.max` MB 換成 bytes 必然溢位。舊行為是 `value * 1_048_576` 直接 crash
    // ——一個打錯的旗標不該讓行程死掉（#46 R2 verify，security lens）。
    let result = BuildTuning.parseMegabytes("\(Int.max)", variable: "--memory-budget-mb")
    #expect(result == .failure(.megabytesOverflow(variable: "--memory-budget-mb", value: "\(Int.max)")))

    // 剛好不溢位的最大值仍要成功——守衛不得寬到把合法值也擋掉。
    let largest = Int.max / 1_048_576
    #expect(BuildTuning.parseMegabytes("\(largest)", variable: "x")
        == .success(largest * 1_048_576))
}

@Test("非正整數被具名拒絕，零與負數都算")
func nonPositiveValuesAreNamed() {
    for bad in ["0", "-1", "abc", "", "1.5"] {
        #expect(BuildTuning.parsePositive(bad, variable: "--batch-chunks")
            == .failure(.notAPositiveInteger(variable: "--batch-chunks", value: bad)))
        #expect(BuildTuning.parseMegabytes(bad, variable: "--memory-budget-mb")
            == .failure(.notAPositiveInteger(variable: "--memory-budget-mb", value: bad)))
    }
}

/// **這條是 F 的回歸鎖的一半。** 另一半在 `LTMService.refreshIncrementally()`——
/// 它先前建構 `IndexBuilder` 時兩個參數都沒傳，所以記憶體預算在增量併入實際
/// 發生的那條路上（每次查詢前，含長駐的 `ltm mcp`）從來沒生效過。
@Test("環境變數被解析成 tuning——查詢路徑靠的就是這一份")
func environmentIsResolvedIntoTuning() {
    let (tuning, rejections) = BuildTuning.fromEnvironment([
        "LTM_BUILD_BATCH_CHUNKS": "512",
        "LTM_BUILD_MEMORY_BUDGET_MB": "64",
    ])
    #expect(rejections.isEmpty)
    #expect(tuning.batchChunkTarget == 512)
    #expect(tuning.memoryBudgetBytes == 64 * 1_048_576)
}

@Test("沒設環境變數時是預設值，且預算沒有預設——那是刻意的")
func absentEnvironmentMeansNoBudget() {
    let (tuning, rejections) = BuildTuning.fromEnvironment([:])
    #expect(rejections.isEmpty)
    #expect(tuning.batchChunkTarget == BuildTuning.defaultBatchChunkTarget)
    #expect(tuning.memoryBudgetBytes == nil,
            "預設不設限是刻意的（#46）——本 repo 沒有量測支撐得起一個門檻")
}

/// 壞值**回報但不吞**：查詢路徑選擇忽略並繼續，而那是呼叫端的決定——
/// 這一層要先把它說出來，否則呼叫端沒有東西可以決定。
@Test("環境變數的壞值被回報，而不是靜默採用預設")
func badEnvironmentValuesAreReportedNotSwallowed() {
    let (tuning, rejections) = BuildTuning.fromEnvironment([
        "LTM_BUILD_BATCH_CHUNKS": "-3",
        "LTM_BUILD_MEMORY_BUDGET_MB": "\(Int.max)",
    ])
    #expect(rejections.count == 2)
    #expect(tuning.batchChunkTarget == BuildTuning.defaultBatchChunkTarget)
    #expect(tuning.memoryBudgetBytes == nil)
}
