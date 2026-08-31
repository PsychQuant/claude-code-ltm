import Foundation
import Testing

@testable import LTMMCP
import LTMIndex
@testable import LTMService

/// #51：MCP 門面對「本輪未併入新內容」的訊號。
///
/// CHANGELOG 寫「查詢撞上建置鎖時說出來」時只有 CLI 消費那個旗標——MCP 的讀者
/// 是模型，它更沒有辦法從答案本身看出新內容沒進來。這組測試扛的是：**兩個門面
/// 消費同一個旗標**，而且沒有命中時也要說（「沒有命中」可能正是因為沒併入）。

private func outcome(
    deferred: Bool, rejections: [String] = [], hits: [QueryHit] = []
) -> QueryOutcome {
    QueryOutcome(
        hits: hits, strategyID: "archival",
        refresh: RefreshReport(
            sourcesRefreshed: 0, sourcesUnreadable: [], sourcesInvalidated: 0,
            skipped: SkipTally(), mergeDeferredForConcurrentBuild: deferred,
            tuningRejections: rejections),
        eventsRecorded: 0, unattributableResults: 0)
}

@Test("併入被延後時，MCP 回應（零命中）帶警告行")
func deferredMergeWarningAppearsOnEmptyResult() {
    let text = RetrievalTool.render(outcome(deferred: true))
    #expect(text.contains("本輪未併入新內容"), "實得：\(text)")
    #expect(text.contains("（沒有命中）"))
}

@Test("併入正常時零命中的回應沒有警告行")
func noWarningWhenMergeSucceeded() {
    let text = RetrievalTool.render(outcome(deferred: false))
    #expect(!text.contains("⚠"), "不該有警告，實得：\(text)")
}

@Test("tuning 拒絕原樣進到 MCP 回應")
func tuningRejectionsSurfaceInResponse() {
    let text = RetrievalTool.render(
        outcome(deferred: false, rejections: ["LTM_BUILD_MEMORY_BUDGET_MB=abc 不是數字，已忽略"]))
    #expect(text.contains("LTM_BUILD_MEMORY_BUDGET_MB=abc"), "實得：\(text)")
}
