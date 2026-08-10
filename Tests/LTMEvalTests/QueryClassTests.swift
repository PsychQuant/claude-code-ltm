import Foundation
import Testing

@testable import LTMEval

@Test(arguments: [
    ("釘選", QueryClass.cjk2char),
    ("釘選版", QueryClass.cjk3char),
    ("釘選版本比較", QueryClass.cjk4plus),
    ("tokenizer", QueryClass.latinAlnum),
    ("FTS5 分詞", QueryClass.mixed),
])
func classifierAssignsOneOfTheClosedFiveValues(query: String, expected: QueryClass) {
    #expect(QueryClassifier.classify(query) == expected)
}

@Test func everyQueryGetsExactlyOneLabelFromTheClosedSet() {
    let samples = ["", "   ", "。、！", "42", "中", "中文與 English 混雜", "純中文的長查詢字串"]
    for sample in samples {
        #expect(QueryClass.allCases.contains(QueryClassifier.classify(sample)))
    }
    #expect(QueryClass.allCases.count == 5)
}

@Test func punctuationAndSpacingDoNotChangeTheLabel() {
    // 標點與空白不算長度，否則同一個查詢加個問號就換桶，報告會不穩。
    #expect(QueryClassifier.classify("釘選、版本") == QueryClassifier.classify("釘選版本"))
    #expect(QueryClassifier.classify("  釘選  ") == .cjk2char)
}

@Test func classifierDoesNotRetainTheQuery() {
    // 標籤器是純函式、沒有存放：同一個 query 進去兩次拿到同一個標籤，且
    // 型別上沒有任何地方能把字串留下來（回傳型別就是一個 enum）。
    let query = "這是一個不該被留下來的查詢字串"
    #expect(QueryClassifier.classify(query) == QueryClassifier.classify(query))
    #expect(QueryClassifier.classify(query) == .cjk4plus)
}
