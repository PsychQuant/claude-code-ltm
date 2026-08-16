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


// MARK: - 只涵蓋漢字與 ASCII 英數（#1 verify R5）

@Test func ordinaryJapaneseIsNotFiledAsAMixedCJKLatinQuery() {
    // R5：latin 先前用 `CharacterSet.alphanumerics`，而那個集合**包含假名**。
    // 於是「記憶する」被判成 `mixed`，而 spec 對 mixed 的定義是「CJK 與 Latin
    // 同時出現」——那句話對這個輸入是假的。
    #expect(QueryClassifier.classify("記憶する") == .cjk2char)
    #expect(QueryClassifier.classify("検索") == .cjk2char)
}

@Test func kanaAndHangulOnlyQueriesLandInTheNonHanBucketAndThatIsAStatedLimitation() {
    // 這條記錄的是**限制**，不是理想行為：五值集合來自只跑過中文與英文的量測，
    // 假名與諺文沒有自己的桶，所以它們落在「不含漢字」那一格。標籤字面寫
    // `latin-alnum`，而它實際的意思是「不含漢字」。
    #expect(QueryClassifier.classify("ひらがな") == .latinAlnum)
    #expect(QueryClassifier.classify("한글검색") == .latinAlnum)
}

@Test func hanBeyondExtensionFIsStillCountedAsHan() {
    // R5：擴充 G 之後的漢字先前不在 `isHan` 的範圍清單裡，卻在
    // `CharacterSet.alphanumerics` 裡，所以被算成 latin。
    let extG = String(Unicode.Scalar(0x30000)!)  // 擴充 G
    #expect(QueryClassifier.classify(extG + extG) == .cjk2char)
}

@Test func aMixedQueryStillNeedsBothHanAndASCII() {
    #expect(QueryClassifier.classify("FTS5 分詞") == .mixed)
    // 漢字＋假名不是 mixed；漢字＋全形標點也不是。
    #expect(QueryClassifier.classify("分詞、比較") == .cjk4plus)
}
