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

@Test func degenerateInputsGetTheDocumentedLabelRatherThanAnyLabel() {
    // 先前這條寫成「classify 的回傳值屬於 QueryClass.allCases」——回傳型別就是
    // QueryClass，所以它恆真、什麼都沒測到（#1 verify，devils-advocate：
    // 「名字比證據強」）。改成逐一釘死退化輸入的**具體**歸屬，那才是真正需要
    // 被固定住的行為：報告的桶會不會因為空字串或純標點而多出一列。
    #expect(QueryClassifier.classify("") == .latinAlnum)
    #expect(QueryClassifier.classify("   ") == .latinAlnum)
    #expect(QueryClassifier.classify("。、！") == .latinAlnum)
    #expect(QueryClassifier.classify("42") == .latinAlnum)
    #expect(QueryClassifier.classify("中") == .cjk2char)  // 單字併入最短桶
    #expect(QueryClassifier.classify("中文與 English 混雜") == .mixed)
    #expect(QueryClassifier.classify("純中文的長查詢字串") == .cjk4plus)

    #expect(QueryClass.allCases.count == 5)
}

@Test func punctuationAndSpacingDoNotChangeTheLabel() {
    // 標點與空白不算長度，否則同一個查詢加個問號就換桶，報告會不穩。
    #expect(QueryClassifier.classify("釘選、版本") == QueryClassifier.classify("釘選版本"))
    #expect(QueryClassifier.classify("  釘選  ") == .cjk2char)
}

@Test func theClassifierIsAFunctionOfTheQueryAlone() {
    // 這條**只**驗確定性，不再宣稱它證明了「不保留 query」（#1 verify R4）：
    // 純函式呼叫兩次得到同樣的值，對「有沒有把字串留在別處」一無所知——
    // 一個會把每個 query 抄進檔案的分類器也照樣通過。
    //
    // 「不保留」的證據在 `InterleavingTests` 的
    // `thePresentationRecordCarriesNoByteOfTheQuery`：那條真的把 query 送進
    // harness、把產出的紀錄序列化，再檢查落地的 bytes。判準是輸出，不是簽章。
    let query = "這是一個不該被留下來的查詢字串"
    #expect(QueryClassifier.classify(query) == QueryClassifier.classify(query))
    #expect(QueryClassifier.classify(query) == .cjk4plus)
}
