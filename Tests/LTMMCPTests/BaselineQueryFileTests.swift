import CryptoKit
import Foundation
import Testing

/// #63：基準查詢集是一份**資料檔**，它的契約是「不被儀器自己污染」——這些測試釘的是契約
/// 的可機械檢查部分：檔頭寫明三件事、條數夠、不含已退役（已被量測命令污染）的查詢、
/// 量測腳本的守衛各有一條測試扛。
///
/// 「各有一條測試扛」的查法就是變異測試：把腳本裡的一條守衛退掉、跑本檔、必須變紅。#63 verify
/// R2 逐條退過 30 處，11 處綠——那 11 處在 R2 verify-fix 裡 9 處補上驅動它的測試
/// （error(exec)、error(sig<N>)、66 整行、`-r` 臂、`-x` 臂、70、最後一行沒換行、k 非數字的訊息、
/// snippet 非字串→shape）、2 處拆掉（`bool(q)`、python 端的 stderr=DEVNULL）。同一輪新加了執行期列
/// 形狀的守衛 `valid_row`，R3 再退一次後留下的每個分支各有一個假 python3 驅動（見 judge 測試）。
/// 這句話**只涵蓋那兩輪列出的守衛**；新加的守衛要自己再退一次。
///
/// 退役查詢以字面寫在這裡是刻意的：它們已經在語料裡（#63 的 root cause），再多出現一次不改變
/// 什麼；而新查詢**不**出現在任何測試或訊息裡——測試只讀檔、只斷言性質，而且對真檔的每一個
/// 斷言都先算成 Bool／索引再 `#expect`，讓失敗訊息的展開式裡**沒有檔案內容**（swift-testing 會把
/// 接收者的值印出來；`#expect(!q.contains(r))` 失敗時 q 會整條落進測試輸出，那是一條洩漏路徑）。
private func repoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
}

/// 六條全部來自 `docs/measurements/2026-09-01-scan-parallelism.md` 的 after 輪命令列（#63）。
private let retired = ["tokenizer 討論", "flock inode 鎖", "資格考", "band 相關度", "memory strategy", "並行雜湊"]

/// 腳本只剝 ASCII 空白（空格、tab、CR、VT、FF；LF 由 `read` 吃掉、這裡由切行吃掉，所以兩個集合
/// 差一個 LF 而行為相同）——刻意不用 `.whitespacesAndNewlines`，它含 U+3000／NBSP 等 Zs，而 bash 的
/// `[:space:]` 對那些字元隨 locale 變。兩邊都只認 ASCII，再加上下面對真檔「沒有非 ASCII 空白」的
/// 斷言，三邊就對得上。切行用 `components(separatedBy: "\n")`（UTF-16 層級）而不是
/// `split(separator: "\n")`：後者把 CRLF 當一個 grapheme、不在它中間切，CRLF 檔會被算成一行。
private let asciiWhitespace = CharacterSet(charactersIn: " \t\r\n\u{0B}\u{0C}")

/// 與 `measure-baseline.sh` 同一個「第 N 條非註解行」定義。
private func nonCommentLines(_ text: String) -> [String] {
    text.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: asciiWhitespace) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// 查詢檔裡不准出現的純量——寫成**性質**不是清單（清單會漏：NUL 就不在舊清單裡）。兩條理由，各自導出一部分：
/// (a) 行定義會分岔：能被 bash 的 read／python 的 split／Swift 的 components 或三邊的 ASCII trim 不同處理的字元
///     ——實際上只有 LF 與五個 ASCII 空白，而那五個由行定義自己處理、不禁；
/// (b) 落進 judge 的 Unicode 空白摺疊會變成空針（`error(blank)`，見 blank 的測試）：U+3000、NBSP 這類 Zs。
/// 實作取 fail-closed 的**超集**：ASCII 控制字元與 DEL（五個 ASCII 空白除外）、非 ASCII 的 Zs／Zl／Zp／Cf／Cc
/// 全禁，不逐一論證每個字元落在 (a) 還是 (b)。射程之外：肉眼看不見但三邊一致、judge 也不摺疊的字元
/// （Mn、variation selector 等）——這條守的是行定義與 judge，不是視覺審閱。檔首 BOM 另判（見 checkQueryFile）。
private func isForbiddenScalar(_ s: Unicode.Scalar) -> Bool {
    if s.value < 0x80 {
        return (s.value < 0x20 && !" \t\r\n\u{0B}\u{0C}".unicodeScalars.contains(s)) || s.value == 0x7F
    }
    switch s.properties.generalCategory {
    case .spaceSeparator, .lineSeparator, .paragraphSeparator, .format, .control: return true
    default: return false
    }
}

/// 一條查詢的純量數上限。它擋的是**整段文字的量級**（一段逐字稿、一則 turn 整段貼進來），分不出一句第三方
/// 逐字短句與自行撰寫的短語——這個檔進 remote 卻無任何審閱路徑（`-diff`＋規則 1 的「reviewer 不准讀內容」），
/// 這條是它唯一的內容約束，所以射程要寫清楚。門檻與現況的查法（只印長度，不印內容；量的單位要與守衛相同——
/// awk 的 `length` 在 macOS 回的是 bytes，中文差約 3 倍，R9）：
/// `grep -v '^#' scripts/baseline-queries.txt | python3 -c "import sys; print(max(len(l.strip()) for l in sys.stdin if l.strip()))"`。
/// README 寫的同一個數由同步測試對照這個常數。
private let maxQueryScalars = 64

/// 檔頭必須出現的短語：三件事（列舉會漏／不得在 session 內顯示／只印編號）與會進索引的兩個欄位名。
private let requiredHeaderPhrases = ["列舉", "會漏", "不得在 Claude Code session 內顯示", "只印編號", "`text` block", "toolMetadataFields"]   // 「text」四個字母 context 也滿足（R9）

/// 查詢檔契約可機械檢查的部分，對任一份 bytes 算。真檔與合成 fixture 走**同一支**——R8 證明先前
/// 四條守衛（禁止純量、長度上限、CRLF 切行、以及它們的行號）只讀真檔，而真檔依建構就是乾淨的，退掉零紅。
/// 每一則違規只帶序號／行號，不帶內容。
private struct QueryFileReport: Equatable {
    var missingHeaderPhrases: [String] = []
    var count = 0
    var duplicateCount = 0
    var retiredOffenders: [Int] = []   // 條目序號
    var tooLong: [Int] = []            // 條目序號
    var forbiddenLines: [Int] = []     // 實體行號；檔首 BOM 記為 0
}

private struct NotUTF8: Error {}

private func checkQueryFile(_ data: Data) throws -> QueryFileReport {
    var r = QueryFileReport()
    // 檔首 BOM：`String(data:)` 會把它剝掉，bash 與 python 不會——第一行的 `#` 對它們不是行首，檔頭註解會被算成
    // 第 1 條、也混進指紋。這是三邊分岔的唯一位置，而它對解碼後的字串不可見，所以看 bytes（R8）。
    if data.starts(with: [0xEF, 0xBB, 0xBF]) { r.forbiddenLines.append(0) }
    guard let text = String(data: data, encoding: .utf8) else { throw NotUTF8() }
    // 實體行用與 nonCommentLines 同一個切法（CRLF 也切）；註解行的判法也與行定義一致：先 ASCII trim 再看 `#`。
    let physical = text.components(separatedBy: "\n")
    let header = physical.filter { $0.trimmingCharacters(in: asciiWhitespace).hasPrefix("#") }.joined(separator: "\n")
    r.missingHeaderPhrases = requiredHeaderPhrases.filter { !header.contains($0) }
    let queries = nonCommentLines(text)
    r.count = queries.count
    r.duplicateCount = queries.count - Set(queries).count
    r.retiredOffenders = queries.indices.filter { i in retired.contains { queries[i].contains($0) } }.map { $0 + 1 }
    r.tooLong = queries.indices.filter { queries[$0].unicodeScalars.count > maxQueryScalars }.map { $0 + 1 }
    r.forbiddenLines += physical.enumerated()
        .filter { $0.element.unicodeScalars.contains(where: isForbiddenScalar) }.map { $0.offset + 1 }
    return r
}

@Test("baseline-queries.txt：檔頭三件事、≥6 條、無重複、每條不超過上限、不含六條退役查詢、無控制字元／非 ASCII 空白／檔首 BOM（失敗訊息只帶序號）")
func baselineQueryFileDocumentsItsContractAndRetiresThePollutedQueries() throws {
    let data = try Data(contentsOf: repoRoot().appendingPathComponent("scripts/baseline-queries.txt"))
    let r = try checkQueryFile(data)
    #expect(r.missingHeaderPhrases.isEmpty, Comment(rawValue: "檔頭缺：\(r.missingHeaderPhrases)"))
    #expect(r.count >= 6, "基準查詢至少 6 條，得 \(r.count)")
    #expect(r.duplicateCount == 0, "查詢重複：\(r.duplicateCount) 條")
    #expect(r.retiredOffenders.isEmpty, Comment(rawValue: "含退役查詢的條目序號：\(r.retiredOffenders)"))
    #expect(r.tooLong.isEmpty, Comment(rawValue: "超過 \(maxQueryScalars) 個純量的條目序號：\(r.tooLong)"))
    #expect(r.forbiddenLines.isEmpty, Comment(rawValue: "含禁止純量（控制字元、非 ASCII 空白；0 = 檔首 BOM）的行號：\(r.forbiddenLines)"))
}

@Test("查詢檔檢查由合成 fixture 驅動：CRLF 下的行號、檔首 BOM、行中 BOM、NUL、U+0001、U+3000、DEL、超長、重複、退役、檔頭缺短語——各自為對的理由紅；行中 tab 與尾隨空白不禁")
func queryFileChecksAreDrivenByTheirOwnFixture() throws {
    let header = "# " + requiredHeaderPhrases.joined(separator: " ") + "\n"
    func report(_ s: String, bom: Bool = false) throws -> QueryFileReport {
        try checkQueryFile((bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(s.utf8))
    }
    #expect(try report(header + "ZQXJ-A\nZQXJ-B\nZQXJ-C\nZQXJ-D\nZQXJ-E\nZQXJ-F\n") == QueryFileReport(count: 6))
    // CRLF：行號要指到實體行——用 split 整檔會被算成一行，行號永遠是 1、條數也錯（R7 #9 的修法先前沒有東西驅動）。
    let crlf = try report("# h\r\nZQXJ-A\r\nZQXJ\u{0001}B\r\nZQXJ-C\r\n")
    #expect(crlf.forbiddenLines == [3] && crlf.count == 3, Comment(rawValue: "\(crlf)"))
    #expect(try report("ZQXJ-A\n", bom: true).forbiddenLines == [0])        // 檔首 BOM：只有 bytes 看得到
    #expect(try report("ZQXJ-A\nZQ\u{FEFF}XJ\n").forbiddenLines == [2])      // 行中 BOM（Cf）
    #expect(try report("ZQXJ\u{0000}A\n").forbiddenLines == [1])             // NUL：舊清單漏掉的那一個
    #expect(try report("ZQXJ\u{3000}A\n").forbiddenLines == [1])             // U+3000（Zs）：judge 會摺成空針
    #expect(try report("ZQXJ\u{7F}A\n").forbiddenLines == [1])               // DEL
    #expect(try report("ZQXJ\tA \n").forbiddenLines.isEmpty)                  // 行中 tab、尾隨空白：行定義自己處理
    #expect(try report("ZQXJ-A\n" + String(repeating: "Z", count: maxQueryScalars + 1) + "\n").tooLong == [2])
    #expect(try report("ZQXJ-A\n" + String(repeating: "Z", count: maxQueryScalars) + "\n").tooLong.isEmpty)
    #expect(try report("ZQXJ-A\nZQXJ-A\n").duplicateCount == 1)
    #expect(try report("ZQXJ-A\n" + retired[0] + "\n").retiredOffenders == [2])
    #expect(try report("ZQXJ-A\n").missingHeaderPhrases.count == requiredHeaderPhrases.count)
    #expect(throws: NotUTF8.self) { try checkQueryFile(Data([0xFF, 0xFE, 0x41])) }   // 非 UTF-8：拒答不猜
}

// MARK: - measure-baseline.sh

/// verdict 字母表的 error token（封閉集合）。同步測試把它與腳本檔頭、README、腳本的輸出點對照。
private let errorTokens = ["<rc>", "sig<N>", "blank", "exec", "json", "shape", "judge"]
private let errorTokenRegex = errorTokens.map { $0 == "<rc>" ? "[1-9][0-9]*" : $0 == "sig<N>" ? "sig[1-9][0-9]*" : $0 }.joined(separator: "|")
private let verdictLine = "^#[0-9]+ [0-9]+ms ((clean|self) tool=[0-9]+|empty tool=0|error\\((\(errorTokenRegex))\\))$"

/// 腳本裡每一個 `error(` 出現（整行註解——去前導 ASCII 空白後以 `#` 開頭——由呼叫端先濾掉）都必須是下面
/// 兩種**輸出述句形狀**之一，否則同步測試紅——**行尾註解裡的字面也紅、沒在同一行閉合的 `error(` 也紅**。
/// 這是刻意的 fail-closed：R6 用「剝掉行尾註解」擋「刪掉的輸出點靠註解補回」，R7 證明那個剝法只是列舉
/// （bash 的 `;#`、`|#`、`)#` 與 python 的無空白 `#` 都是註解卻穿得過去；引號裡的 ` #` 又會誤剝），而 bash 與
/// python 對「`#` 何時是註解」本來就不同——一個逐行的 helper 判不出這一行是哪個語言。所以不剝、不猜：
///   (a) python：整行是 `print(<字面>); sys.exit(0)` 或 `print(<字面> if <條件> else <字面>); sys.exit(0)`，
///       字面是 `"…"`／`f"…"`、條件裡不准有引號與 `#`，而且整行的 `error(` 全部都在那一兩個字面裡
///       （R7 版的 `print\(.*\)` 讓 `print("a"); x = "error(foo)"; sys.exit(0)` 通過——token 進集合卻不輸出；
///       R7 版另一條「雙引號外沒有 `#`」的迴圈在這個形狀下沒有任何一行的判定靠它，依紀律拆掉）；
///   (b) bash：整行是 `valid_row "$row" || row="0 error(<token>)"`（judge 的兜底列）。
/// 它擋的是「輸出點被刪／改名／註解掉而清單沒跟」；它**不證明**那一行可達或會執行（`if False:` 底下換行的
/// print 一樣算），那由每個 token 各自的行為測試扛。這個分類器有自己的 fixture 測試，不靠真腳本的內容驅動。
private enum OutputLine: Equatable {
    case notAnOutputLine
    case tokens([String])
    case unrecognised
}

private func classifyOutputLine(_ raw: String) -> OutputLine {
    let line = raw.trimmingCharacters(in: asciiWhitespace)
    // 偵測用 `error(` 子字串，不用閉合的 regex：R7 版用 `error\(…\)` 偵測，於是沒閉合的 `error(`（續行、`echo "error( $x"`）
    // 被判成「不是輸出行」而靜默略過（R8）。這裡看到 `error(` 就進形狀檢查，沒閉合的自然對不上形狀而紅。
    // （曾另加一條「閉合數 == 出現數」的守衛，變異證明在兩種形狀下都到不了——python 行尾必有 `sys.exit(0)` 的
    // `)`——依紀律拆掉。）
    guard line.contains("error(") else { return .notAnOutputLine }
    let tokens = matches(#"error\(([^)]*)\)"#, in: line)
    if line.range(of: #"^valid_row "\$row" \|\| row="0 error\([a-z]+\)"$"#, options: .regularExpression) != nil {
        return .tokens(tokens)
    }
    let pyShape = try! NSRegularExpression(pattern: ##"^print\((f?"[^"]*")(?: if [^"#]+ else (f?"[^"]*"))?\); sys\.exit\(0\)$"##)   // `"#` 在單 # 的 raw string 裡會提早收尾
    let ns = line as NSString
    guard let m = pyShape.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return .unrecognised }
    var inLiterals = 0
    for g in 1..<m.numberOfRanges where m.range(at: g).location != NSNotFound {   // 不寫死 1...2：group 數變了要紅不要 trap（R9）
        inLiterals += matches(#"error\(([^)]*)\)"#, in: ns.substring(with: m.range(at: g))).count
    }
    guard inLiterals == tokens.count else { return .unrecognised }
    return .tokens(tokens)
}

@Test("同步測試的輸出點分類：兩種形狀認得；`;#` 註解、單一空白註解、輸出行後掛註解、字面外的 error(、多述句同行、非字面的 print、少了前綴的 judge 列、單行 `if False:`、沒閉合的 error( 全部認不出——不剝註解、不猜")
func outputLineClassifierIsDrivenByItsOwnFixture() {
    #expect(classifyOutputLine(#"    print("0 error(exec)"); sys.exit(0)"#) == .tokens(["exec"]))
    #expect(classifyOutputLine(#"print(f"{ms} error({rc})" if rc > 0 else f"{ms} error(sig{-rc})"); sys.exit(0)"#) == .tokens(["{rc}", "sig{-rc}"]))
    #expect(classifyOutputLine(#"    valid_row "$row" || row="0 error(judge)""#) == .tokens(["judge"]))
    #expect(classifyOutputLine("n=0; bad=0") == .notAnOutputLine)
    #expect(classifyOutputLine(#"true;# error(exec)"#) == .unrecognised)                                  // R6-A 的洞：bash 的 ;# 是註解
    #expect(classifyOutputLine(#"x=1 # error(json)"#) == .unrecognised)                                   // 單一空白的行尾註解
    #expect(classifyOutputLine(#"print("0 error(exec)"); sys.exit(0)  # error(json)"#) == .unrecognised)  // 輸出行後面掛註解也紅（`$` 錨點）
    #expect(classifyOutputLine(#"print("0 " + error(exec)); sys.exit(0)"#) == .unrecognised)              // error( 在字面外
    #expect(classifyOutputLine(#"print("a"); x = "error(foo)"; sys.exit(0)"#) == .unrecognised)          // 多述句同行：token 進集合卻不輸出（R8）
    #expect(classifyOutputLine(#"print(x)  # print("0 error(exec)"); sys.exit(0)"#) == .unrecognised)    // 被註解掉的假輸出點：print 的引數不是字面（R8）
    #expect(classifyOutputLine(#"print("0 error(exec)" if x#y else "z"); sys.exit(0)"#) == .unrecognised) // 條件裡的 # 讓 python 把後半當註解
    #expect(classifyOutputLine(#"row="0 error(judge)""#) == .unrecognised)                                // 少了 valid_row 前綴：不是那個形狀
    #expect(classifyOutputLine(#"if False: print("0 error(exec)"); sys.exit(0)"#) == .unrecognised)       // 形狀外一律紅，不假裝能判可達
    #expect(classifyOutputLine(#"echo "error( $line" >&2"#) == .unrecognised)                             // 沒閉合：不是「不是輸出行」（R8）
    #expect(classifyOutputLine(#"    print("0 error("#) == .unrecognised)                                  // 續行的前半
    #expect(classifyOutputLine(#"print("0 error("); sys.exit(0)"#) == .unrecognised)                        // 形狀對、字面沒閉合：沒有這條守衛會安靜地回空 token（R8 verify-fix 的變異抓到）
}

/// `#expect(` 的**第一個引數**（期望值那一側）：從 `#expect(` 之後掃到第一個頂層逗號——括號／中括號／大括號深度為 0、
/// 不在字串裡（含 `\(…)` 內插與 `\"`）。訊息長什麼樣（`Comment(rawValue:)`、裸字串、內插）一概不看：R8
/// 指出 R7 用字面 `, Comment(` 切是形式列舉，換一個訊息多載字面就又回到訊息側。切不出來（括號不平衡、字串沒關）
/// 回 nil，呼叫端當紅；單引數的 `#expect(x)` 整個就是期望值。
private func firstExpectArgument(_ line: String) -> String? {
    guard let start = line.range(of: "#expect(") else { return nil }
    let chars = Array(line[start.upperBound...])
    var depth = 0, i = 0, inString = false
    var interpolation: [Int] = []
    var out = ""
    while i < chars.count {
        let c = chars[i]
        if inString {
            out.append(c)
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]; out.append(n); i += 2
                if n == "(" { interpolation.append(depth); depth += 1; inString = false }
                continue
            }
            if c == "\"" { inString = false }
            i += 1; continue
        }
        switch c {
        case "\"": inString = true
        case "(", "[", "{": depth += 1
        case ")", "]", "}":
            if depth == 0 { return out }
            depth -= 1
            if c == ")", interpolation.last == depth { interpolation.removeLast(); inString = true }
        case ",": if depth == 0 { return out }
        default: break
        }
        out.append(c); i += 1
    }
    return nil
}

@Test("期望值側的切法由 fixture 驅動：Comment(rawValue:)、裸字串、內插、內插裡的巢狀字串與括號、單引數、括號不平衡")
func firstExpectArgumentIsDrivenByItsOwnFixture() {
    #expect(firstExpectArgument(#"#expect(a == ["error(x)"], Comment(rawValue: "error(y) \(z)"))"#) == #"a == ["error(x)"]"#)
    #expect(firstExpectArgument(#"#expect(a == ["error(x)"], "error(y)")"#) == #"a == ["error(x)"]"#)               // 裸字串訊息（R7 的 `, Comment(` 切法在這裡退回整行）
    #expect(firstExpectArgument(#"#expect(f(a, b) == [1, 2] && g("x, y"), "m")"#) == #"f(a, b) == [1, 2] && g("x, y")"#)
    #expect(firstExpectArgument(#"#expect(s == "\(x ? "a, b" : "c")", "m")"#) == #"s == "\(x ? "a, b" : "c")""#)  // 內插裡有引號與逗號
    #expect(firstExpectArgument(#"#expect(s == "q\"uote", "m")"#) == #"s == "q\"uote""#)
    #expect(firstExpectArgument(#"    #expect(a == b)"#) == "a == b")                                            // 單引數：整個是期望值
    #expect(firstExpectArgument(#"#expect(a == (b, "m")"#) == nil)                                               // 括號不平衡：切不出來
    #expect(firstExpectArgument(#"#expect(a == "open, "m")"#) == nil)                                            // 字串沒關
    #expect(firstExpectArgument(#"let x = 1  // not an expect"#) == nil)
}

@Test("字母表同步：腳本檔頭、README、測試的 errorTokens、腳本輸出點四處相等，ERROR_TOKENS 等於它們扣掉 <rc>／sig<N>；含 error( 的行不是輸出述句形狀直接紅；CHANGELOG 三個 verdict 詞在；退役清單 README 與測試一致")
func verdictAlphabetIsStatedIdenticallyEverywhere() throws {
    let root = repoRoot()
    let script = try String(contentsOf: root.appendingPathComponent("scripts/measure-baseline.sh"), encoding: .utf8)
    let readme = try String(contentsOf: root.appendingPathComponent("docs/measurements/README.md"), encoding: .utf8)
    let changelog = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
    let scriptLines = script.components(separatedBy: "\n")

    // 1. 腳本檔頭的「error tokens：」那一行。
    let headerLine = scriptLines.first { $0.hasPrefix("#   error tokens：") }
    let headerTokens = Set((headerLine ?? "").replacingOccurrences(of: "#   error tokens：", with: "")
        .split(separator: " ").map(String.init))
    // 2. 腳本裡的 ERROR_TOKENS（valid_row 執行期用的字面集合）＝ errorTokens 扣掉兩個樣式 token。
    let errorTokensLine = scriptLines.first { $0.hasPrefix("ERROR_TOKENS=\"") } ?? ""
    let runtimeLiterals = Set((matches(#"^ERROR_TOKENS="([^"]*)""#, in: errorTokensLine).first ?? "")
        .split(separator: " ").map(String.init))   // 只取引號裡的（那一行目前沒有行尾註解；帶了含 error( 的註解會被輸出點檢查判紅）
    // 3. 腳本程式碼裡的 error(...) 輸出點：只濾掉整行註解，剩下每一行交給 classifyOutputLine——含 error( 的行
    //    不是兩種輸出述句形狀之一就直接紅（含行尾註解裡的字面；不剝註解、不猜哪個 # 是註解，理由見該函式的 doc）。
    //    **不排除任何程式碼區段**——valid_row 用變數 E_OPEN 比對、不寫 error( 的字面，所以「哪些 error( 不是輸出點」
    //    不需要這裡判斷（R3 用範圍排除 valid_row，R4 指出那等於對排除掉的行假設它們不輸出）。每一個
    //    token 必須是字面 token、{rc} 或 sig{-rc}——別的形狀（例如 $var）不是「略過」而是失敗。
    let codeLines = scriptLines.enumerated().filter { !$0.element.trimmingCharacters(in: asciiWhitespace).hasPrefix("#") }
    var emitted = Set<String>()
    var unrecognised: [String] = []
    var unrecognisedLines: [Int] = []
    for (i, line) in codeLines {
        switch classifyOutputLine(line) {
        case .notAnOutputLine: continue
        case .unrecognised: unrecognisedLines.append(i + 1)
        case .tokens(let raws):
            for raw in raws {
                switch raw {
                case "{rc}": emitted.insert("<rc>")
                case "sig{-rc}": emitted.insert("sig<N>")
                default:
                    if raw.range(of: "^[a-z]+$", options: .regularExpression) != nil { emitted.insert(raw) } else { unrecognised.append(raw) }
                }
            }
        }
    }
    // 4. README 的字母表行：`error(<rc>|sig<N>|…)`。
    // 不跨行：README 散文裡提到沒閉合的 `error(` 時，跨行的 `[^)]*` 會一路吃到別處的 `clean|self|empty`（R8 verify-fix 踩到）。
    let readmeTokens = Set(matches(#"error\(([^)\n]*\|[^)\n]*)\)"#, in: readme).flatMap { $0.split(separator: "|").map(String.init) })
    // 5. 測試自己的 errorTokens。
    let expected = Set(errorTokens)
    let expectedLiterals = expected.subtracting(["<rc>", "sig<N>"])

    #expect(unrecognisedLines.isEmpty, Comment(rawValue: "含 error( 卻不是兩種輸出述句形狀的行（含註解裡的字面）：行 \(unrecognisedLines)"))
    #expect(unrecognised.isEmpty, Comment(rawValue: "腳本裡認不出的 error(...) token（只准字面 token、{rc}、sig{-rc}）：\(unrecognised)"))
    #expect(headerTokens == expected, Comment(rawValue: "腳本檔頭：\(headerTokens.sorted())"))
    #expect(runtimeLiterals == expectedLiterals, Comment(rawValue: "ERROR_TOKENS：\(runtimeLiterals.sorted())"))
    #expect(emitted == expected, Comment(rawValue: "腳本輸出點：\(emitted.sorted())"))
    #expect(readmeTokens == expected, Comment(rawValue: "README：\(readmeTokens.sorted())"))

    // **存在性**檢查（不是執行證明）：每個 token 在本檔**別的**測試裡有一條帶「產生標記」、帶 `#expect(`
    // 的活斷言行（producer 行的定義只有一份，在下方 checkProducerLines 那段：含標記的每一行，不加「以 `#expect(` 開頭」的
    // 合取——R12 只改了 README 那句，這裡留著舊句與那段矛盾，R13），其**第一個引數**（期望值那一側，`firstExpectArgument` 以括號配對切出、切不出來就紅）寫著
    // 它的 tail。它擋的是「把產生點刪掉／改名／註解掉而清單沒跟著改」；它**不證明**那條斷言被執行（`.disabled`、
    // 迴圈跳過都看不到，連本測試自己被停用也看不到）——執行由整份測試檔綠來保證。標記字串執行期拼出（下一行）；
    // 本測試自己的行範圍（從它的 `@Test(` 行到下一個 `@Test(`／`private func`）內不得含那個字面，由下面的斷言守
    // ——宣告行以「整行以 `func NAME(` 開頭且恰好一行」找（NAME 由 #function 取，改名自動跟著走）：子字串比對
    // 取第一個會被更早出現的交叉引用註解劫持、範圍指到別的測試（R8）。標記與 tail 必須在同一實體行（拆行會紅，
    // 訊息會說）。誰（哪個 lens／讀者）抓到什麼、幾個讀者，不在這裡寫——查 issue #63 各輪的 verify comment；
    // 輪次編號是那些 comment 的索引，可以留（R10：規則寫進來之後第一個違反它的是同一段註解）。
    let producesMarker = ["//", "produces", ":"].joined(separator: " ").replacingOccurrences(of: "produces :", with: "produces:")
    let rawSource = try String(contentsOf: URL(fileURLWithPath: "\(#filePath)"), encoding: .utf8)
    let sourceLines = rawSource.components(separatedBy: "\n")
    let selfName = String(#function.prefix { $0 != "(" })
    let declarationLines = sourceLines.indices.filter { sourceLines[$0].hasPrefix("func \(selfName)(") }
    let funcLine = try #require(declarationLines.count == 1 ? declarationLines[0] : nil,
                                "同步測試的宣告行必須恰好一行（整行以 func NAME( 開頭），得 \(declarationLines.count) 行")
    let selfStart = try #require(sourceLines[..<funcLine].lastIndex { $0.hasPrefix("@Test(") }, "同步測試的宣告行上面沒有 @Test( 行")
    let selfEnd = sourceLines[(funcLine + 1)...].firstIndex { $0.hasPrefix("@Test(") || $0.hasPrefix("private func ") } ?? sourceLines.count
    let markerInsideSelf = (selfStart..<selfEnd).filter { sourceLines[$0].contains(producesMarker) }.map { $0 + 1 }
    #expect(markerInsideSelf.isEmpty, Comment(rawValue: "產生標記出現在同步測試自己的行範圍內（不得自問自答）：行 \(markerInsideSelf)"))
    // 上一條斷言一成立，自身範圍內就沒有帶標記的行，所以這裡不再排除自身範圍——R7 證明那個排除條件在任何
    // 世界狀態下都不改變 verdict（訊息可能多一筆，但那條路徑上測試已因上一條斷言而紅），驅動不了的守衛拆掉。
    let producerLines = sourceLines.enumerated().filter { $0.element.contains(producesMarker) }
    // 標記後面列的名字集合必須**等於**該行期望值那一側的 tail 集合——雙向、不准空、不准重複。R6 只做單向
    // （每個名字在行內某處出現），於是漏列、重複、一個名字都不寫、字面只在失敗訊息裡都過得去（R7）；R7 用
    // `, Comment(` 切期望值側，裸字串訊息又讓字面回到訊息側（R8）——現在用第一個引數，與訊息形式無關。
    // 這段抽成 checkProducerLines（純函式）：真檔與一條常駐的負向 fixture 走同一支——R9 把同步測試裡的切法退成整行、
    // 全綠（四條真 producer 的訊息側都不含 error( 字面），守衛有效但接線無人驅動。producer 行 = 含標記的每一行，
    // 不再另加「以 #expect( 開頭」的合取（R10：那個合取無驅動且 fail-open——一行 `let x = 1` 掛著產生標記會被
    // 靜默濾掉；現在它會以 unsplittable 紅、帶行號）。
    let producers = checkProducerLines(producerLines.map { (line: $0.offset + 1, text: $0.element) }, marker: producesMarker)
    #expect(producers.unsplittable.isEmpty, Comment(rawValue: "帶產生標記的行不是 #expect 行、或第一個引數切不出來（括號不平衡、字串沒關）：行 \(producers.unsplittable)"))
    #expect(producers.suffixMismatch.isEmpty, Comment(rawValue: "產生標記後的名字集合與同一行期望值側的 tail 集合不相等（雙向、不空、不重複）：\(producers.suffixMismatch)"))
    #expect(producers.missingProductions.isEmpty, Comment(rawValue: "沒有帶產生標記、且 #expect 第一個引數寫著它的活斷言：\(producers.missingProductions)"))

    // 七個 metadata 欄位名：CorpusScanner 的常數、README 表、查詢檔檔頭三處同一份。
    let scanner = try String(contentsOf: root.appendingPathComponent("Sources/LTMIndex/CorpusScanner.swift"), encoding: .utf8)
    let constantBody = matches(#"static let toolMetadataFields = \[([^\]]*)\]"#, in: scanner).first ?? ""
    let constantFields = matches(#""([a-z_]+)""#, in: constantBody)
    let readmeFieldRow = readme.components(separatedBy: "\n").first { $0.contains("七個 metadata 欄位") && $0.hasPrefix("|") } ?? ""
    let readmeFirstCell = readmeFieldRow.components(separatedBy: "|").dropFirst().first ?? ""   // 只看「位置」那一格
    let readmeFields = matches(#"`([a-z_]+)`"#, in: readmeFirstCell).filter { $0 != "tool_use" }
    let queryHeader = try String(contentsOf: root.appendingPathComponent("scripts/baseline-queries.txt"), encoding: .utf8)
        .components(separatedBy: "\n").filter { $0.trimmingCharacters(in: asciiWhitespace).hasPrefix("#") }.joined(separator: "\n")   // 與行定義同：先 trim 再看 #
    // 檔頭那一段的形狀是「`CorpusScanner.toolMetadataFields`：a / b / … / g，各取前 N 字元」，可能跨行（續行的 `#` 前可有縮排，
    // 反折時一併剝掉——R10：先前只接欄首的 `#`，縮排續行會讓正確的檔頭紅在欄位名）。N 不寫死在 regex 裡（R10）：
    // 截斷長度 `toolMetadataFieldLimit` 從 CorpusScanner 讀，README、腳本檔頭、查詢檔檔頭三處各自對照它，紅在對的地方。
    let headerJoined = joinHeaderContinuations(queryHeader)
    let headerRe = try! NSRegularExpression(pattern: #"toolMetadataFields`：([a-z_/]+)，各取前([0-9]+)字元"#)
    let headerNS = headerJoined as NSString
    let headerMatch = headerRe.firstMatch(in: headerJoined, range: NSRange(location: 0, length: headerNS.length))
    let headerFields = headerMatch.map { headerNS.substring(with: $0.range(at: 1)).split(separator: "/").map(String.init) } ?? []
    let headerLimit = headerMatch.map { headerNS.substring(with: $0.range(at: 2)) } ?? ""
    let limit = try #require(matches(#"static let toolMetadataFieldLimit = ([0-9]+)"#, in: scanner).first, "CorpusScanner 裡找不到 toolMetadataFieldLimit")
    #expect(constantFields.count == 7, Comment(rawValue: "常數：\(constantFields)"))
    #expect(Set(readmeFields) == Set(constantFields), Comment(rawValue: "README 表：\(readmeFields)"))
    #expect(Set(headerFields) == Set(constantFields), Comment(rawValue: "查詢檔檔頭少了：\(Set(constantFields).subtracting(headerFields).sorted())"))
    #expect(headerLimit == limit, Comment(rawValue: "查詢檔檔頭的截斷長度 \(headerLimit) ≠ toolMetadataFieldLimit \(limit)"))
    let readmeLimits = limitMentions(readme), scriptLimits = limitMentions(script)
    #expect(readmeLimits == [limit] && scriptLimits == [limit], Comment(rawValue: "README／腳本檔頭出現的「N 字元」不全等於 toolMetadataFieldLimit \(limit)：README \(readmeLimits.sorted()) 腳本 \(scriptLimits.sorted())"))
    // R9 的收穫要有鎖：查詢內容只能經 process substitution 的管線給指紋 python 與迴圈——herestring 在 bash 3.2 會寫
    // $TMPDIR 暫存檔、而且會補尾端換行讓 `|| [ -n "$raw" ]` 再度死掉（R10：兩處退回去全綠）。
    // 只數程式碼行（整行註解濾掉；codeText 與下方離開碼那段共用）：R11 把迴圈改回 `< "$QF"` 再放一條含原字面的註解，
    // 整檔字面計數照樣 2。這條鎖**是拼法列舉，不是「只開一次」的證明**（R13：把鍵從 `< "$QF"` 換成識別碼 `$QF` 之後，
    // `cat "$HERE/baseline-queries.txt"`、`cat "${LTM_BASELINE_QUERIES:-…}"`、`wc -l < "$HERE/…"` 照樣穿過——鍵換了、形狀沒換，
    // CLAUDE.md #34／#37 那句）。腳本裡能指到查詢檔的拼法有三種，三種各釘一個次數：識別碼 `$QF`／`${QF}` 7 次（-f/-r 那行 3、
    // read 1、三句錯誤訊息 3）、檔名字面 `baseline-queries.txt` 1 次（QF 的預設值）、環境變數名 `LTM_BASELINE_QUERIES` 4 次
    // （re-exec 白名單那一行 3 次＋QF 賦值 1 次）；多一次就是多一條路徑或多一處訊息，都要來這裡對帳。它守得住的較窄陳述是「用這三種拼法之一再開一次會紅」；
    // 先把路徑存進第四個名字再開，這裡看不到——要判準版得觀察 open 系統呼叫，不可攜，不做。README 的量測段用同一句話。
    // 呼叫端 shell 環境那一族（BASH_ENV、SHELLOPTS、匯出函式、readonly、PS4、PYTHONPATH）由前兩行程式碼一次清掉：`builtin set +x`
    // 再 `builtin exec /usr/bin/env -i <白名單> /bin/bash -- "$0" "$@"`。R13 對這一族逐名字指名 builtin，R14 一輪再冒五個同名
    // ——那些拼法在 re-exec 之後驅動不了，拆掉；這裡釘的是「前兩行就是那兩行」（行為由 xtrace 測試的 exec／set 同名函式臂驅動）。
    let codeText = codeLines.map(\.element).joined(separator: "\n")
    let firstTwo = codeLines.prefix(2).map(\.element)
    #expect(firstTwo.first == "builtin set +x" && (firstTwo.last ?? "").hasPrefix("case \"${LTM_MB_CLEAN-}\" in 1) ;; *) builtin exec /usr/bin/env -i LTM_MB_CLEAN=1 "), Comment(rawValue: "腳本的前兩行程式碼必須是 builtin set +x 與 re-exec 那一行：\(firstTwo)"))
    let procSubs = codeText.components(separatedBy: "< <(printf '%s' \"$QF_CONTENT\")").count - 1
    let qfRefs = try! NSRegularExpression(pattern: #"\$\{?QF\b"#).numberOfMatches(in: codeText, range: NSRange(location: 0, length: (codeText as NSString).length))
    let fileNameRefs = codeText.components(separatedBy: "baseline-queries.txt").count - 1
    let envNameRefs = codeText.components(separatedBy: "LTM_BASELINE_QUERIES").count - 1
    let hasHerestring = codeText.contains("<<<")
    #expect(procSubs == 2 && qfRefs == 7 && fileNameRefs == 1 && envNameRefs == 4 && !hasHerestring, Comment(rawValue: "查詢檔的三種拼法在程式碼行出現：識別碼 \(qfRefs)（應為 7）、檔名字面 \(fileNameRefs)（應為 1）、環境變數名 \(envNameRefs)（應為 4：白名單行 3＋QF 賦值 1）——多一次就是多一條讀取路徑或訊息；process substitution \(procSubs) 處（應為 2）；herestring：\(hasHerestring)"))
    // 字元比對一律字面集合、不用 `[X-Y]` range——含字母的 range 在 bash 3.2 隨 locale 排序而變（指紋檢查的 fpUpper 臂驅動）；
    // 純數字 range 找不到反例（R14），這裡釘的是同檔一致寫法。pin 認任何 `[`、可選 `!`／`^`、英數、`-`、英數 的形式
    // （R13 版只認 `[0-9]`／`[!0-9]` 兩種拼法，`[^0-9]`、`[0-9a-f]` 穿得過，R14）。
    let charRanges = matches(#"(\[[!^]?[0-9A-Za-z]-[0-9A-Za-z])"#, in: codeText)
    #expect(charRanges.isEmpty, Comment(rawValue: "程式碼行裡有 \(charRanges.count) 處 [X-Y] 形式的 range：\(charRanges)，要改成字面集合"))

    // 離開碼：檔頭那一行列的數字 ＝ 程式碼裡 exit 的數字 ∪ {0}。
    let exitHeaderLine = scriptLines.first { $0.hasPrefix("# 離開碼（") } ?? ""
    let headerExits = Set((exitHeaderLine.components(separatedBy: "：").last ?? "").split(separator: " ").compactMap { Int($0) })
    // 行尾註解裡的 `exit N` 也算——多出來的會讓兩邊不等而紅，與輸出點同一條紀律：不剝、不猜。另一個方向也要關：
    // `exit "$VAR"` 對 `exit N` 的比對隱形（R8 變異綠），所以每一個 bash 的 `exit` 字（`sys.exit(` 不算）後面
    // 都必須是字面數字，否則紅。
    let codeExits = Set(matches(#"(?<![.\w])exit ([0-9]+)"#, in: codeText).compactMap { Int($0) }).union([0])
    let exitWords = try! NSRegularExpression(pattern: #"(?<![.\w])exit\b"#).numberOfMatches(in: codeText, range: NSRange(location: 0, length: (codeText as NSString).length))
    let literalExits = matches(#"(?<![.\w])exit ([0-9]+)"#, in: codeText).count
    #expect(exitWords == literalExits, Comment(rawValue: "腳本裡有 \(exitWords) 個 exit，其中 \(literalExits) 個後面是字面數字——經變數的離開對同步檢查隱形，一律紅"))
    #expect(headerExits == codeExits, Comment(rawValue: "檔頭：\(headerExits.sorted()) 程式碼：\(codeExits.sorted())"))
    // README 的兩個數字（每條純量上限、目前條數）由這裡對照常數與真檔，不各存一份（R8）。
    let queryReport = try checkQueryFile(try Data(contentsOf: root.appendingPathComponent("scripts/baseline-queries.txt")))
    let readmeHasCap = readme.contains("每條不超過 \(maxQueryScalars) 個純量"), readmeHasCount = readme.contains("目前的 \(queryReport.count) 條")   // 先算成 Bool：失敗時不把整份 README 展開
    #expect(readmeHasCap, "README 的純量上限與 maxQueryScalars 不同")
    #expect(readmeHasCount, Comment(rawValue: "README 寫的目前條數與真檔（\(queryReport.count)）不同"))

    // 退役清單：README 的「…」列與測試的 retired 陣列是同一份，不能各自漂移。
    let readmeRetiredLine = readme.components(separatedBy: "\n").first { $0.hasPrefix("「") && $0.contains("」「") } ?? ""
    let readmeRetired = Set(matches(#"「([^」]+)」"#, in: readmeRetiredLine))
    #expect(readmeRetired == Set(retired), Comment(rawValue: "README 退役清單：\(readmeRetired.sorted())"))
    // 先算成 Bool 再 #expect：失敗時不把整份檔案展開進測試輸出（同檔對真查詢檔的紀律）。
    let scriptNormalised = script.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    for word in ["clean tool=<n>", "self tool=<n>", "empty tool=0"] {
        let inReadme = readme.contains(word), inScript = scriptNormalised.contains(word)
        #expect(inReadme, Comment(rawValue: "README 缺 verdict：\(word)"))
        #expect(inScript, Comment(rawValue: "腳本檔頭缺 verdict：\(word)"))
    }
    let changelogHasWords = changelog.contains("clean|self|empty")
    #expect(changelogHasWords, "CHANGELOG 缺三個 verdict 詞")
}

private struct ProducerReport: Equatable {
    var unsplittable: [Int] = []          // 實體行號：切不出第一個引數、或根本不是 #expect 行
    var suffixMismatch: [String] = []
    var missingProductions: [String] = []
}

private func tailName(_ literal: String) -> String {
    literal == "error(7)" ? "rc" : literal == "error(sig9)" ? "sig" : String(literal.dropFirst(6).dropLast())
}

/// 對一組 producer 行（含產生標記的每一行；`#expect(` 可以縮排、也可以不存在——不存在就是 unsplittable）做三件事：
/// 切出 `#expect(` 的第一個引數（切不出來或沒有 `#expect(` → unsplittable）、
/// 標記後的名字集合 == 該引數裡的 tail 集合（雙向、不空、不重複）、每個 error token 都有某一行的第一個引數寫著它。
/// 字面只出現在訊息側的行在這裡會被判成 mismatch＋missing——那正是 R7→R8 反覆重開的洞。
private func checkProducerLines(_ lines: [(line: Int, text: String)], marker: String) -> ProducerReport {
    var r = ProducerReport()
    var sides: [String] = []
    for (n, line) in lines {
        guard let m = line.range(of: marker) else { r.unsplittable.append(n); continue }
        let names = line[m.upperBound...].split(separator: " ").map(String.init)
        // 整行交給 firstExpectArgument：它在第一個頂層逗號或收尾就回，永遠到不了標記（R10：切到標記之前是 no-op）。
        guard let side = firstExpectArgument(line) else { r.unsplittable.append(n); continue }
        sides.append(side)
        let tails = Set(matches(#"(error\([^)]*\))"#, in: side).map(tailName))
        if names.isEmpty || Set(names).count != names.count || Set(names) != tails {
            r.suffixMismatch.append("行 \(n)：標記後 \(names) vs 期望值側 \(tails.sorted())")
        }
    }
    let text = sides.joined(separator: "\n")
    let wanted = errorTokens.map { $0 == "<rc>" ? "error(7)" : $0 == "sig<N>" ? "error(sig9)" : "error(\($0))" }
    r.missingProductions = wanted.filter { !text.contains($0) }
    return r
}

@Test("producer 行檢查由常駐的負向 fixture 驅動：裸字串訊息、字面只在訊息側 → mismatch＋missing；漏列名字、括號不平衡各自紅；全部合格 → 空報告")
func producerLineChecksAreDrivenByTheirOwnFixture() {
    let mk = ["//", "produces", ":"].joined(separator: " ").replacingOccurrences(of: "produces :", with: "produces:")
    let good = [
        #"#expect(a == ["error(7)", "error(sig9)", "error(json)", "error(shape)"], Comment(rawValue: x))  "# + mk + " rc sig json shape",
        #"#expect(b == ["error(blank)"], "bare message with error(shape) in it")  "# + mk + " blank",
        #"#expect(c.status == 1 && c.rows == ["error(exec)"], Comment(rawValue: "rc=\(c.status)"))  "# + mk + " exec",
        ##"#expect(d == ["#1 0ms error(judge)"], Comment(rawValue: "\(label)"))  "## + mk + " judge",   // `"#` 在單 # 的 raw string 裡會收尾
    ]
    func numbered(_ xs: [String]) -> [(line: Int, text: String)] { xs.enumerated().map { (line: ($0.offset + 1) * 10, text: $0.element) } }
    #expect(checkProducerLines(numbered(good), marker: mk) == ProducerReport())
    // 裸字串訊息、字面只在訊息側（R8 的 `, Comment(` 切法在這裡退回整行而過；R9 指出接線無人驅動）。
    let messageOnly = good.dropLast() + [#"#expect(d.status == 1, "no longer checks the row: error(judge) rc=\(d.status)")  "# + mk + " judge"]
    let r1 = checkProducerLines(numbered(Array(messageOnly)), marker: mk)
    #expect(r1.suffixMismatch.count == 1 && r1.missingProductions == ["error(judge)"], Comment(rawValue: "\(r1)"))
    let omitted = good.dropFirst() + [#"#expect(a == ["error(7)", "error(sig9)", "error(json)", "error(shape)"], Comment(rawValue: x))  "# + mk + " rc sig shape"]
    #expect(checkProducerLines(numbered(Array(omitted)), marker: mk).suffixMismatch.count == 1)
    let unbalanced = good.dropLast() + [#"#expect(d == ["error(judge)", Comment(rawValue: x))  "# + mk + " judge"]
    #expect(checkProducerLines(numbered(Array(unbalanced)), marker: mk).unsplittable == [40])          // 帶行號（R10）
    let notAnExpect = good + ["let x = 1  " + mk + " blank"]
    #expect(checkProducerLines(numbered(Array(notAnExpect)), marker: mk).unsplittable == [50])         // 含標記但不是 #expect 行：紅，不是靜默濾掉（R10）
    #expect(checkProducerLines([(line: 7, text: "#expect(a == b)")], marker: mk).unsplittable == [7])  // 沒有標記的行進來也紅
}

/// 檔頭續行反折：下一行開頭（可有縮排）的 `#` 連同換行拿掉，再去掉所有空格。R10 放寬成也接縮排的 `#`，R11 指出它
/// 無驅動（真檔頭沒有縮排續行）——所以抽出來、給它 fixture。
private func joinHeaderContinuations(_ header: String) -> String {
    header.replacingOccurrences(of: "\n[ \t]*#", with: "", options: .regularExpression).replacingOccurrences(of: " ", with: "")
}

@Test("檔頭續行反折由 fixture 驅動：欄首與縮排的 `#` 續行都接得起來")
func headerContinuationJoiningIsDrivenByItsOwnFixture() {
    #expect(joinHeaderContinuations("# `x`：a / b /\n# c，各取前 200 字元") == "#`x`：a/b/c，各取前200字元")
    #expect(joinHeaderContinuations("# `x`：a / b /\n   # c，各取前 200 字元") == "#`x`：a/b/c，各取前200字元")   // 縮排續行（R10 的放寬）
    #expect(joinHeaderContinuations("# a\nb") == "#a\nb")   // 不是 # 開頭的下一行不動（換行留著）
}

/// 散文裡對截斷長度的複述：「N 字元」（有無空格都算）。這是形式比對——「200 個字元」「200 字」這類寫法看不見，
/// 所以 README／腳本檔頭要用這個形式寫；fixture 驅動有空格與無空格兩臂（R12）。
private func limitMentions(_ text: String) -> Set<String> { Set(matches(#"([0-9]+) ?字元"#, in: text)) }

@Test("截斷長度複述的擷取由 fixture 驅動：有空格、無空格、括號裡；「N 個字元」不算")
func limitMentionExtractionIsDrivenByItsOwnFixture() {
    #expect(limitMentions("上限（200 字元）與 200字元；另有 30 個字元") == ["200"])
    #expect(limitMentions("前 400字元") == ["400"])
    #expect(limitMentions("沒有數字").isEmpty)
}

private func matches(_ pattern: String, in text: String) -> [String] {
    let re = try! NSRegularExpression(pattern: pattern)
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
}

private struct ScriptRun {
    let status: Int32
    let stdout: String
    let stderr: String
    /// stdout 第一行是 set 行（格式以腳本檔頭為準；`setLine(_:k:)` 重算），之後才是列。
    var setLine: String { stdout.split(separator: "\n").first.map(String.init) ?? "" }
    var rows: [String] { Array(stdout.split(separator: "\n").map(String.init).dropFirst()) }
    var combined: String { stdout + stderr }
}

/// 與腳本同一個指紋：對非註解行（同一個 ASCII trim 定義）逐行 sha256（行＋"\n"），取前 12 個 hex。
private func setFingerprint(_ text: String) -> String {
    var h = SHA256()
    for line in nonCommentLines(text) { h.update(data: Data((line + "\n").utf8)) }
    return "set sha256:" + h.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
}

/// 腳本印的第一行：指紋加這一次的 k。
private func setLine(_ text: String, k: String = "3") -> String { setFingerprint(text) + " k=" + k }

/// `#N <ms>ms ` 之後的全部（verdict 含 `tool=<n>`）。
private func tail(_ line: String) -> String {
    line.split(separator: " ", maxSplits: 2).last.map(String.init) ?? ""
}

/// 建一個把 argv 記到 `argv.log`、先把 stdin 讀光、再依查詢（最後一個參數）回應的 stub。
/// `cat >/dev/null` 是刻意的：ltm 的 stdin 若是查詢內容，stub 會把剩下的行吃掉，列數就少了。它驅動得到的是
/// 「judge 自己的 stdin 是 /dev/null」（R7 起）；python 端另外對 ltm 設的 `stdin=DEVNULL` 從此是分不出來的縱深
/// （R8 變異：拿掉它列數不變）。`raw` 是整段 bash，給訊號自殺這類回應用。
private func makeStub(in dir: URL, responses: [String: String], exits: [String: Int32] = [:],
                      raw: [String: String] = [:]) throws -> URL {
    let stub = dir.appendingPathComponent("ltm")
    let log = dir.appendingPathComponent("argv.log").path
    var cases = ""
    for (q, body) in responses.sorted(by: { $0.key < $1.key }) {
        cases += "  \"\(q)\") printf '%s\\n' '\(body)' ;;\n"
    }
    for (q, code) in exits.sorted(by: { $0.key < $1.key }) {
        cases += "  \"\(q)\") exit \(code) ;;\n"
    }
    for (q, body) in raw.sorted(by: { $0.key < $1.key }) {
        cases += "  \"\(q)\") \(body) ;;\n"
    }
    try """
    #!/bin/bash
    cat >/dev/null
    printf '%s\\x1f' "$@" >> '\(log)'; printf '\\n' >> '\(log)'
    q="${@: -1}"
    case "$q" in
    \(cases)  *) printf '[{"snippet":"一段實質內容","uuid":"u"}]\\n' ;;
    esac
    """.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    return stub
}

private func runScript(queries: URL, stub: URL, k: String = "3", viaBashX: Bool = false,
                       ltmBinOverride: String? = nil, pathOverride: String? = nil, pathPrefix: String? = nil,
                       extraEnv: [String: String] = [:], unsetting: [String] = [],
                       scriptOverride: URL? = nil, bashOperand: String? = nil, cwd: URL? = nil, extraArgs: [String] = []) throws -> ScriptRun {
    let script = scriptOverride ?? repoRoot().appendingPathComponent("scripts/measure-baseline.sh")
    let process = Process()
    if let bashOperand {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")   // `bash <operand>`：$0 就是 operand（裸名時 bash 先看 cwd 再搜 PATH）
        process.arguments = [bashOperand, k] + extraArgs
    } else if viaBashX {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-x", script.path, k] + extraArgs
    } else {
        process.executableURL = script
        process.arguments = [k] + extraArgs
    }
    if let cwd { process.currentDirectoryURL = cwd }
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "LTM_ANCHOR_KEY")
    env["LTM_BIN"] = ltmBinOverride ?? stub.path
    env["LTM_BASELINE_QUERIES"] = queries.path
    if let pathOverride { env["PATH"] = pathOverride }
    if let pathPrefix { env["PATH"] = pathPrefix + ":" + (env["PATH"] ?? "/usr/bin:/bin") }
    for (k, v) in extraEnv { env[k] = v }
    for k in unsetting { env.removeValue(forKey: k) }
    process.environment = env
    let out = Pipe(), err = Pipe()
    process.standardOutput = out; process.standardError = err
    try process.run(); process.waitUntilExit()
    return ScriptRun(
        status: process.terminationStatus,
        stdout: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-baseline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 測試行程 PATH 上真正的 python3（假 python3 對非 judge 的呼叫要轉交給它）。
private func realPython3() -> String {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    for dir in path.split(separator: ":") {
        let candidate = "\(dir)/python3"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return "/usr/bin/python3"
}

/// 一個 PATH 目錄，只放呼叫端指定的假命令（腳本自 R10 起不再需要 `dirname`，鷹架已拆）。
/// `judgeFakes` 是假 python3 對 **judge 呼叫**（`python3 -c …`）的行為；其他呼叫（算查詢集指紋的
/// `python3 - <file>`）轉交真的 python3——要模擬的是 judge 掛掉，不是整個 python 壞掉。
private func makeBinDir(in dir: URL, judgeFakes: [String: String]) throws -> URL {
    let bin = dir.appendingPathComponent("bin-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for (name, body) in judgeFakes {
        let f = bin.appendingPathComponent(name)
        try "#!/bin/bash\nif [ \"$1\" = \"-c\" ]; then\n\(body)\nfi\nexec '\(realPython3())' \"$@\"\n".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    }
    return bin
}

@Test("measure-baseline.sh：invocation 形狀固定、行定義與測試一致、clean/self/empty 與 tool=<n> 各自會動、self 摺疊空白與大小寫、輸出不含查詢與命中")
func measureBaselinePrintsOnlyIndicesAndVerdicts() throws {
    let script = repoRoot().appendingPathComponent("scripts/measure-baseline.sh")
    let attrs = try FileManager.default.attributesOfItem(atPath: script.path)
    #expect(((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0, "腳本沒有執行位元")

    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // 合成檔（不碰真檔）：縮排註解與純空白行都不算條目；CRLF、tab 與尾隨空白要被剝掉；
    // 最後一行沒有換行也要量到。
    // #1 乾淨（實質命中、無工具 chunk）；#2 self：查詢原文在散文之後的工具殘影裡（tool=1）；
    // #3 self：查詢原文被引述進散文、空白摺疊後才對得上、沒有工具標記（tool=0）；#4 零命中；
    // #5 兩個工具 chunk 但都不含查詢原文 → clean tool=2（工具 chunk 本身不是污染訊號，R2）；
    // #6 self：只差大小寫（casefold）；
    // #7 ltm 回了 k+1 筆、只有第 k+1 筆含原文且帶工具標記 → clean tool=0：judge 只看前 k 筆，「前 k 名」的語意
    //    由 judge 自己截、不靠 ltm 自律（R7）；
    // #8 第 k+1 筆是畸形的（snippet 不是字串）→ 仍是 clean tool=0：形狀檢查也只看前 k 筆（R8：先前切在檢查之後）。
    let queries = dir.appendingPathComponent("q.txt")
    try "# header\n   # indented comment\nZQXJ-CLEAN-ONE\n   \nZQXJ-SELF-TWO\r\n\t ZQXJ QUOTE THREE  \nZQXJ-EMPTY-FOUR\nZQXJ-TOOLONLY-FIVE\nzqxj lower six\nZQXJ-OVERFLOW-SEVEN\nZQXJ-OVERFLOW-EIGHT"
        .write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [
        "ZQXJ-SELF-TWO": #"[{"snippet":"先說明一下\n⟨tool Bash command=ltm query ZQXJ-SELF-TWO --k 5⟩","uuid":"u"},{"snippet":"別的","uuid":"v"}]"#,
        "ZQXJ QUOTE THREE": #"[{"snippet":"使用者說：第三條是 ZQXJ  QUOTE\nTHREE 沒錯","uuid":"u"}]"#,
        "ZQXJ-EMPTY-FOUR": "[]",
        "ZQXJ-TOOLONLY-FIVE": #"[{"snippet":"⟨tool Bash command=swift test⟩","uuid":"u"},{"snippet":"⟨tool Read file_path=x⟩","uuid":"v"}]"#,
        "zqxj lower six": #"[{"snippet":"⟨tool Bash command=ltm query ZQXJ Lower SIX --k 5⟩","uuid":"u"}]"#,
        "ZQXJ-OVERFLOW-SEVEN": #"[{"snippet":"一","uuid":"a"},{"snippet":"二","uuid":"b"},{"snippet":"三","uuid":"c"},{"snippet":"⟨tool Bash command=ltm query ZQXJ-OVERFLOW-SEVEN⟩","uuid":"d"}]"#,
        "ZQXJ-OVERFLOW-EIGHT": #"[{"snippet":"一","uuid":"a"},{"snippet":"二","uuid":"b"},{"snippet":"三","uuid":"c"},{"snippet":null,"uuid":"d"}]"#,
    ])

    let run = try runScript(queries: queries, stub: stub)
    #expect(run.status == 0, Comment(rawValue: "rc=\(run.status) err=\(run.stderr)"))
    let fixtureText = try String(contentsOf: queries, encoding: .utf8)
    #expect(run.setLine == setLine(fixtureText), Comment(rawValue: "第一行：\(run.setLine)"))
    #expect(run.setLine.range(of: "^set sha256:[0-9a-f]{12} k=[0-9]+$", options: .regularExpression) != nil)
    #expect(run.rows.count == 8, Comment(rawValue: run.stdout))
    #expect(run.rows.allSatisfy { $0.range(of: verdictLine, options: .regularExpression) != nil }, Comment(rawValue: run.stdout))
    #expect(run.rows.map(tail) == ["clean tool=0", "self tool=1", "self tool=0", "empty tool=0", "clean tool=2", "self tool=1", "clean tool=0", "clean tool=0"], Comment(rawValue: run.stdout))
    #expect(run.rows.map { $0.prefix(3) } == ["#1 ", "#2 ", "#3 ", "#4 ", "#5 ", "#6 ", "#7 ", "#8 "], Comment(rawValue: run.stdout))
    // 查詢文字與 snippet 都不得出現在任何輸出。
    #expect(!run.combined.lowercased().contains("zqxj") && !run.combined.contains("實質內容") && !run.combined.contains("說明"))

    // ltm 每次都收到同一個形狀：query --all-projects --k <k> --json -- <去掉 CR 與前後空白的查詢>。
    let log = try String(contentsOf: dir.appendingPathComponent("argv.log"), encoding: .utf8)
    let calls = log.split(separator: "\n").map { $0.split(separator: "\u{1f}", omittingEmptySubsequences: false).dropLast().map(String.init) }
    let expected = ["ZQXJ-CLEAN-ONE", "ZQXJ-SELF-TWO", "ZQXJ QUOTE THREE", "ZQXJ-EMPTY-FOUR", "ZQXJ-TOOLONLY-FIVE", "zqxj lower six", "ZQXJ-OVERFLOW-SEVEN", "ZQXJ-OVERFLOW-EIGHT"]
        .map { ["query", "--all-projects", "--k", "3", "--json", "--", $0] }
    #expect(calls == expected, Comment(rawValue: log))

    // k 進了第一行：換一個 k，指紋不變、第一行變。（放在 argv 斷言之後，因為這一跑也會寫 argv.log。）
    let k7 = try runScript(queries: queries, stub: stub, k: "7")
    #expect(k7.setLine == setLine(fixtureText, k: "7") && k7.setLine != run.setLine, Comment(rawValue: k7.setLine))
}

@Test("measure-baseline.sh：行定義只認 ASCII 空白，LC_ALL=C 與 UTF-8 下列數相同、與測試的 nonCommentLines 一致；只含 U+3000 的條目報 error(blank) 而不是 self")
func measureBaselineLineDefinitionIsLocaleIndependent() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    // 一個只有 U+3000 的行，與一個以 U+3000 縮排的「註解」：兩者對腳本與測試都**是**條目（都不剝 U+3000）。
    // 最後兩行是 CRLF：Swift 端若用 split(separator: "\n") 會把 CRLF 當一個 grapheme、不切，兩邊就分岔。
    let text = "# header\nZQXJ-A\n\u{3000}\n\u{3000}# not a comment\nZQXJ-B\nZQXJ-C\r\nZQXJ-D\r\n"
    let queries = dir.appendingPathComponent("q.txt")
    try text.write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [:])
    let swiftCount = nonCommentLines(text).count
    #expect(swiftCount == 6)
    for locale in ["C", "en_US.UTF-8"] {
        let run = try runScript(queries: queries, stub: stub, extraEnv: ["LC_ALL": locale, "LANG": locale])
        #expect(run.rows.count == swiftCount, Comment(rawValue: "LC_ALL=\(locale): \(run.stdout)"))
        // 只有 U+3000 的那一行：行定義算條目，但 judge 的 Unicode 空白摺疊會得到空針——那是 error(blank)，
        // 不能是 self。U+3000 縮排的「# not a comment」摺疊後不是空的，照常量（clean）。
        #expect(run.rows.map(tail) == ["clean tool=0", "error(blank)", "clean tool=0", "clean tool=0", "clean tool=0", "clean tool=0"], Comment(rawValue: "LC_ALL=\(locale): \(run.stdout)"))  // produces: blank
        #expect(run.status == 1, Comment(rawValue: "LC_ALL=\(locale): rc=\(run.status)"))
        #expect(run.setLine == setLine(text), Comment(rawValue: "LC_ALL=\(locale): \(run.setLine)"))
    }
    // blank 那一行不跑 ltm：stub 被呼叫的次數 = 6 條 − 1 條 blank，兩個 locale 各跑一次。
    let calls = (try? String(contentsOf: dir.appendingPathComponent("argv.log"), encoding: .utf8))?.split(separator: "\n").count ?? -1
    #expect(calls == 2 * (swiftCount - 1), "ltm 被呼叫 \(calls) 次，blank 那一行不該進 ltm")

    // judge 的 argv 解碼（R14，codex）：Linux 上 LC_ALL=C 加 PYTHONUTF8=0 加 PYTHONCOERCECLOCALE=0 時 python 把 argv 解成 surrogate、
    // snippet 卻是真 Unicode，非 ASCII 查詢逐字命中也判 clean。腳本改成還原 bytes 再明確以 UTF-8 解。macOS 的 python fs encoding
    // 恆為 UTF-8，這一臂在本機驅動不到——鑑別力只在 Linux（同 fd3 探針「只在 bash 3.2 有鑑別力」的註記）。
    let nonASCII = "ZQXJ-查詢-甲\n"
    let nonASCIIFile = dir.appendingPathComponent("nonascii.txt")
    try nonASCII.write(to: nonASCIIFile, atomically: true, encoding: .utf8)
    let echoStub = try makeStub(in: dir, responses: ["ZQXJ-查詢-甲": #"[{"snippet":"命中裡逐字含 ZQXJ-查詢-甲 這條","uuid":"u"}]"#])
    let cLocale = try runScript(queries: nonASCIIFile, stub: echoStub, extraEnv: ["LC_ALL": "C", "LANG": "C", "PYTHONUTF8": "0", "PYTHONCOERCECLOCALE": "0"])
    #expect(cLocale.status == 0 && cLocale.rows.map(tail) == ["self tool=0"], Comment(rawValue: "C locale, non-ASCII query: rc=\(cLocale.status) \(cLocale.stdout) err=\(cLocale.stderr)"))
    let stub2 = try makeStub(in: dir, responses: [:])   // 上面重寫了 stub；後面的 CR 臂要回到預設回應
    // 單獨的 CR 不是行分隔：腳本、測試、指紋三邊都只在 LF 切（R4：指紋的 python 曾用逐行迭代，連 CR 也切，
    // 兩個不同的查詢集會算出同一個指紋）。放在呼叫計數之後，因為這一跑也寫 argv.log。
    let loneCR = "ZQXJ-P\rZQXJ-Q\nZQXJ-R\n"
    let loneCRFile = dir.appendingPathComponent("cr.txt")
    try loneCR.write(to: loneCRFile, atomically: true, encoding: .utf8)
    let crRun = try runScript(queries: loneCRFile, stub: stub2)
    #expect(crRun.rows.count == 2 && nonCommentLines(loneCR).count == 2, Comment(rawValue: crRun.stdout))
    #expect(crRun.setLine == setLine(loneCR), Comment(rawValue: "lone CR: \(crRun.setLine)"))
    #expect(crRun.setLine != setLine("ZQXJ-P\nZQXJ-Q\nZQXJ-R\n"), "含 CR 的兩行集與三行集不得同指紋")
}

@Test("measure-baseline.sh：error 字母表的每個 token 都會出現（rc、sig<N>、exec、json、shape×3）、每列照印、任一 error 以 1 離開；stderr 不帶 traceback 也不帶查詢")
func measureBaselineReportsEveryFailureAndExitsNonZero() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-RC-SEVEN\nZQXJ-SIGNAL\nZQXJ-NONJSON\nZQXJ-OBJECT\nZQXJ-STRINGS\nZQXJ-NULLSNIPPET\nZQXJ-OK\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [
        "ZQXJ-NONJSON": "not json at all",
        "ZQXJ-OBJECT": #"{"hits":[{"snippet":"⟨tool x⟩"}]}"#,
        "ZQXJ-STRINGS": #"["⟨tool x⟩"]"#,
        "ZQXJ-NULLSNIPPET": #"[{"snippet":null,"uuid":"u"}]"#,
    ], exits: ["ZQXJ-RC-SEVEN": 7], raw: ["ZQXJ-SIGNAL": "kill -9 $$"])

    let run = try runScript(queries: queries, stub: stub)
    #expect(run.status == 1, Comment(rawValue: "rc=\(run.status) out=\(run.stdout) err=\(run.stderr)"))
    #expect(run.rows.map(tail) == ["error(7)", "error(sig9)", "error(json)", "error(shape)", "error(shape)", "error(shape)", "clean tool=0"], Comment(rawValue: run.stdout))  // produces: rc sig json shape
    #expect(run.rows.allSatisfy { $0.range(of: verdictLine, options: .regularExpression) != nil }, Comment(rawValue: run.stdout))
    #expect(!run.combined.contains("ZQXJ") && !run.combined.contains("Traceback"), Comment(rawValue: run.stderr))

    // error(exec)：LTM_BIN 是可執行的一般檔案，但不是可執行格式（ENOEXEC）。
    let notAProgram = dir.appendingPathComponent("notaprogram")
    try "this is not a program\n".write(to: notAProgram, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: notAProgram.path)
    let one = dir.appendingPathComponent("one.txt")
    try "ZQXJ-ONE\n".write(to: one, atomically: true, encoding: .utf8)
    let exec = try runScript(queries: one, stub: stub, ltmBinOverride: notAProgram.path)
    #expect(exec.status == 1 && exec.rows.map(tail) == ["error(exec)"], Comment(rawValue: "rc=\(exec.status) out=\(exec.stdout)"))  // produces: exec
}

@Test("measure-baseline.sh：judge 掛掉或印出不合形狀的東西 → 該列 error(judge)、以 1 離開，judge 的 stderr／雜訊不外流")
func measureBaselineContainsAJudgeCrash() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-ONE\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [:])
    let fakes: [(String, String)] = [
        // 崩掉：traceback 進 stderr、非零離開。
        ("crash", "echo 'Traceback (most recent call last): ZQXJ-JUDGE' >&2; exit 1"),
        // 沒崩，但 stdout 多了一行雜訊（例如 site-packages 的 .pth 印字）。
        ("junk", "printf 'ZQXJ-JUNK from a .pth\\n42 clean tool=0\\n'; exit 0"),
        // 一行，但 <ms> 不是數字。
        ("badms", "printf 'fast clean tool=0\\n'; exit 0"),
        // 一行，verdict 不在字母表。
        ("badword", "printf '42 dirty tool=0\\n'; exit 0"),
        // tool= 後面不是數字。
        ("toolx", "printf '42 clean tool=x\\n'; exit 0"),
        // sig 後面不是數字。
        ("sigx", "printf '42 error(sigx)\\n'; exit 0"),
        // 字面 token 不在 ERROR_TOKENS（字元都合法——這條釘的是「字面比對」而不是「字元類別」）。
        ("badtoken", "printf '42 error(timeout)\\n'; exit 0"),
        // 空 token。
        ("emptytok", "printf '42 error()\\n'; exit 0"),
        // 少了右括號（judge 寫到一半死掉的形狀）。
        ("unclosed", "printf '42 error(json\\n'; exit 0"),
        // 0 不是「非零離開碼」、sig0 不是訊號、前導零不是 rc 的印法。
        ("rczero", "printf '42 error(0)\\n'; exit 0"),
        ("sigzero", "printf '42 error(sig0)\\n'; exit 0"),
        ("rcleadingzero", "printf '42 error(07)\\n'; exit 0"),
    ]
    for (label, body) in fakes {
        let bin = try makeBinDir(in: dir, judgeFakes: ["python3": body])
        let run = try runScript(queries: queries, stub: stub, pathPrefix: bin.path)
        #expect(run.status == 1, Comment(rawValue: "\(label): rc=\(run.status) out=\(run.stdout)"))
        #expect(run.rows == ["#1 0ms error(judge)"], Comment(rawValue: "\(label): \(run.stdout)"))  // produces: judge
        #expect(!run.combined.contains("ZQXJ") && !run.combined.contains("Traceback"), Comment(rawValue: "\(label): \(run.stderr)"))
    }
}

@Test("measure-baseline.sh：前置守衛各自有離開碼——k 越界或非數字 64（且 stderr 只有那一句）、只有註解 65、查詢檔缺／是目錄／不可讀 66、ltm 是目錄或不可執行 69、沒有 python3 70")
func measureBaselinePreflightGuardsHaveDistinctExitCodes() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-ONE\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [:])

    // 每臂都斷言 stderr 只有那一句（R9：標題這樣宣稱，先前只有非數字那一臂斷言）。
    // 空字串也是 64（R10）；`18446744073709551621` 這臂驅動的是位數上限：沒有它，`[ -ge ]` 對超過 intmax 的字串會多印一行 bash
    // 診斷，stderr 的相等比對就紅（查法在腳本註解；R12 寫的「wrap 成 5」是已刪掉的算術才有的行為，R13）；21 個字元的那臂驅動
    // 剝零之前的長度閘（把剝零的展開成本綁在 20 個字元內；成本數字不在紀錄裡就不寫，R14——紅的是 rc）。
    for bad in ["0", "1001", "", "18446744073709551621", "000000000000000000005"] {
        let r = try runScript(queries: queries, stub: stub, k: bad)
        #expect(r.status == 64 && r.stderr == "k 必須是 1–1000 的整數\n", Comment(rawValue: "k=\(bad): rc=\(r.status) err=\(r.stderr)"))
    }
    let nonDigit = try runScript(queries: queries, stub: stub, k: "x")
    #expect(nonDigit.status == 64 && nonDigit.stderr == "k 必須是 1–1000 的整數\n", Comment(rawValue: nonDigit.stderr))
    // 多給的引數是錯（R14）：舊習慣把查詢放第二個參數時，字串已進 metadata，這次不能算量到——64、stdout 空、ltm 沒被叫、
    // stderr 不回顯那個引數。
    let logBefore = (try? String(contentsOf: dir.appendingPathComponent("argv.log"), encoding: .utf8)) ?? ""
    let extra = try runScript(queries: queries, stub: stub, extraArgs: ["ZQXJ-EXTRA-ARG"])
    let logAfter = (try? String(contentsOf: dir.appendingPathComponent("argv.log"), encoding: .utf8)) ?? ""
    #expect(extra.status == 64 && extra.stdout.isEmpty && !extra.combined.contains("ZQXJ") && logAfter == logBefore, Comment(rawValue: "extra arg: rc=\(extra.status) out=\(extra.stdout) err=\(extra.stderr)"))
    // 明確給空字串是錯、不是用預設（R14；k 的同一條紀律 R10）：LTM_BASELINE_QUERIES 空 → 66（不能靜默量到腳本旁的真檔）；LTM_BIN 空 → 69。
    #expect(try runScript(queries: queries, stub: stub, extraEnv: ["LTM_BASELINE_QUERIES": ""]).status == 66)
    #expect(try runScript(queries: queries, stub: stub, extraEnv: ["LTM_BIN": ""]).status == 69)

    // k 正規化：前導零一律十進位（R10 版的 `$((K))` 把 `010` 當八進位、`08` 算術失敗仍 rc 0，R11）；set 行印正規化後的值。
    // 20 個字元是長度閘的邊界：`00000000000000001000` 仍合法（R13）。
    for (given, want) in [("007", "7"), ("010", "10"), ("08", "8"), ("0100", "100"), ("01000", "1000"), ("00007", "7"), ("00000000000000001000", "1000")] {   // 前導零任意多個都合法（R12）
        let r = try runScript(queries: queries, stub: stub, k: given)
        #expect(r.status == 0 && r.setLine.hasSuffix(" k=\(want)") && r.stderr.isEmpty, Comment(rawValue: "k=\(given): rc=\(r.status) \(r.setLine) err=\(r.stderr)"))
    }
    #expect(try runScript(queries: dir.appendingPathComponent("missing.txt"), stub: stub).status == 66)
    #expect(try runScript(queries: dir, stub: stub).status == 66)
    // 含 NUL 的查詢檔：bash 變數存不了它（會靜默丟掉），腳本要在讀進記憶體之前擋成 66（R8：查詢檔改成只讀一次）。
    let withNUL = dir.appendingPathComponent("nul.txt")
    try Data("ZQXJ-ONE\n".utf8 + [0x5A, 0x00, 0x41, 0x0A]).write(to: withNUL)
    let nulRun = try runScript(queries: withNUL, stub: stub)
    #expect(nulRun.status == 66 && nulRun.stdout.isEmpty, Comment(rawValue: "rc=\(nulRun.status) out=\(nulRun.stdout)"))
    // root 對 0o000 的檔案仍然 -r 為真，這一臂在 root 下（容器／CI）不成立。不能靜默跳過（那是「看起來有人守」），
    // 也不能誤紅：以 known issue 留下可見訊號（R7 → R8）。
    if geteuid() == 0 {
        withKnownIssue("以 root 執行：0o000 的檔案對 root 仍可讀，66 的「不可讀」這一臂無法驗證") { Issue.record("這一臂在 root 下沒有跑") }
    } else {
        let unreadable = dir.appendingPathComponent("unreadable.txt")
        try "ZQXJ-ONE\n".write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        #expect(try runScript(queries: unreadable, stub: stub).status == 66)
    }

    #expect(try runScript(queries: queries, stub: stub, ltmBinOverride: dir.path).status == 69)
    let notExecutable = dir.appendingPathComponent("noexec")
    try "#!/bin/bash\n".write(to: notExecutable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExecutable.path)
    #expect(try runScript(queries: queries, stub: stub, ltmBinOverride: notExecutable.path).status == 69)

    // 沒有 HOME 也沒有 LTM_BIN：`${HOME:-}` 讓預設變成 /bin/ltm → 69，不是 set -u 的隱式 1（R8 #8；R9 指出沒測試驅動）。
    let noHome = try runScript(queries: queries, stub: stub, unsetting: ["HOME", "LTM_BIN"])
    #expect(noHome.status == 69, Comment(rawValue: "no HOME: rc=\(noHome.status) err=\(noHome.stderr)"))
    let noPython = try makeBinDir(in: dir, judgeFakes: [:])
    #expect(try runScript(queries: queries, stub: stub, pathOverride: noPython.path).status == 70)
    // 指紋算不出來（python3 對 `-` 那一次呼叫掛掉）也是 70，而且一列都不印。
    let fpBroken = dir.appendingPathComponent("bin-fp")
    try FileManager.default.createDirectory(at: fpBroken, withIntermediateDirectories: true)
    try "#!/bin/bash\nif [ \"$1\" = \"-\" ]; then exit 3; fi\nexec '\(realPython3())' \"$@\"\n"
        .write(to: fpBroken.appendingPathComponent("python3"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fpBroken.appendingPathComponent("python3").path)
    let fpRun = try runScript(queries: queries, stub: stub, pathOverride: fpBroken.path)
    #expect(fpRun.status == 70 && fpRun.stdout.isEmpty, Comment(rawValue: "rc=\(fpRun.status) out=\(fpRun.stdout)"))
    // 指紋印出大寫「hex」：字面集合比對在任何 locale 都拒絕；bash 3.2 的 [0-9a-f] range 在 en_US.UTF-8 下會把
    // A–E 收進去（collation），這條測試就是釘住不能退回 range 寫法。
    let fpUpper = dir.appendingPathComponent("bin-fpu")
    try FileManager.default.createDirectory(at: fpUpper, withIntermediateDirectories: true)
    try "#!/bin/bash\nif [ \"$1\" = \"-\" ]; then printf 'ABCDE1234567\\n'; exit 0; fi\nexec '\(realPython3())' \"$@\"\n"
        .write(to: fpUpper.appendingPathComponent("python3"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fpUpper.appendingPathComponent("python3").path)
    for locale in ["C", "en_US.UTF-8"] {
        let up = try runScript(queries: queries, stub: stub, pathOverride: fpUpper.path, extraEnv: ["LC_ALL": locale, "LANG": locale])
        #expect(up.status == 70 && up.stdout.isEmpty, Comment(rawValue: "LC_ALL=\(locale): rc=\(up.status) out=\(up.stdout)"))
    }
    // 13 個小寫 hex：逐字元檢查只看前 12 位，長度檢查才擋得住。
    let fpLong = dir.appendingPathComponent("bin-fpl")
    try FileManager.default.createDirectory(at: fpLong, withIntermediateDirectories: true)
    try "#!/bin/bash\nif [ \"$1\" = \"-\" ]; then printf 'abcdef0123456\\n'; exit 0; fi\nexec '\(realPython3())' \"$@\"\n"
        .write(to: fpLong.appendingPathComponent("python3"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fpLong.appendingPathComponent("python3").path)
    let long = try runScript(queries: queries, stub: stub, pathOverride: fpLong.path)
    #expect(long.status == 70 && long.stdout.isEmpty, Comment(rawValue: "rc=\(long.status) out=\(long.stdout)"))

    let onlyComments = dir.appendingPathComponent("c.txt")
    try "# a\n\n   # b\n".write(to: onlyComments, atomically: true, encoding: .utf8)
    let run = try runScript(queries: onlyComments, stub: stub)
    #expect(run.status == 65 && run.rows.isEmpty, Comment(rawValue: "rc=\(run.status) out=\(run.stdout)"))
}

@Test("measure-baseline.sh：呼叫端 shell 環境整族由 re-exec 清掉——xtrace 三條路（`bash -x`／`SHELLOPTS`／`BASH_ENV`）、errexit 兩條、同名函式（exec／set／read／printf）、readonly（QF_CONTENT／SETID）、allexport 三條與 pre-exported 變數：都不漏、不撞號、不偽造指紋")
func measureBaselineDoesNotLeakUnderXtrace() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-TRACE-ONE\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [
        "ZQXJ-TRACE-ONE": #"[{"snippet":"ZQXJ-SNIPPET 一段命中","uuid":"u"}]"#,
    ])
    let benv = dir.appendingPathComponent("benv.sh")
    try "set -x\n".write(to: benv, atomically: true, encoding: .utf8)
    // errexit（R13）：`read -d ''` 在 EOF 的正常回 1 會在 `set -e` 下直接殺掉腳本——零輸出、rc 1（與「任一列 error」撞號）。
    let eenv = dir.appendingPathComponent("eenv.sh")
    try "set -e\n".write(to: eenv, atomically: true, encoding: .utf8)
    // 同名函式：bash 解析名字時函式先於 builtin。`BASH_ENV` 裡把 exec 與 set 都蓋成 no-op、再把 read／printf 蓋成丟給 /bin/cat 的
    // 函式、然後 `builtin set -x`——腳本第一行 `builtin set +x` 沒指名 builtin 就關不掉 trace（re-exec 那一行帶 `LTM_ANCHOR_KEY`
    // 上 stderr，見 xtrace 三臂的 ZQXJ-KEY）；第二行 `builtin exec` 沒指名 builtin 就不會 re-exec、read 函式接走整份查詢檔上 stdout。
    // 這一臂驅動的是前兩行的兩個 `builtin`（R13 版對 read／printf／unset 各指名 builtin 並拿 `unset BASH_ENV` 收尾，R14 改成
    // re-exec 之後那些都驅動不了、拆掉）。
    let fenv = dir.appendingPathComponent("fenv.sh")
    try "exec() { :; }; set() { :; }; read() { /bin/cat; return 1; }; printf() { /bin/cat \"$@\"; }; builtin set -x\n".write(to: fenv, atomically: true, encoding: .utf8)
    // readonly：呼叫端把 `QF_CONTENT` 設成 readonly 曾讓預設值冒充讀進來的內容（R13）；把 `SETID` 設成 readonly 會偽造指紋、`bad`
    // 設成 readonly 會吃掉 error 列（R14）——同一族。re-exec 之後這個 shell 裡沒有任何 readonly，指紋必須是真的。
    let renv = dir.appendingPathComponent("renv.sh")
    try "readonly QF_CONTENT='ZQXJ-PRESET'; readonly SETID=abcdef012345\n".write(to: renv, atomically: true, encoding: .utf8)
    // xtrace 三臂帶一把假密鑰：re-exec 那一行把 `LTM_ANCHOR_KEY` 放在命令列上，第一行 `builtin set +x` 沒生效它就會被 trace 出來
    // ——密鑰不是查詢，但它是同一條 stderr，也是 .claude/rules/anchor-key-in-probes.md 說不得落地的東西。
    let key = ["LTM_ANCHOR_KEY": "ZQXJ-KEY"]
    let runs = [
        ("bash -x", try runScript(queries: queries, stub: stub, viaBashX: true, extraEnv: key)),
        ("SHELLOPTS", try runScript(queries: queries, stub: stub, extraEnv: key.merging(["SHELLOPTS": "xtrace"]) { $1 })),
        ("BASH_ENV", try runScript(queries: queries, stub: stub, extraEnv: key.merging(["BASH_ENV": benv.path]) { $1 })),
        ("SHELLOPTS=errexit", try runScript(queries: queries, stub: stub, extraEnv: ["SHELLOPTS": "errexit"])),
        ("BASH_ENV set -e", try runScript(queries: queries, stub: stub, extraEnv: ["BASH_ENV": eenv.path])),
        ("BASH_ENV exec/set/read/printf functions", try runScript(queries: queries, stub: stub, extraEnv: key.merging(["BASH_ENV": fenv.path]) { $1 })),
        ("BASH_ENV readonly QF_CONTENT/SETID", try runScript(queries: queries, stub: stub, extraEnv: ["BASH_ENV": renv.path])),
    ]
    for (label, run) in runs {
        #expect(run.status == 0, Comment(rawValue: "\(label): rc=\(run.status) err=\(run.stderr.count) bytes"))
        #expect(run.rows.count == 1 && run.rows[0].hasSuffix(" clean tool=0") && run.setLine == setLine("ZQXJ-TRACE-ONE\n"), Comment(rawValue: "\(label): \(run.stdout)"))
        let leaked = run.combined.contains("ZQXJ")
        #expect(!leaked, Comment(rawValue: "\(label): 漏了查詢、命中或密鑰（stderr \(run.stderr.count) bytes）"))
    }
    // allexport（R10；放在三條 xtrace 之後——makeStub 會覆寫同一目錄的 ltm stub）：`BASH_ENV` 裡一行 `set -a` 會把裝著整份查詢集的變數匯出給每個子行程——腳本第一行要連它一起關。
    // ltm stub 是 bash：`${QF_CONTENT+leaked}` 在它的環境裡看得到那個變數就展開成 leaked。
    let aenv = dir.appendingPathComponent("aenv.sh")
    try "set -a\n".write(to: aenv, atomically: true, encoding: .utf8)
    let envProbe = dir.appendingPathComponent("env.txt")
    let probeStub = try makeStub(in: dir, responses: [:], raw: ["ZQXJ-TRACE-ONE": "printf '%s' \"${QF_CONTENT+leaked}\" > '\(envProbe.path)'; printf '[]\\n'"])
    // 第三條向量：呼叫端環境裡已經 export 了同名變數——bash 的賦值會保留 export 屬性，所以腳本一開始的 `unset QF_CONTENT`
    // 不是裝飾（R12）：拿掉它，這一臂就 leaked。
    for (label, env) in [("BASH_ENV set -a", ["BASH_ENV": aenv.path]), ("SHELLOPTS=allexport", ["SHELLOPTS": "allexport"]), ("pre-exported QF_CONTENT", ["QF_CONTENT": "pre-exported"])] {
        try? FileManager.default.removeItem(at: envProbe)
        let allexport = try runScript(queries: queries, stub: probeStub, extraEnv: env)
        #expect(allexport.status == 0, Comment(rawValue: "\(label): rc=\(allexport.status)"))
        let exported = (try? String(contentsOf: envProbe, encoding: .utf8)) ?? "(unread)"
        #expect(exported.isEmpty, Comment(rawValue: "\(label): 查詢集變數被匯出進 ltm 的環境：\(exported)"))
    }
}

@Test("measure-baseline.sh：拿得到查詢內容的子行程 stdio 都隔離——judge 的 stdin 不是查詢檔（吃不掉後面的行）、指紋 python 與 judge 的 stderr 不上腳本的 stderr")
func measureBaselineIsolatesChildProcessStdio() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let queries = dir.appendingPathComponent("q.txt")
    try "ZQXJ-ONE\nZQXJ-TWO\nZQXJ-THREE\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = try makeStub(in: dir, responses: [:])
    // 假 python3：每次呼叫都先往 stderr 吐一行；judge 那次（-c）再把 stdin 讀光；然後轉交真的 python3。
    // 這裡補的是 R7 指出的兩個行程：指紋 python 是唯一整份讀進查詢集的行程，它的 stderr 曾經沒有重導；
    // judge python 曾經繼承查詢內容當 stdin（ltm 那一側見 makeStub 的說明）。
    // `cat` 用絕對路徑：這條測試的敏感度靠它——找不到 `cat` 時 judge 沒接 /dev/null 也照樣綠（R7 verify-fix 的變異
    // 第一次就是這樣假綠的，當時是 pathOverride 讓 PATH 上沒有它；R8 指出改 pathPrefix 後仍依賴宿主 PATH）。
    #expect(FileManager.default.isExecutableFile(atPath: "/bin/cat"), "沒有 /bin/cat，這條測試的 stdin 那一臂驅動不了")
    let bin = dir.appendingPathComponent("bin-stdio")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    // 指紋那次（-）另外記下 fd 3 是不是管線：R11 指出字面計數鎖不住資料路徑——herestring 或 `< "$QF"` 會給一般檔案。
    // 鑑別力只在 bash 3.2（macOS 的 /bin/bash，就是 shebang 解到的那個）：bash ≥ 5.1 的小 herestring 也走管線（R12）。
    let fdProbe = dir.appendingPathComponent("fd3.txt")
    try "#!/bin/bash\necho 'ZQXJ-STDERR-NOISE' >&2\nif [ \"$1\" = \"-c\" ]; then /bin/cat >/dev/null; fi\nif [ \"$1\" = \"-\" ]; then { [ -p /dev/fd/3 ] && printf pipe || printf notpipe; } > '\(fdProbe.path)'; fi\nexec '\(realPython3())' \"$@\"\n"
        .write(to: bin.appendingPathComponent("python3"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("python3").path)
    let run = try runScript(queries: queries, stub: stub, pathPrefix: bin.path)
    #expect(run.status == 0, Comment(rawValue: "rc=\(run.status) out=\(run.stdout)"))
    #expect(run.rows.count == 3, Comment(rawValue: "judge 的 stdin 若是查詢檔，cat 會吃掉剩下的行：\(run.stdout)"))
    let leaked = run.stderr.contains("ZQXJ-STDERR-NOISE")
    #expect(!leaked, Comment(rawValue: "子行程的 stderr 上了腳本的 stderr（\(run.stderr.count) bytes）"))
    let fd3 = (try? String(contentsOf: fdProbe, encoding: .utf8)) ?? "(unread)"
    #expect(fd3 == "pipe", Comment(rawValue: "指紋 python 的 fd 3 不是管線：\(fd3)"))
}

@Test("measure-baseline.sh：查詢檔預設在腳本旁，走訪仿 bash 找腳本運算元的順序——裸名經 PATH 解到腳本目錄而非 cwd 誘餌；相對路徑；cwd 與 PATH 各一份時用 cwd；644 排在 755 前用 644；000 排在 755 前跳過 000；PATH 元素字面 `~/…` 展開；`~+/…` 不仿 → 66")
func measureBaselineResolvesItsOwnDirectoryLikeBashDoes() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let stub = try makeStub(in: dir, responses: [:])
    // A：腳本的複本＋旁邊兩條合成查詢；B：別的 cwd，放一條同名誘餌；C：cwd 也有一份腳本複本＋自己的查詢檔；
    // N：一份 644（不可執行）的複本＋自己的查詢檔。都不碰真查詢檔。每一臂都比指紋——指紋是身分，列數只是巧合（R13：第三臂曾只比列數）。
    let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b"), c = dir.appendingPathComponent("c"), n = dir.appendingPathComponent("n")
    for d in [a, b, c, n] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    let source = repoRoot().appendingPathComponent("scripts/measure-baseline.sh")
    try FileManager.default.copyItem(at: source, to: a.appendingPathComponent("measure-baseline.sh"))
    try FileManager.default.copyItem(at: source, to: c.appendingPathComponent("measure-baseline.sh"))
    try FileManager.default.copyItem(at: source, to: n.appendingPathComponent("measure-baseline.sh"))
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: n.appendingPathComponent("measure-baseline.sh").path)
    let real = "ZQXJ-REAL-ONE\nZQXJ-REAL-TWO\n", decoy = "ZQXJ-DECOY\n", inCwd = "ZQXJ-CWD-ONE\nZQXJ-CWD-TWO\nZQXJ-CWD-THREE\n", nonExec = "ZQXJ-NOEXEC-ONE\n"
    try real.write(to: a.appendingPathComponent("baseline-queries.txt"), atomically: true, encoding: .utf8)
    try decoy.write(to: b.appendingPathComponent("baseline-queries.txt"), atomically: true, encoding: .utf8)
    try inCwd.write(to: c.appendingPathComponent("baseline-queries.txt"), atomically: true, encoding: .utf8)
    try nonExec.write(to: n.appendingPathComponent("baseline-queries.txt"), atomically: true, encoding: .utf8)
    let unused = dir.appendingPathComponent("unused.txt")   // runScript 要一個 queries URL；這裡把 LTM_BASELINE_QUERIES 拿掉讓預設值生效
    // 1. 裸名、cwd=B、PATH 前綴 A：R11 版量到 B 的誘餌（1 列、指紋是誘餌的）；現在必須是 A 的兩條。
    let viaPath = try runScript(queries: unused, stub: stub, pathPrefix: a.path, unsetting: ["LTM_BASELINE_QUERIES"], bashOperand: "measure-baseline.sh", cwd: b)
    #expect(viaPath.status == 0 && viaPath.rows.count == 2 && viaPath.setLine == setLine(real), Comment(rawValue: "via PATH: rc=\(viaPath.status) \(viaPath.stdout)"))
    // 2. 相對路徑呼叫（帶 CDPATH=.：它曾把解出的路徑印進命令替換 → 66，R12；R14 起由 re-exec 清掉，這裡留著只證明它進不來）。
    let rel = try runScript(queries: unused, stub: stub, extraEnv: ["CDPATH": "."], unsetting: ["LTM_BASELINE_QUERIES"], bashOperand: "a/measure-baseline.sh", cwd: dir)
    #expect(rel.status == 0 && rel.rows.count == 2 && rel.setLine == setLine(real), Comment(rawValue: "relative+CDPATH: rc=\(rel.status) \(rel.stdout) err=\(rel.stderr)"))
    // 3. 裸名、cwd=A、PATH 上沒有：bash 在 cwd 找到腳本 → 用 A。
    let inPlace = try runScript(queries: unused, stub: stub, unsetting: ["LTM_BASELINE_QUERIES"], bashOperand: "measure-baseline.sh", cwd: a)
    #expect(inPlace.status == 0 && inPlace.rows.count == 2 && inPlace.setLine == setLine(real), Comment(rawValue: "in place: rc=\(inPlace.status) \(inPlace.stdout)"))
    // 4. 裸名、cwd=C、PATH 前綴 A，**兩邊都有**腳本：bash 先看 cwd → 跑的是 C 那份 → 指紋必須是 C 的三條，不是 A 的兩條。
    //    前三臂都問不到「誰優先」（把 cwd 與 PATH 的順序反過來寫，三臂逐字同輸出，R13）；這一臂才問。
    let cwdWins = try runScript(queries: unused, stub: stub, pathPrefix: a.path, unsetting: ["LTM_BASELINE_QUERIES"], bashOperand: "measure-baseline.sh", cwd: c)
    #expect(cwdWins.status == 0 && cwdWins.rows.count == 3 && cwdWins.setLine == setLine(inCwd), Comment(rawValue: "cwd over PATH: rc=\(cwdWins.status) \(cwdWins.stdout)"))
    // 5. 裸名、cwd=B、PATH 前綴 N:A，N 那份 644：bash 沿 PATH 取第一個**可讀**的 → 跑的是 N 那份 → 指紋必須是 N 的一條。
    //    R12 版用 `command -v`，它偏好可執行檔、會回 A → 量到 A 的兩條而 rc 0（R13 實測，bash 3.2.57 與 5.3.15 同）。
    let readableFirst = try runScript(queries: unused, stub: stub, pathPrefix: n.path + ":" + a.path, unsetting: ["LTM_BASELINE_QUERIES"], bashOperand: "measure-baseline.sh", cwd: b)
    #expect(readableFirst.status == 0 && readableFirst.rows.count == 1 && readableFirst.setLine == setLine(nonExec), Comment(rawValue: "readable before executable: rc=\(readableFirst.status) \(readableFirst.stdout) err=\(readableFirst.stderr)"))
    // 6. 裸名、cwd=B、PATH 前綴 U:A，U 那份 000：bash 跳過不可讀的、跑 A → 指紋必須是 A 的。走訪的 `-r` 連言由這一臂扛（R14：五臂
    //    全是可讀的複本，退掉 `-r` 全綠）。root 對 000 仍可讀，同 preflight 那一臂的處置。
    if geteuid() == 0 {
        withKnownIssue("以 root 執行：000 的複本對 root 仍可讀，「跳過不可讀」這一臂無法驗證") { Issue.record("這一臂在 root 下沒有跑") }
    } else {
        let u = dir.appendingPathComponent("u")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: u.appendingPathComponent("measure-baseline.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: u.appendingPathComponent("measure-baseline.sh").path)
        try "ZQXJ-UNREADABLE\n".write(to: u.appendingPathComponent("baseline-queries.txt"), atomically: true, encoding: .utf8)
        let skipUnreadable = try runScript(queries: unused, stub: stub, pathPrefix: u.path + ":" + a.path, unsetting: ["LTM_BASELINE_QUERIES"], bashOperand: "measure-baseline.sh", cwd: b)
        #expect(skipUnreadable.status == 0 && skipUnreadable.rows.count == 2 && skipUnreadable.setLine == setLine(real), Comment(rawValue: "unreadable first: rc=\(skipUnreadable.status) \(skipUnreadable.stdout) err=\(skipUnreadable.stderr)"))
    }
    // 7. PATH 元素寫成字面 `~/a`（HOME=dir）：bash 對每個 PATH 元素做 tilde 展開才找腳本，走訪也要（R14：不展開就跳過它、量到
    //    後面那份或落到 /nonexistent）。
    let tilde = try runScript(queries: unused, stub: stub, pathPrefix: "~/a", extraEnv: ["HOME": dir.path], unsetting: ["LTM_BASELINE_QUERIES"], bashOperand: "measure-baseline.sh", cwd: b)
    #expect(tilde.status == 0 && tilde.rows.count == 2 && tilde.setLine == setLine(real), Comment(rawValue: "literal ~/ in PATH: rc=\(tilde.status) \(tilde.stdout) err=\(tilde.stderr)"))
    // 8. PATH 元素寫成 `~+/a`（bash 展開成 $PWD，走訪刻意不仿）：bash 找得到、走訪找不到 → HERE=/nonexistent → 66，而不是安靜量到
    //    別棵樹。這一臂驅動的正是那條退路（R13 寫它「實務上到不了」）。
    let plus = try runScript(queries: unused, stub: stub, pathPrefix: "~+/a", unsetting: ["LTM_BASELINE_QUERIES"], bashOperand: "measure-baseline.sh", cwd: dir)
    #expect(plus.status == 66 && plus.stdout.isEmpty && plus.stderr.contains("/nonexistent/"), Comment(rawValue: "~+ in PATH: rc=\(plus.status) \(plus.stdout) err=\(plus.stderr)"))
}
