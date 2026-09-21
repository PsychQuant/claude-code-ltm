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

/// 一條**非註解行**的純量數上限。查詢檔的自動內容約束是 9 項（README 同一份；R23 統一——R22 版三處各寫一個互斥的
/// 「唯一」；R24 版寫「6 項」並把數釘在 `QueryFileReport` 的欄位數上，R25 指出那是**儲存屬性數**不是約束數；R26 加了
/// 一條位置錨點、R27 換成檔頭終止符、R28 加了「檔頭不得含曾經是查詢的字串」——項目本身這裡不寫，R28 更正：R27 版
/// 在這裡複述了 R26 那條的名字，而它正是同一個 commit 換掉的那一條）。**權威與查法**：`contentConstraints` 這份具名
/// 清單，它自己寫明買到什麼、買不到什麼。這裡不複述項目內容，也不複述項數以外的任何數字。
/// 它擋不住整段文字（切成多條短行、或放進 `#` 註解都過，codex R22），更分不出一句第三方逐字短句與自行撰寫的短語——這個檔進 remote
/// 卻無任何審閱路徑（`-diff`＋規則 1 的「reviewer 不准讀內容」），作者自審是防線。門檻與現況的查法（只印長度，不印內容；量的單位要與守衛相同——
/// awk 的 `length` 在 macOS 回的是 bytes，中文差約 3 倍，R9）：
/// `python3 -c "import sys; print(max(len(l.strip()) for l in open(sys.argv[1], encoding='utf-8') if l.strip() and not l.lstrip().startswith('#')))" scripts/baseline-queries.txt`
/// （單一命令、不可切半——R16：前一版是 `grep -v '^#' … |` 接 python，前半段單獨執行就會把整份查詢集印上 stdout）。
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
    var headerStructure: [Int] = []   // 實體行號：終止符之後的註解行、終止符之前的非註解行；終止符缺少或重複記為 0
    var headerFormerQueries: [Int] = []   // 實體行號：檔頭區塊裡含任何一條「曾經是查詢」的字串的行（見 checkQueryFile）
}

private struct NotUTF8: Error {}

/// 對應 judge 的 `norm()`（`" ".join(s.split()).casefold()`）的正規化：空白摺疊成單一空白＋小寫。
/// **不是同形**，而且兩個方向都有（R25：R24 版寫「同形」、又在下一句自陳不同形，且把整個分岔歸因給 fold 函式）：
///
/// 1. **fold 本身比 judge 窄**：`lowercased()` ≠ Python `casefold()`。查法（三對輸入，兩支五行腳本）：
///    `ß`/`SS`、`ς`/`σ`、`ﬁle`(U+FB01)/`file` —— judge 的 `norm()` 判相等，這裡判不等。
/// 2. **比對本身比 judge 寬**：`Set` 與 `contains` 走 Swift String 的**正則等價**，而這個函式從不做 NFC/NFD 正規化。
///    查法：`e`+U+0301 與 U+00E9 —— Swift `==` 為真、judge `norm()` 為假。**這一軸與 fold 函式無關**：改寫成手工
///    case fold 碰不到它（R25，security）。方向是 fail-closed（假紅、不是漏放）。
///
/// 退役清單今天沒有第 1 條那類字元（查法：`retired` 陣列），但那只保護 `retiredOffenders`；`duplicateCount` 的輸入是
/// 未來新增的查詢，不受該事實保護。臂：`foldLikeJudge` 摺成**什麼**由 `queryFileChecksAreDrivenByTheirOwnFixture`
/// 的分隔符那一條釘住（R25：R24 版的兩條 fixture 只驅動「有沒有摺疊」，把分隔符改成 `""` 全綠）。
private func foldLikeJudge(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() }

/// 檔頭終止符。**檔頭 ＝ 這一行（含）以前**——一個與位置無關的界線，不是「第一個非註解行之前」。
///
/// R25 把檔頭從「全檔任意註解」收成「前導連續註解」（codex：否則檔頭整段搬到檔尾仍全綠）。R26 在那之上加了
/// 「第一條查詢之後不得有註解行」。**R27 四家各自實測推翻了那個錨點**：把**第一條**查詢就地加 `#` 退役時，
/// 那一行升格成檔頭、錨點右移到第二條，八條約束全綠——例子被蓋住，性質沒有。有了終止符，「註解行只能出現在
/// 終止符之前」對每一條查詢都成立，與它排第幾無關。該檔 `-diff` ＋ 規則 1 讓 reviewer 不准讀內容，
/// 這項機械檢查是主要防線。
private let headerTerminator = "# === 檔頭結束：以下每一行都是一條查詢，不得有註解 ==="

/// 檔頭區塊與終止符的位置。終止符**恰好一行**；缺少或重複時回 `nil`（呼叫端記成哨兵 `0`，與檔首 BOM 同慣例）。
/// 終止符不存在時仍回傳前導連續註解當檔頭，好讓 `missingHeaderPhrases` 在畸形檔上仍給得出具名訊息。
/// 空行不終止前導區塊；註解行的判法與行定義一致（先 ASCII trim 再看 `#`）。
private func headerBlock(_ physical: [String]) -> (text: String, terminator: Int?) {
    let marks = physical.indices.filter { physical[$0].trimmingCharacters(in: asciiWhitespace) == headerTerminator }
    if marks.count == 1 { return (physical[...marks[0]].joined(separator: "\n"), marks[0]) }
    var block: [String] = []
    for line in physical {
        let t = line.trimmingCharacters(in: asciiWhitespace)
        if t.hasPrefix("#") { block.append(line); continue }
        if t.isEmpty { continue }
        break
    }
    return (block.joined(separator: "\n"), nil)
}

private let realFileTestName = "baselineQueryFileDocumentsItsContractAndRetiresThePollutedQueries"
private let fixtureTestName = "queryFileChecksAreDrivenByTheirOwnFixture"

/// 自動內容約束的**具名清單**——散文那兩份列舉（README 與 `maxQueryScalars` 的說明）的權威來源。
/// 每一項標明它經哪個出口回報（`QueryFileReport` 的一個欄位，或 `checkQueryFile` 的 `throw`）。
///
/// **每個欄位型出口要在兩條測試裡各有一句斷言，兩條的角色不同；`throw` 型只有 driven**（R27，DA：R26 版只指名真檔測試，而**真檔依建構
/// 就是乾淨的**——同檔上方 R8 那段自己寫著「退掉零紅」——所以那七句 `#expect(r.<欄位>…)` 是恆真斷言；DA 實測
/// 把一條約束的計算整段失效，被指名的真檔測試全綠、只有 fixture 測試紅。R26 的鍵「從 outlet 導出 needle、搜在
/// 指名測試的本體裡」是對的，指名的測試錯了——同一格的第五把鍵）：
///   - **smoke**（`realFileTestName`）：真檔測試對這個欄位有一句 `#expect(r.<欄位>…`。它證明真檔今天過關，
///     **不證明有人守著這條約束**。
///   - **driven**（`fixtureTestName`）：fixture 測試有一句以合成輸入驅動、寫成 `#expect(… report(…).<欄位> …)`
///     的斷言。這是能紅的那一條。`throw X` 型的 driven needle 是 `#expect(throws: X.self)`。
///
/// **這份清單買到什麼**（同步檢查逐條寫在 `verdictAlphabetIsStatedIdenticallyEverywhere` 裡，數字只在那裡數）：散文的項數
/// 與這裡不同 → 紅；`QueryFileReport` 多一個欄位而沒被列 → 紅；`checkQueryFile` 本體裡 `throw` 後接的識別碼路徑集合與
/// 清單的 `throw ` 項不同 → 紅，且本體裡不得有 `try`（R27，DA：R26 版只用 `Mirror` 守欄位那一邊，`throw` 那一邊零
/// 檢查；R28，requirements／logic：R27 版只認 `throw Ident(` 一種字面，`throw X.y`／`throw err`／`try` 傳播全漏——
/// 現在 `throw` 後的任何識別碼路徑都進集合、與清單不等就紅，`try` 則整個不准出現在本體裡）；某個出口在 smoke 或
/// driven 那條測試的本體裡沒有對應形狀的斷言 → 紅。needle 從 outlet 導出，所以 outlet 字串本身也被釘住（R26）。
///
/// **driven 那一欄的射程：它證明 fixture 測試裡有一行以 `#expect(` 開頭、含識別碼 `report(` 且提到 `).<欄位>`（`throw` 型是
/// `#expect(throws: X.self)`），且那一行不在 `withKnownIssue` 區塊裡——兩種出口都是（R29 DA：R28 版只在欄位分支剔區塊）。
/// 它證明「提到」，不證明「會紅」。** 「會紅」只有變異測試能證，紀錄在每一條約束旁的註解與各輪 verify report 裡。
/// 這個判定本身有臂：`unassertedOutletsIsDrivenByItsOwnFixture`（合成 smoke／driven 本體）。
///
/// **買不到什麼——每一條標明誰在哪一輪構造了什麼、結果如何；沒有構造紀錄的不寫進來**（R27 版寫「每一條都是 R27
/// 實際構造並量過」，R28 三家逐條核：四條裡只有第 1 條符合那句話——第 2 條是 R27 #20 的「屬潛在」、第 3 條是 R25
/// 量的、第 4 條指著同一 commit 已刪的 `assertedIn` 且已被 `requireTest` 關掉。這份清單**依建構不完整**：它只列
/// 構造過的，下一個容器一定還有）：
///   1. **斷言存在但恆真**（R27 DA）：`#expect(r.X.isEmpty` → `#expect(r.X.count >= 0`，訊息、欄位名、`r` 都不動 →
///      needle 仍在、邊界檢查仍過，查詢檔裡留一條活的註解行而 614 條全綠。needle 是純文字比對，它認得「有沒有提到」，
///      認不得「有沒有牙」。同族（未逐一構造）：斷言在永不執行的 closure 裡、斷言在另一個 `r` 上。
///   2. **needle 出現在字串字面裡**（R28 DA 構造；R27 #20 logic 只掃描、標「屬潛在」）：真檔測試的
///      `#expect(r.tooLong.isEmpty, …)` 換成 `#expect(true, Comment(rawValue: "… #expect(r.tooLong.isEmpty) …"))` → 三條
///      測試全綠——`topLevelBodyLines` 剝行尾 `//`、**不剝字串字面**。R26 修的行尾註解是同一類容器的第一種。
///   3. **一條約束把違規記進既有的欄位**（R25 DA 對 `Mirror` 版構造，記進 `tooLong`）：項數不變、欄位不變、`throw`
///      集合不變。已實現的實例：檔首 BOM 有自己的判定、fixture 臂與哨兵值，卻摺進「禁用字元」那一項（R26）。
///   4. **`@Test` 帶 `.disabled` trait**（R28 requirements 構造）：fixture 測試改成 `@Test("…", .disabled("m4"))` →
///      `requireTest` 只看「上一行以 `@Test(` 開頭」，照樣滿足；那條測試從此不跑，八個出口的「能紅的那一條」全部失效，
///      同步 pin 無感。（R27 版這裡寫的是「指到非 `@Test` 的頂層 func」——那個洞已被 `requireTest` 關掉。）
///   5. **driven 臂只斷言不違規的方向**（R28 DA 構造）：刪掉 `headerStructure` 所有 `== [n]` 臂、只留
///      `#expect(try report(header + "ZQXJ-A\nZQXJ-B\n").headerStructure.isEmpty)`，並把 `r.headerStructure` 神經化成 `[]`
///      → 三條全綠。driven needle 分不出「斷言 `== []`」與「斷言 `== [3]`」。
///   6. **driven 臂放進 `withKnownIssue`**（R28 DA 構造，對 R27 版）：`withKnownIssue { #expect((tl).tooLong == [1]) }`
///      ＋ `r.tooLong = []` → passed with known issues——實作壞就被記成已知問題。R28 起 driven 掃描跳過 `withKnownIssue`
///      區塊（`outsideKnownIssueBlocks`）——**但 R28 版只關了一種排版、一種出口**：R29 logic／requirements 把 wrapper 排成多行
///      （`withKnownIssue(`／引數／`) {`）→ 全綠；R29 security 在訊息裡放一個 `}` → 全綠；R29 logic 在區塊裡多閉一層 → 之後每個
///      區塊都算進 driven；R29 DA 對 `throw` 出口做同一構造（那個分支沒套剔除）→ 三條全綠、非 UTF-8 拒答整條失效。**R29 起**：
///      pending 狀態到第一個 `{`、剝字串字面後數、深度夾 0、兩個 driven 分支都剔。**R30 又找到四種**：logic／DA 把多行 wrapper 的
///      引數行寫成含同行閉合的閉包（`Comment(rawValue: xs.map { $0 }.joined())`）→ pending 提早解除、本體漏出；requirements／logic
///      在 `withKnownIssue` 前放一個屬於未追蹤外層的 `}`（`}; withKnownIssue("m") {`）→ 整行 delta 0 判成同行閉合；logic 在被包住的
///      臂裡寫 `"\(flag ? "}" : "")"` → 插值裡的巢狀引號翻轉狀態機、字面 `}` 被當程式碼數；**DA 把真檔測試的 `#expect(r.X…)` 包進
///      `withKnownIssue`** → 違規的查詢檔讓真檔測試 `passed with known issue`、`swift test` exit 0（第七、八把鍵都只裝在 driven
///      本體上，smoke 本體沒剔）。**R30 起**：token 之後才數、本體的 `{` 是小括號深度回到 0 的那一個、插值以括號深度追蹤、
///      **smoke 本體也剔**（四者各有負向臂）。仍不在射程：`if false {`、永不呼叫的 closure、多行字串字面 `"""` 與 raw string 裡的
///      大括號（本檔 driven 臂沒有）、**把 wrapper 搬到被掃本體之外**（`knownGap { … }` 這種 helper——剔除只認出現在本體裡的
///      token，R30 DA）——同第 1 條的同族。
///   7. **`).count` 被無關的 `.count` 滿足**（R28 DA 構造，對 R27 版）：刪掉 `.count == 2` 臂、換成
///      `#expect(requiredHeaderPhrases.joined(separator: " ").count > 0)` → 全綠。**R28 起 driven 行還必須含 `report(`**，
///      所以這個構造今天會紅；`#expect(try report("").count >= 0)` 仍過（那是第 1 條）。代價（R29 regression／requirements）：
///      直接呼叫 `checkQueryFile(`、跨行 `#expect(`、`#require(` 都會被報成「driven 缺」；`report(` 在字串字面裡也算數（第 2 條）。
///   8. **檔頭裡的查詢拆成兩行、或字元間插空白**（R29 DA 對真檔盲測；對 R28 版）：`headerFormerQueries` 逐行比對 → 全綠，
///      而 `grep '^#'` 相鄰印出。**R29 起**比對整個檔頭區塊去空白後的連接文字，這兩個構造今天會紅（跨行記哨兵 0）。射程寫成
///      性質：一條查詢的字元要**依序連續**出現在連接文字裡才擋得住。仍不在射程：字元間插**非空白**字元（實作者在 R29
///      verify-fix 的自測，不是讀者構造）；**把兩半的順序顛倒**放進檔頭（連接鍵順序敏感，`grep '^#'` 仍相鄰印出——R30 DA）；
///      從未進 git 可達歷史、也不在退役清單裡的查詢；改名之後舊名下的版本（見 `historicalQueryFolds` 的射程）。
///   9. **`throw` 換行接型別**（R29 requirements 構造，對 R28 版）：(3) 逐行餵 regex，`throw`／換行／`X()` 整條看不見 → 全綠。
///      **R29 起**對整個本體連接後掃（`throwScanIsDrivenByItsOwnFixture`）。
/// R24 版把數釘在 `Mirror` 的欄位數上，那是**儲存屬性數**不是約束數；這份清單讓漂移變貴，不是變不可能——
/// 而「不可能」那一側只有一種做法：每一項各有一條合成 fixture 臂，且退掉實作時那一臂會紅。那是 driven 那一欄
/// 在要求的事，但**「那句斷言真的會紅」這件事本身沒有靜態檢查能證明**，只有變異測試能。
private let contentConstraints: [(name: String, outlet: String)] = [
    ("檔頭必備短語（只看終止符以前）", "missingHeaderPhrases"),
    ("條數下限", "count"),
    ("不得重複", "duplicateCount"),
    ("退役查詢的子字串比對", "retiredOffenders"),
    ("非註解行的每條純量上限", "tooLong"),
    ("禁用字元（含檔首 BOM，見上方「買不到什麼」第 3 條）", "forbiddenLines"),
    ("檔頭結構：終止符恰好一行、之前只有註解、之後沒有註解", "headerStructure"),
    ("檔頭不得含曾經是查詢的字串——比對整個檔頭區塊去空白後的連接文字（集合由呼叫端給——真檔測試餵 git 可達歷史 ∪ 退役清單）", "headerFormerQueries"),
    ("非 UTF-8 直接拒答", "throw NotUTF8"),
]

/// 取一個**頂層**宣告的函式本體（不含宣告行與收尾大括號）。
///
/// 結尾判準是「第一個在第 0 欄、內容恰為 `}` 的行」——那是本檔每個頂層宣告的收尾形狀，**不是一份會漏的
/// 終止符列舉**（R26：R25 版用 `@Test(`／`private func ` 兩個前綴，漏掉 `private struct`／`enum`／`let`／
/// 裸 `func`／`extension`／`// MARK`，於是「函式本體」這個名字不成立——同檔 `selfEnd` 就是活例）。
/// 查法（兩條都要濾掉這一段註解自己——R27：R26 版的「掃 `"""` 的奇偶」逐字跑回 3，第三個命中就是那句散文，
/// 與腳本檔頭記過的失敗逐字同形）：(a) `grep -v '^///' 本檔 | grep -o '"""' | wc -l` → 偶數，且每一對之間沒有第 0 欄的
/// `}`（本檔唯一一對在 `stub` 那個多行字串，內容全部縮排）；(b) 第 0 欄的 `}` 數 == 第 0 欄以 `{` 收尾的宣告數 ＋ 跨行
/// 簽章的宣告數（R26 版只寫「一起看」，兩個整數對讀者不產生判定）。
///
/// 剝掉整行註解**與行尾 `//` 之後的部分**（R26：R25 版只剝整行註解，`#expect(true)   // …#expect(r.tooLong…`
/// 就能讓一個欄位「沒有斷言卻全綠」，實測過）。字串字面裡的 `//` 也會被剝掉——那個方向是 fail-closed
/// （會多紅、不會少紅），所以不另外處理。
/// 跑一個已設定好的 `Process`：**兩條 pipe 同時排空**，之後才 `waitUntilExit()`。三處子行程共用這一個，不再各寫一套
/// （R27，codex／logic／security／regression 四家：R26 的重排「先讀到 EOF 再 wait」只解掉「wait 排在讀之前」那一種
/// 互鎖，stdout／stderr 仍是**循序**排空——測試端阻塞在 stdout 的 `readToEnd()` 時，子行程把 stderr pipe 寫滿（Darwin
/// 64 KiB）後阻塞、既不結束也不關 stdout）。stderr 在背景 queue 上讀，stdout 在呼叫端讀，兩邊都到 EOF 才 wait。
/// **門檻與射程是量過的，不是推的**（R28 DA，更正 R27 版這裡與 `ecf3aef` commit message 抄自 codex 推理的那句「xtrace
/// 防線失效時會掛死而不是紅」）：循序版對 stderr 60,050 bytes 通過、70,050 bytes `timeout` 124；本版 300 KB 通過。
/// 而 `measureBaselineDoesNotLeakUnderXtrace` 的 fixture 在防線整條失效時（`builtin set +x` → `:`、re-exec 改
/// `/bin/bash -x --`）trace 只有約 20 KB——循序版對它是 35 秒內**具名紅**，不是掛死。查法：對子行程「先寫 N bytes stderr、
/// 再寫 stdout、exit 3」用兩種 runner 各跑一次，N 取 60,050 與 70,050。
private func runDraining(_ process: Process) throws -> (status: Int32, stdout: Data, stderr: Data) {
    let out = Pipe(), err = Pipe()
    process.standardOutput = out; process.standardError = err
    try process.run()
    let errBox = DispatchGroup(); nonisolated(unsafe) var errBytes = Data()
    DispatchQueue.global().async(group: errBox) { errBytes = (try? err.fileHandleForReading.readToEnd()) ?? Data() }
    let outBytes = (try? out.fileHandleForReading.readToEnd()) ?? Data()
    errBox.wait()
    process.waitUntilExit()
    return (process.terminationStatus, outBytes, errBytes)
}

private func topLevelBodyLines(of name: String, in lines: [String], requireTest: Bool = false) -> [String]? {
    let decls = lines.indices.filter { $0 < lines.count && (lines[$0].hasPrefix("func \(name)(") || lines[$0].hasPrefix("private func \(name)(")) }
    guard decls.count == 1, let end = lines[(decls[0] + 1)...].firstIndex(of: "}") else { return nil }
    // smoke／driven 那兩條的宣告行，上一行必須以 `@Test(` 開頭（R27，requirements：R26 版只認 `func NAME(`，指向一個含
    // needle 的 private helper 會全綠而那句斷言從不執行）。**這只證明它是 `@Test`，不證明它會被執行**：`@Test("…", .disabled(…))`
    // 照樣通過而那條測試不跑（R28 requirements 構造；`contentConstraints` 說明「買不到什麼」第 4 條）。
    if requireTest, !(decls[0] > 0 && lines[decls[0] - 1].hasPrefix("@Test(")) { return nil }
    return lines[(decls[0] + 1)..<end].map { line in
        line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
    }.filter { !$0.trimmingCharacters(in: asciiWhitespace).isEmpty }
}

/// `formerQueries`：**曾經是查詢**的字串集合（已經過 `foldLikeJudge`），由呼叫端給——真檔測試從這個檔在 git 歷史裡的
/// 每一個**可達**版本取（`historicalQueryFolds`，射程寫在它自己的說明裡；R30 regression：R29 改了兩處、漏了這一處），fixture
/// 給合成集合。本體裡不得有 `try`（同步測試釘住），所以沒有第二種出口。
private func checkQueryFile(_ data: Data, formerQueries: Set<String> = []) throws -> QueryFileReport {
    var r = QueryFileReport()
    // 檔首 BOM：`String(data:)` 會把它剝掉，bash 與 python 不會——第一行的 `#` 對它們不是行首，檔頭註解會被算成
    // 第 1 條、也混進指紋。這是三邊分岔的唯一位置，而它對解碼後的字串不可見，所以看 bytes（R8）。
    if data.starts(with: [0xEF, 0xBB, 0xBF]) { r.forbiddenLines.append(0) }
    guard let text = String(data: data, encoding: .utf8) else { throw NotUTF8() }
    // 實體行用與 nonCommentLines 同一個切法（CRLF 也切）；註解行的判法也與行定義一致：先 ASCII trim 再看 `#`。
    let physical = text.components(separatedBy: "\n")
    let (header, terminatorIndex) = headerBlock(physical)
    r.missingHeaderPhrases = requiredHeaderPhrases.filter { !header.contains($0) }
    let queries = nonCommentLines(text)
    r.count = queries.count
    // 重複比對與退役檢查共用 `foldLikeJudge`（R24，codex：R23 版是 `Set(queries)` 逐位元相等，只差大小寫或內部空白的兩條
    // 會過「無重複」，卻在 judge 眼中是同一個 needle、並產生兩列實質重複的 measured row。R17 對同一形狀的修法只套到退役
    // 檢查，正上方這一行沒一起關）。**它與 judge 的關係、兩個方向的缺口與各自的查法都只寫在 `foldLikeJudge` 的說明裡，
    // 這裡不複述**（R26：R25 版在這裡還留著「與…judge 同一個正規化」這個已被推翻的框架，而且只提 ß／ς 這一個方向；
    // 我上一輪的 `grep '同形'` 掃不到它，因為它寫的是「同一個正規化」）。
    r.duplicateCount = queries.count - Set(queries.map(foldLikeJudge)).count
    // 正規化見 `foldLikeJudge`（R18 更正 R17 的「同一套」）。R17（codex）指出只比原始字面時，改大小寫或內部空白就能讓污染查詢
    // 重新進基準集，而這是 `contentConstraints` 裡唯一針對「已知污染字串」的一條（項數與列舉都以那份清單為準，這裡不複述；
    // `-diff`＋規則 1 讓 reviewer 不准讀內容。R26：R25 版在這裡寫了「六項」兩次、又說「六項列在 maxQueryScalars 的說明」，
    // 而同一個 commit 已把說明改成「不再複述」——以單一來源為目的的改動在同一個檔案裡留下第三份複本，而新 pin 是全檔
    // `contains` 所以看不見它）。
    let foldedRetired = retired.map(foldLikeJudge)
    r.retiredOffenders = queries.indices.filter { i in foldedRetired.contains { foldLikeJudge(queries[i]).contains($0) } }.map { $0 + 1 }
    r.tooLong = queries.indices.filter { queries[$0].unicodeScalars.count > maxQueryScalars }.map { $0 + 1 }
    r.forbiddenLines += physical.enumerated()
        .filter { $0.element.unicodeScalars.contains(where: isForbiddenScalar) }.map { $0.offset + 1 }
    // **檔頭終止符之後不得有註解行**（R26 codex 提的性質；R27 修好它的錨點，見 `headerTerminator`）。
    //
    // **這條約束買到的是「註解行只能在終止符之前」，不是「`grep '^#'` 印出來的只有檔頭契約」**——檔頭區塊的
    // **內容**只受下面 `headerFormerQueries` 那一條約束（R28 加、R29 改成對整個檔頭區塊的無空白連接比對），長度、
    // 重複、純量上限一律不適用（R27 security／regression 各自實測：塞 200 字元段落，八條全過；「檔頭放一行含查詢的
    // 註解，八條全過」在 R28 之前為真、今天會紅——R29 regression 指出這段註解在 R28 沒跟著改）。退役一條查詢
    // **必須刪除**。這一段與下面那一段合起來才是規則 1 那句安全宣稱的確切射程。
    // 終止符**之前**也只准註解與空行——否則把檔頭整段搬到檔尾、查詢排在它前面，終止符仍然找得到、短語仍然
    // 「在檔頭裡」（R25 的那一臂就是防這個）。兩個方向合起來才是「檔頭 ＝ 終止符以前，且只有檔頭在那裡」。
    r.headerStructure = terminatorIndex.map { t in
        physical.enumerated().compactMap { i, line -> Int? in
            let c = line.trimmingCharacters(in: asciiWhitespace)
            if i > t { return c.hasPrefix("#") ? i + 1 : nil }
            if i < t { return (c.isEmpty || c.hasPrefix("#")) ? nil : i + 1 }
            return nil
        }
    } ?? [0]
    // **檔頭不得含曾經是查詢的字串**（R28，DA：終止符的位置由被約束方自選——第一條查詢就地加 `#` **並把終止符往下挪一行**，
    // 兩個編輯，八條約束全綠，`grep '^#'` 照樣印出那條仍然活著的查詢；`-diff` 讓 reviewer 只看得到 `Bin 4402 -> 44xx`，
    // 一個編輯與兩個編輯不可分辨。R27 #2 提過兩條機制修法，R27 選了寫射程句，而射程句仍過強）。集合由呼叫端給——真檔
    // 測試餵的是**這個檔在 git 裡每一個可達版本**的每一條查詢（含現行）加上已知污染的退役清單（`retired`；R29 regression：
    // 那六條從未以非註解行進過這個檔，R28 版的歷史集合抓不到它們），fixture 餵合成集合。
    //
    // **比對單位是整個檔頭區塊、去掉全部空白之後的連接文字**，不是行（R29 DA 對真檔盲測：R28 版逐行比對，同一條查詢對半
    // 切成兩行相鄰的 `# ` 全綠，而 `grep '^#'` 把兩行相鄰印出來、reviewer 一眼接回去；在 CJK 查詢中間插一個空格也穿透，因為
    // `foldLikeJudge` 只摺既有空白、不刪空白）。行號那一欄仍逐行算（有行號的優先），連接文字命中而沒有任何單行命中時記
    // 哨兵 `0`（與 BOM／終止符同慣例）。**它擋不住的**（R29 量過、未關）：在查詢字元之間插入**非空白**字元（例如 `-`），或
    // 從未進過 git 歷史、也不在退役清單裡的查詢。
    // 檔頭區塊 ＝ 終止符（含）以前；終止符缺少或重複時是前導連續註解與空行（索引沿用 `physical`，行號是實體行號——R29 logic：
    // R28 版走 `headerBlock` 的壓縮陣列，空行會讓回報的行號往前位移）。
    let headerIndices: [Int] = terminatorIndex.map { Array(0...$0) } ?? Array(physical.indices.prefix { i in
        let t = physical[i].trimmingCharacters(in: asciiWhitespace); return t.isEmpty || t.hasPrefix("#")
    })
    let squash = { (s: String) -> String in String(s.filter { !$0.isWhitespace }) }
    let commentBody = { (line: String) -> String in String(line.trimmingCharacters(in: asciiWhitespace).drop { $0 == "#" }) }   // 去掉行首的 `#`，否則跨行連接時 `#` 會卡在中間
    let formerSquashed = formerQueries.map { squash(foldLikeJudge($0)) }.filter { !$0.isEmpty }
    let foldedHeaderLines = headerIndices.map { (index: $0, text: squash(foldLikeJudge(commentBody(physical[$0])))) }
    let perLine = foldedHeaderLines.filter { line in formerSquashed.contains { line.text.contains($0) } }.map { $0.index + 1 }
    let wholeHeader = squash(foldLikeJudge(headerIndices.map { commentBody(physical[$0]) }.joined()))
    // 跨行命中記哨兵 0，**與單行命中並列**（R30 requirements：R29 版寫成 `perLine.isEmpty ? …`，只要有任何單行命中就把跨行那筆
    // 藏起來，作者刪掉單行那條之後才看得到第二筆——判定不受影響，但要兩趟才報得完）。「跨行」的定義是**這一條**在連接文字裡
    // 命中、卻不在任何單一行裡，不是「沒有任何單行命中」。
    let spansLines = formerSquashed.contains { q in wholeHeader.contains(q) && !foldedHeaderLines.contains { $0.text.contains(q) } }
    r.headerFormerQueries = perLine + (spansLines ? [0] : [])
    return r
}

/// 這個檔在 git 裡**每一個可達版本**（`git log --all --full-history`：所有 ref、不做歷史簡化；含工作樹現況）的非註解行，各經
/// `foldLikeJudge`。在行程內取、不印、不落地；真檔測試用它餵 `checkQueryFile(formerQueries:)`。
///
/// **射程（R29 logic／requirements／security 各自以 dummy repo 量過，R28 版寫「每一個版本」是全稱過頭）**：
///   - `--all` 涵蓋所有 ref 可達的 commit；被 `branch -D`／amend／rebase 掉、只剩 reflog 或懸空的版本**不在**（`rev-list --all`
///     不走 reflog）。`--full-history` 關掉 merge 處的歷史簡化（側支版本才會列）。
///   - **不跟隨改名**（無 `--follow`）：改名之後舊名下的版本消失。`relativePath` 是寫死的常數，改名時要一併決定歷史怎麼接。
///   - 淺 clone 只看得到它有的那幾個 commit。
///   - `git log` 回**零個版本**時 `throw NoHistory`（R29 logic：R28 版靜默退化成「只比工作樹」，而工作樹依定義不含被 `#`
///     退役的查詢——約束變恆真、測試綠）。`git show` 對某一版非 0（該版本沒有這個檔，例如刪檔重建那個 commit）→ 跳過那一版
///     （R29 requirements／regression：R28 版一律 throw，訊息說「git 不可用」而成因是歷史裡有刪除節點）——判「有沒有這條路徑」
///     用 `ls-tree`（只要 tree 物件），`show` 非 0 一律具名 throw（R30 DA：R29 版一律 `continue`，blobless partial clone 離線時
///     每一版 `show` 都 128、集合靜默退化成只有工作樹）；`git log` 本身非 0 → `throw GitFailed`。錯誤只帶子命令名與 status，**不帶 git 的 stderr**（`git show` 的 fatal 訊息含路徑不含內容，但這裡
///     一律不轉述）。
///   - 子行程環境只留 `PATH`／`HOME`：清掉呼叫端的 `GIT_DIR`／`GIT_WORK_TREE` 等（R29 logic：那會讓 git 去查別的倉庫、回空、以 0 離開）。
/// 臂：`historicalQueryFoldsIsDrivenByItsOwnFixture`（合成 repo：刪檔重建、側支版本、零歷史；R29 regression：R28 版整段
/// `for h in hashes` 拔掉五條測試全綠，而它正是這條約束對它建出來的那個威脅唯一還握有查詢的一半）。
private func historicalQueryFolds(root: URL, relativePath: String) throws -> Set<String> {
    func git(_ args: [String]) throws -> (status: Int32, stdout: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.currentDirectoryURL = root
        p.arguments = ["git"] + args
        let inherited = ProcessInfo.processInfo.environment
        p.environment = ["PATH": inherited["PATH"] ?? "/usr/bin:/bin", "HOME": inherited["HOME"] ?? "/"]
        let r = try runDraining(p)
        return (r.status, r.stdout)
    }
    let log = try git(["log", "--all", "--full-history", "--format=%H", "--", relativePath])
    guard log.status == 0 else { throw GitFailed(subcommand: "log", status: log.status) }
    let hashes = String(data: log.stdout, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
    guard !hashes.isEmpty else { throw NoHistory(relativePath: relativePath) }
    var folds = Set(nonCommentLines(try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)).map(foldLikeJudge))
    for h in hashes {
        // 「該版本沒有這個檔」與「物件拿不到」要分開（R30 DA：R29 版對 `git show` 的任何非 0 一律 `continue`，於是 blobless
        // partial clone 離線時——`log` 非空、每一版 `show` 都 128——集合靜默退化成只有工作樹、不 throw 不紅，R29 #6 的靜默縮小
        // 沿另一條軸復活；同一條 `continue` 也吞物件損壞與權限）。`ls-tree` 只要 tree 物件（blobless clone 也有），所以它能
        // 判「有沒有這條路徑」而不必取 blob：空輸出＝這一版沒有這個檔，其餘非 0 一律具名 throw。
        let listing = try git(["ls-tree", "--name-only", h, "--", relativePath])
        guard listing.status == 0 else { throw GitFailed(subcommand: "ls-tree", status: listing.status) }
        if (String(data: listing.stdout, encoding: .utf8) ?? "").trimmingCharacters(in: asciiWhitespace).isEmpty { continue }   // 刪除節點
        let blob = try git(["show", "\(h):\(relativePath)"])
        guard blob.status == 0 else { throw GitFailed(subcommand: "show", status: blob.status) }
        guard let text = String(data: blob.stdout, encoding: .utf8) else { continue }   // 非 UTF-8 的歷史版本：那一版的查詢在別的判準下已經不算查詢
        folds.formUnion(nonCommentLines(text).map(foldLikeJudge))
    }
    return folds
}

private struct GitFailed: Error { let subcommand: String; let status: Int32 }

/// 合成 repo（全部 `ZQXJ-*` 內容、用完即刪）：A→B→刪檔→C（main）；側支 D **併回後刪掉分支**；main 再 E；另一條**還活著**的
/// 側支 F。期望 {A,B,C,D,E,F}——**兩個 flag 各有自己的臂**（R30 regression：R29 版只有一條活側支，D 靠 `--all` 就到、沒有 merge
/// 所以簡化沒東西可丟，單獨拿掉 `--full-history` 全綠，而 doc 與 commit message 把它的貢獻歸給了 `--full-history`）：
/// 拿掉 `--all` → F 不見（未併回的活分支）；拿掉 `--full-history` → D 不見（併回後刪掉的分支，merge 對 parent 1 TREESAME）。
/// 另外：刪除節點由 `ls-tree` 判掉，物件拿不到則具名 throw（刪掉 HEAD 版本的 loose blob 那一臂）。
@Test("historicalQueryFolds 由合成 git repo 驅動：刪除節點跳過、併回後刪掉的分支靠 --full-history、未併回的活分支靠 --all、blob 缺失具名 throw、零歷史與非 repo 具名 throw")
func historicalQueryFoldsIsDrivenByItsOwnFixture() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    func git(_ args: String...) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.currentDirectoryURL = dir
        p.arguments = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        // 環境比照生產側再收一層（R30 security：R29 版繼承完整環境，呼叫端的 `GIT_DIR`／`GIT_WORK_TREE`／`GIT_INDEX_FILE`
        // 會讓這個 fixture 的 `init`／`commit` **寫進**別的倉庫，全域 `core.hooksPath`／`init.templateDir` 的 hook 也會執行）。
        let inherited = ProcessInfo.processInfo.environment
        p.environment = ["PATH": inherited["PATH"] ?? "/usr/bin:/bin", "HOME": inherited["HOME"] ?? "/",
                         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let r = try runDraining(p); try #require(r.status == 0, "git \(args.first ?? "") 以 \(r.status) 離開")
    }
    func gitOut(_ args: String...) throws -> Data {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.currentDirectoryURL = dir
        p.arguments = ["git"] + args
        let inherited = ProcessInfo.processInfo.environment
        p.environment = ["PATH": inherited["PATH"] ?? "/usr/bin:/bin", "HOME": inherited["HOME"] ?? "/",
                         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let r = try runDraining(p); try #require(r.status == 0, "git \(args.first ?? "") 以 \(r.status) 離開")
        return r.stdout
    }
    let f = dir.appendingPathComponent("q.txt")
    func write(_ body: String) throws { try (headerTerminator + "\n" + body + "\n").write(to: f, atomically: true, encoding: .utf8) }
    try git("init", "-q", "-b", "main")
    try write("ZQXJ-A"); try git("add", "q.txt"); try git("commit", "-qm", "1")
    try write("ZQXJ-B"); try git("add", "q.txt"); try git("commit", "-qm", "2")
    try git("rm", "-q", "q.txt"); try git("commit", "-qm", "3")
    try write("ZQXJ-C"); try git("add", "q.txt"); try git("commit", "-qm", "4")
    try git("checkout", "-qb", "side"); try write("ZQXJ-D"); try git("add", "q.txt"); try git("commit", "-qm", "5")
    try git("checkout", "-q", "main"); try write("ZQXJ-E"); try git("add", "q.txt"); try git("commit", "-qm", "6")
    try git("merge", "-q", "-s", "ours", "side", "-m", "merge"); try git("branch", "-qD", "side")   // D 只剩 merge 的第二 parent 可達
    try git("checkout", "-qb", "side2"); try write("ZQXJ-F"); try git("add", "q.txt"); try git("commit", "-qm", "7")
    try git("checkout", "-q", "main")
    let folds = try historicalQueryFolds(root: dir, relativePath: "q.txt")
    #expect(folds == Set(["ZQXJ-A", "ZQXJ-B", "ZQXJ-C", "ZQXJ-D", "ZQXJ-E", "ZQXJ-F"].map(foldLikeJudge)), Comment(rawValue: "\(folds.count) 條"))
    try "x\n".write(to: dir.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
    #expect(throws: NoHistory.self) { try historicalQueryFolds(root: dir, relativePath: "untracked.txt") }
    // 物件拿不到（≠ 該版本沒有這個檔）：刪掉 HEAD 版本的 loose blob → `ls-tree` 仍列得出路徑、`show` 非 0 → 具名 throw
    // （R30 DA 的 blobless partial clone 離線那條路的可重現替身）。
    let blobHash = try #require(String(data: gitOut("rev-parse", "HEAD:q.txt"), encoding: .utf8)?.trimmingCharacters(in: asciiWhitespace))
    try FileManager.default.removeItem(at: dir.appendingPathComponent(".git/objects/\(blobHash.prefix(2))/\(blobHash.dropFirst(2))"))
    #expect(throws: GitFailed.self) { try historicalQueryFolds(root: dir, relativePath: "q.txt") }
    let notRepo = try tempDir(); defer { try? FileManager.default.removeItem(at: notRepo) }
    try "x\n".write(to: notRepo.appendingPathComponent("q.txt"), atomically: true, encoding: .utf8)
    #expect(throws: GitFailed.self) { try historicalQueryFolds(root: notRepo, relativePath: "q.txt") }
}
private struct NoHistory: Error { let relativePath: String }

@Test("baseline-queries.txt 過 contentConstraints 的每一條（項目以那份清單為準，標題不數；失敗訊息只帶序號）")
func baselineQueryFileDocumentsItsContractAndRetiresThePollutedQueries() throws {
    let data = try Data(contentsOf: repoRoot().appendingPathComponent("scripts/baseline-queries.txt"))
    // git 歷史那一半失敗時具名紅在**環境**那一側、其餘八條照跑（R29 regression：R28 版把 `try` 放在引數位置，`.git` 不在時
    // 這八條 smoke 一條都不執行，訊息 `GitUnavailable(status: 128)` 也沒說是環境。**八不是九**——九是 `contentConstraints`
    // 的項數，第九項 `throw NotUTF8` 依設計沒有 smoke 臂；查法：`sed -n '<本測試本體>' | grep -c '#expect(r\.'` → 8，R30
    // regression 指出 R29 把 report 的「nine smoke arms」抄進兩份 artifact 而沒帶查法）；與 `.gitattributes` 那條同一套處置。
    // 只接住 git 那一側的具名錯誤：R30 requirements 指出 R29 版 `catch` 吃掉所有錯誤，而工作樹檔案非 UTF-8 時
    // `String(contentsOf:encoding:)` 丟的是 Cocoa 解碼錯誤——那是**檔案**錯了，訊息卻說「是環境」。其餘錯誤照常傳出。
    // **無臂**（R30 實測：換回 `catch { … }`，六條測試全綠）——要驅動它得讓**真檔**變成非 UTF-8，而那正是規則 1 禁止的
    // 就地改動；方向 fail-closed（多一個具名錯誤，不會少紅）。
    let history: Set<String>?
    do { history = try historicalQueryFolds(root: repoRoot(), relativePath: "scripts/baseline-queries.txt") }
    catch let error as GitFailed { history = nil; Issue.record(Comment(rawValue: "取不到查詢檔的 git 歷史（\(error)）：`headerFormerQueries` 這一條只對照退役清單、沒有對照歷史——是環境（不在 git checkout、PATH 上沒有 git、物件拿不到），不是檔案錯了")) }
    catch let error as NoHistory { history = nil; Issue.record(Comment(rawValue: "取不到查詢檔的 git 歷史（\(error)）：這個路徑在 git 裡沒有任何可達版本——是環境，不是檔案錯了")) }
    let r = try checkQueryFile(data, formerQueries: (history ?? []).union(retired.map(foldLikeJudge)))
    #expect(r.missingHeaderPhrases.isEmpty, Comment(rawValue: "檔頭缺：\(r.missingHeaderPhrases)"))
    #expect(r.count >= 6, "基準查詢至少 6 條，得 \(r.count)")
    #expect(r.duplicateCount == 0, "查詢重複：\(r.duplicateCount) 條")
    #expect(r.retiredOffenders.isEmpty, Comment(rawValue: "含退役查詢的條目序號：\(r.retiredOffenders)"))
    #expect(r.tooLong.isEmpty, Comment(rawValue: "超過 \(maxQueryScalars) 個純量的條目序號：\(r.tooLong)"))
    #expect(r.forbiddenLines.isEmpty, Comment(rawValue: "含禁止純量（控制字元、非 ASCII 空白；0 = 檔首 BOM）的行號：\(r.forbiddenLines)"))
    #expect(r.headerStructure.isEmpty, Comment(rawValue: "檔頭結構違規行號（終止符後的註解行／終止符前的非註解行；0 ＝ 終止符缺少或重複。退役要刪除、不得註解保留）：\(r.headerStructure)"))
    #expect(r.headerFormerQueries.isEmpty, Comment(rawValue: "檔頭裡含曾經是查詢（git 任一可達版本、或退役清單）的字串的行號（0 ＝ 跨行拼出來的）——退役要刪除、不得搬進檔頭：\(r.headerFormerQueries)"))
}

@Test("查詢檔檢查由合成 fixture 驅動：CRLF 下的行號、檔首 BOM、行中 BOM、NUL、U+0001、U+3000、DEL、超長、重複、退役、檔頭缺短語——各自為對的理由紅；行中 tab 與尾隨空白不禁")
func queryFileChecksAreDrivenByTheirOwnFixture() throws {
    let headerNoTerm = "# " + requiredHeaderPhrases.joined(separator: " ") + "\n"
    let header = headerNoTerm + headerTerminator + "\n"
    func report(_ s: String, bom: Bool = false, former: Set<String> = []) throws -> QueryFileReport {
        try report(bytes: (bom ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(s.utf8), former: former)
    }
    func report(bytes: Data, former: Set<String> = []) throws -> QueryFileReport { try checkQueryFile(bytes, formerQueries: former) }
    #expect(try report(header + "ZQXJ-A\nZQXJ-B\nZQXJ-C\nZQXJ-D\nZQXJ-E\nZQXJ-F\n") == QueryFileReport(count: 6))
    #expect(try report(header + "ZQXJ-A\n \n\nZQXJ-B\n").count == 2)   // 條數：空行與只含空白的行不算（driven 臂，R27）
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
    // 只差大小寫／內部空白也算重複（R24，codex：R23 版比逐位元相等，這兩條會過「無重複」卻是 judge 眼中的同一個 needle）。
    #expect(try report("ZQXJ A B\nzqxj  a\tb\n").duplicateCount == 1)
    #expect(try report("ZQXJ-A B\nZQXJ-A  C\n").duplicateCount == 0)   // 摺疊之後仍不同：不算重複
    // 摺成**什麼**（R25：R24 的兩條只驅動「有沒有摺疊」——把 `joined(separator: " ")` 改成 `""` 全綠，而分隔符正是
    // judge 的 `" ".join(...)` 在講的事）。空白摺成一個空白時這兩條是不同的 needle；刪掉空白則會被誤判成重複。
    #expect(try report("ZQXJ-A B\nZQXJ-AB\n").duplicateCount == 0)
    // `foldLikeJudge` 與 judge 的兩個方向：釘成 fixture，否則那三對輸入只以散文查法存在、會無聲漂移（R26，codex）。
    // 方向一 **fold 較窄**（`lowercased()` ≠ Python `casefold()`）——judge 判相等、這裡判不等。**這是一個 fail-open
    // 的缺口**（judge 眼中同一個 needle 的兩條會通過「無重複」），所以包進 `withKnownIssue`：被包住的斷言寫的是缺口
    // **不存在**時的值，`withKnownIssue` 把它今天的失敗記成已知問題。**缺口被修掉時這條會紅**——swift-testing 預設
    // `isIntermittent: false`，body 沒記錄任何 issue 就記一筆 `Known issue was not recorded`——屆時拆掉包裝即可；**不要**
    // 改成 `isIntermittent: true`，那會讓兩個方向都靜默過（R28 security／regression 各自實測，更正 R27 版這裡與
    // `ecf3aef` **測試檔註解**（:305）的「自動轉綠、不用刪」——R29 的替換句把載體寫成 commit message，而那裡的計數是 0
    // （R30 security；`issuecomment-5754103526` 更正的正是這個誤歸，R30 的 errata 再更正這一行）；R27，DA：R26 版寫成
    // `== 0` 的正向 fixture，等於把缺口釘死——
    // 照文件說的方向修好 fold，三條就一起紅，維護者最可能的反應是把修法退回去）。
    let foldGap = try (report("ZQXJ-\u{00DF}\nZQXJ-SS\n").duplicateCount,          // ß vs SS
                       report("ZQXJ-\u{03C2}\nZQXJ-\u{03C3}\n").duplicateCount,   // ς vs σ
                       report("ZQXJ-\u{FB01}le\nZQXJ-file\n").duplicateCount)      // ﬁ(U+FB01) vs fi
    withKnownIssue("foldLikeJudge 比 judge 的 casefold 窄：ß/SS、ς/σ、ﬁ/fi 在 judge 是同一個 needle，這裡不是（fail-open，已揭露）") {
        #expect(foldGap == (1, 1, 1))
    }
    // 方向二 **比對較寬**：`Set` 走 Swift String 的正則等價，judge 的 `norm()` 判不等。這一軸與 fold 函式無關
    // （換成手工 case fold 也碰不到它），方向是 fail-closed。**這一條驅動不了 `foldLikeJudge`**——它斷言的是
    // Swift String 比較本身的性質；留著是因為換掉**容器**（例如改成比 UTF-8 bytes）時它會紅（R26）。
    // 方向一那三條的實測（R27 更正 R26 寫的「兩條紅」與 `2201a25` commit message 的同一句——**三條全紅**：
    // `String.CompareOptions.caseInsensitive` 的 folding 本來就做完整 case folding，`"ß".folding(…)` → `"ss"`）：
    // 把 `lowercased()` 換成 `folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])`，三對全判相等。
    #expect(try report("ZQXJ-e\u{0301}\nZQXJ-\u{00E9}\n").duplicateCount == 1)  // NFD vs NFC
    #expect(try report("ZQXJ-A\n" + retired[0] + "\n").retiredOffenders == [2])
    #expect(try report("ZQXJ-A\n" + retired[0].uppercased().replacingOccurrences(of: " ", with: "  \t") + "\n").retiredOffenders == [2])   // 大小寫與內部空白改寫也算退役（R17）
    #expect(try report("ZQXJ-A\n").missingHeaderPhrases.count == requiredHeaderPhrases.count)
    #expect(throws: NotUTF8.self) { try report(bytes: Data([0xFF, 0xFE, 0x41])) }   // 非 UTF-8：拒答不猜
    // 終止符之後不得有註解行（R26 codex 提的是「第一條查詢之後」，R27 換成終止符：把一條查詢加 `#` 退役會讓它脫離其餘
    // 每一條內容約束，而規則 1 指定的 `grep '^#'` 會把那條仍然活著的查詢原樣印出來）。行號是實體行號。
    #expect(try report(header + "ZQXJ-A\n# retired by commenting\nZQXJ-B\n").headerStructure == [4])
    #expect(try report(header + "ZQXJ-A\nZQXJ-B\n").headerStructure.isEmpty)
    #expect(try report(header + "ZQXJ-A\n\n   # indented, still a comment\n").headerStructure == [5])
    // **退役第一條**：R26 版的錨點（「第一個非註解行之後」）對這一形狀全綠，因為那一行會升格成檔頭（R27 四家實測）。
    #expect(try report(header + "# ZQXJ-RETIRED-FIRST\nZQXJ-B\nZQXJ-C\n").headerStructure == [3])
    // 終止符缺少／重複 → 哨兵 0（與檔首 BOM 同慣例）。缺少時前導註解仍當檔頭，所以 missingHeaderPhrases 不受影響。
    #expect(try report(headerNoTerm + "ZQXJ-A\n").headerStructure == [0])
    #expect(try report(headerNoTerm + "ZQXJ-A\n").missingHeaderPhrases.isEmpty)
    #expect(try report(header + headerTerminator + "\nZQXJ-A\n").headerStructure == [0])
    // 檔頭必須在**第一條查詢之前**（R25，codex：R24 版收的是全檔任意註解，查詢在前、規則註解在後——真正的檔頭
    // 已經消失——仍然全綠）。同一份短語、只是換到檔尾，就該全缺。
    #expect(try report("ZQXJ-A\nZQXJ-B\n" + header).headerStructure == [1, 2])   // 查詢排在終止符之前 → 結構紅（R27；R25 版紅在短語）
    #expect(try report("ZQXJ-A\nZQXJ-B\n" + headerNoTerm).missingHeaderPhrases.count == requiredHeaderPhrases.count)   // 沒有終止符時退回前導區塊：檔頭在檔尾 → 全缺
    let leadingBlank = try report("\n\n" + header + "ZQXJ-A\n")
    #expect(leadingBlank.missingHeaderPhrases.isEmpty && leadingBlank.headerStructure.isEmpty)   // 終止符之前准許空行（R28 logic：R27 版這一臂只斷短語，`c.isEmpty ||` 無臂）
    #expect(try report("\n\n" + headerNoTerm + "ZQXJ-A\n").missingHeaderPhrases.isEmpty)   // 沒有終止符時的前導區塊也跳過前導空行（R28 logic：這條才走 `headerBlock` 的 fallback）
    // 檔頭不得含曾經是查詢的字串（R28，DA：`#` ＋ 挪終止符兩個編輯全綠）。集合由呼叫端給、已 fold；子字串包含；
    // 行號是檔頭區塊內的實體行號。空集合時永遠空（真檔測試餵的是 git 歷史，這裡餵合成）。
    let moved = headerNoTerm + "# retired: ZQXJ-A\n" + headerTerminator + "\nZQXJ-B\n"
    #expect(try report(moved, former: [foldLikeJudge("ZQXJ-A")]).headerFormerQueries == [2])
    #expect(try report(moved, former: [foldLikeJudge("zqxj-a")]).headerFormerQueries == [2])   // 比對走同一個 fold（大小寫）
    #expect(try report(moved).headerFormerQueries.isEmpty)
    #expect(try report(moved, former: [foldLikeJudge("ZQXJ-B")]).headerFormerQueries.isEmpty)   // 現行查詢在查詢區、不在檔頭 → 不算
    #expect(try report(headerNoTerm + "# retired: ZQXJ-A\nZQXJ-B\n", former: [foldLikeJudge("ZQXJ-A")]).headerFormerQueries == [2])   // 沒有終止符：前導區塊也查
    #expect(try report("\n" + headerNoTerm + "\n# retired: ZQXJ-A\nZQXJ-B\n", former: [foldLikeJudge("ZQXJ-A")]).headerFormerQueries == [4])   // 沒有終止符＋空行：行號仍是實體行號（R29 logic）
    // 比對單位是整個檔頭去空白後的連接文字（R29 DA：R28 版逐行，拆成兩行或插一個空格就穿透）。跨行命中記哨兵 0。
    let split = headerNoTerm + "# ZQX\n# J-LONG\n" + headerTerminator + "\nZQXJ-B\n"
    #expect(try report(split, former: [foldLikeJudge("ZQXJ-LONG")]).headerFormerQueries == [0])
    // 單行命中與跨行命中並存 → 兩筆都報（R30 requirements：R29 版只報單行那筆，要兩趟才看得完）
    let bothShapes = headerNoTerm + "# ZQXJ-A\n# ZQX\n# J-LONG\n" + headerTerminator + "\nZQXJ-B\n"
    #expect(try report(bothShapes, former: [foldLikeJudge("ZQXJ-A"), foldLikeJudge("ZQXJ-LONG")]).headerFormerQueries == [2, 0])
    #expect(try report(headerNoTerm + "# Z Q X J-A\n" + headerTerminator + "\nZQXJ-B\n", former: [foldLikeJudge("ZQXJ-A")]).headerFormerQueries == [2])   // 插空白仍命中
    #expect(try report(headerNoTerm + "# ZQX-J-A\n" + headerTerminator + "\nZQXJ-B\n", former: [foldLikeJudge("ZQXJ-A")]).headerFormerQueries.isEmpty)   // 插非空白字元：擋不住（量過、未關）
    #expect(try report(moved, former: [""]).headerFormerQueries.isEmpty)   // 空針不得命中任何行（R29：Swift 的 `contains("")` 本來就 false，這條守的是換容器之後）
    #expect(try report(headerNoTerm + "# " + retired[0] + "\n" + headerTerminator + "\nZQXJ-B\n", former: [foldLikeJudge(retired[0])]).headerFormerQueries == [2])   // 退役清單也進集合（真檔測試餵 history ∪ retired）
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

@Test("ScriptRun.physicalLines：保留中間與尾端的空行，只丟掉正常結尾造成的那一個尾端空元素；沒有換行收尾時殘行算一列")
func physicalLinesKeepsBlankLines() {
    // R24：`components(separatedBy:)` 這個改動（R23，codex）退回 `split` 後 18 條測試全綠——無臂、也沒標無臂。這條是它的臂：
    // 退回 `split(separator: "\n")` 時，下面三個「中間／尾端有空行」的期望會少掉那些空元素而紅。
    func run(_ out: String) -> ScriptRun { ScriptRun(status: 0, stdout: out, stderr: "") }
    #expect(run("set\n#1 1ms clean\n").physicalLines == ["set", "#1 1ms clean"])   // 正常結尾：丟掉那一個尾端空元素
    #expect(run("set\n\n#1 1ms clean\n").physicalLines == ["set", "", "#1 1ms clean"])   // 中間的空行留著（split 會丟掉）
    #expect(run("set\n#1 1ms clean\n\n").physicalLines == ["set", "#1 1ms clean", ""])   // 多印一個空行：留著，rows 因此多一筆
    #expect(run("set\n#1 1ms cle").physicalLines == ["set", "#1 1ms cle"])   // 沒有換行收尾：殘行照算一列（正規化不檢查這件事）
    #expect(run("").physicalLines == [] && run("").setLine == "")
    #expect(run("\n").physicalLines == [""] && run("\n").setLine == "")   // 只印了一個空行：setLine 也是 ""，與「什麼都沒印」分不出（兩條重導失敗的 70 那一臂因此用 stdout.isEmpty，見 `expectSetLine`）
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
                    // 字面 token 的形狀：純小寫字母、且不以 sig 開頭（valid_row 先攔 sig*；R21：R20 版只釘第一半，`signal` 過測試卻在執行期被改寫）。
                    if raw.range(of: "^(?!sig)[a-z]+$", options: .regularExpression) != nil { emitted.insert(raw) } else { unrecognised.append(raw) }
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
    let queryHeader = headerBlock(try String(contentsOf: root.appendingPathComponent("scripts/baseline-queries.txt"), encoding: .utf8)
        .components(separatedBy: "\n")).text   // 檔頭＝終止符（含）以前（R27；R25 版是前導連續註解、R24 版是全檔任意註解）
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
    // 三處各自的**多重度**也要驗（R25，codex：只用 Set 比對等於放棄多重度，而那正是「七個」這個數字唯一的載體——
    // 常數裡一個重複、一個被刪，`count == 7` 與兩個 Set 比對都還成立，「七個」已經退化成六個而全綠）。
    #expect(constantFields.count == 7 && Set(constantFields).count == 7, Comment(rawValue: "常數：\(constantFields)"))
    #expect(readmeFields.count == 7 && Set(readmeFields) == Set(constantFields), Comment(rawValue: "README 表：\(readmeFields)"))
    #expect(headerFields.count == 7 && Set(headerFields) == Set(constantFields), Comment(rawValue: "查詢檔檔頭：\(headerFields)；少了 \(Set(constantFields).subtracting(headerFields).sorted())"))
    #expect(headerLimit == limit, Comment(rawValue: "查詢檔檔頭的截斷長度 \(headerLimit) ≠ toolMetadataFieldLimit \(limit)"))
    let readmeLimits = limitMentions(readme), scriptLimits = limitMentions(script)
    #expect(readmeLimits == [limit] && scriptLimits == [limit], Comment(rawValue: "README／腳本檔頭出現的「N 字元」不全等於 toolMetadataFieldLimit \(limit)：README \(readmeLimits.sorted()) 腳本 \(scriptLimits.sorted())"))
    // R9 的收穫要有鎖：查詢內容只能經 process substitution 的管線給指紋 python 與迴圈——herestring 在 bash 3.2 會寫
    // $TMPDIR 暫存檔、而且會補尾端換行讓 `|| [ -n "$raw" ]` 再度死掉（R10：兩處退回去全綠）。
    // 只數程式碼行（整行註解濾掉；codeText 與下方離開碼那段共用）：R11 把迴圈改回 `< "$QF"` 再放一條含原字面的註解，
    // 整檔字面計數照樣 2。這條鎖**是拼法列舉，不是「只開一次」的證明**（R13：把鍵從 `< "$QF"` 換成識別碼 `$QF` 之後，
    // `cat "$HERE/baseline-queries.txt"`、`cat "${LTM_BASELINE_QUERIES:-…}"`、`wc -l < "$HERE/…"` 照樣穿過——鍵換了、形狀沒換，
    // CLAUDE.md #34／#37 那句）。腳本裡能指到查詢檔的拼法有三種，三種各釘一個次數：識別碼 `$QF`／`${QF}` 7 次（-f/-r 那行 3、
    // read 1、三句錯誤訊息 3）、檔名字面 `baseline-queries.txt` 1 次（QF 的預設值）、環境變數名 `LTM_BASELINE_QUERIES` 2 次
    // （白名單變數那一行 1 次＋QF 賦值 1 次）；多一次就是多一條路徑或多一處訊息，都要來這裡對帳。它守得住的較窄陳述是「用這三種拼法之一再開一次會紅」；
    // 先把路徑存進第四個名字再開，這裡看不到——要判準版得觀察 open 系統呼叫，不可攜，不做。README 的量測段用同一句話。
    // 呼叫端 shell 環境經繼承進來的那一面由前四行程式碼一次清掉：`builtin trap - …`、`builtin set +x`、白名單變數、re-exec 的 `case`
    // （細節只有一份，在腳本檔頭；這段註解在 R14／R15 各漂移過一次——R15 版還寫著 R15 自己判 HIGH 的舊寫法，R16）。這裡釘的是
    // 「前四行就是那四行」；行為由 xtrace 測試的各臂驅動（DEBUG trap、同名函式、假密鑰、偽造哨兵）。
    let codeText = codeLines.map(\.element).joined(separator: "\n")
    let firstFour = codeLines.prefix(4).map(\.element)
    #expect(firstFour.count == 4 && Array(firstFour[0...1]) == ["builtin trap - DEBUG ERR RETURN EXIT", "builtin set +x"] && firstFour[2].hasPrefix("LTM_MB_WHITELIST=\"") && firstFour[3] == "case \"${LTM_MB_CLEAN-}\" in", Comment(rawValue: "腳本的前四行程式碼必須是 trap 清除、builtin set +x、白名單變數、re-exec 的 case（R17：順序不能反，見腳本檔頭）：\(firstFour)"))
    // 白名單三邊互相釘住（R15：R14 版的白名單一行沒有任何東西釘；R16：寫端讀端共用同一個變數，讀端拒絕名單外的名字）：
    // (1) 第三行 `LTM_MB_WHITELIST="…"` 的名字、(2) 檔頭「白名單：」那段散文裡的名字、(3) `Sources/` 裡每一個 `environment["NAME"]`
    // 讀取點的名字——(1)==(2)，(3) ⊆ (1)，(1) − (3) 恰好是腳本自己用的五個（LC_ALL、LANG、TMPDIR、LTM_BIN、LTM_BASELINE_QUERIES）。
    // (3) 是單一拼法的 grep，所以另一條斷言釘住 Sources 裡不得出現別的讀法（`getenv(`、非字面鍵的 `environment[`）——R16：
    // 沒有那一條，「Sources 讀環境變數的每一個名字」只是一句比 regex 強的散文。
    let reexecLine = codeLines.map(\.element).first { $0.contains("builtin exec -c /usr/bin/env \"PATH=${PATH-}\" ${HOME+\"HOME=$HOME\"} \"LTM_MB_CLEAN=$$\" /bin/bash -- \"$0\" \"$@\" 3< <(builtin printf '%s\\0' \"LTM_MB_FD3=$$\"; for v in $LTM_MB_WHITELIST; do") && $0.hasSuffix("LTM_MB_END=1) || exit 70 ;;") } ?? ""
    let forList = (matches(#"^LTM_MB_WHITELIST=\"([A-Z0-9_ ]+)\"$"#, in: firstFour.count == 4 ? firstFour[2] : "").first ?? "").split(separator: " ").map(String.init)
    let whitelistProse = script.components(separatedBy: "#   白名單：").dropFirst().first?.components(separatedBy: "白名單裡的東西**原樣轉發**").first ?? ""
    let proseNames = whitelistProseNames(whitelistProse)
    var sourceNames = Set<String>()
    if let walker = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil) {
        for case let url as URL in walker where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) { sourceNames.formUnion(matches(#"environment\["([A-Z0-9_]+)"\]"#, in: text)) }
        }
    }
    #expect(!reexecLine.isEmpty && Set(forList).count == forList.count && forList.count >= 6, Comment(rawValue: "re-exec 行找不到（要帶頭標記、for 迴圈讀 $LTM_MB_WHITELIST、尾標記、|| exit 70）、或白名單變數空／重複：\(forList)"))
    var otherEnvReads: [String] = []
    if let walker = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil) {
        for case let url as URL in walker where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) { otherEnvReads += envReadViolations(in: text).map { url.lastPathComponent + ": " + $0 } }
        }
    }
    #expect(otherEnvReads.isEmpty, Comment(rawValue: "Sources 裡有 `environment[\"字面名\"]` 以外的環境變數讀法，白名單同步看不到它們：\(otherEnvReads)"))
    // `.gitattributes` 的 `-diff` 是規則 1 的機制面，之前零測試釘它（R16）：用 git 自己的屬性解析結果，不是解析檔案文字。
    // 這是套件裡唯一需要 git 本身的斷言：不在 checkout 裡或找不到 git 時會以錯的理由紅（R17），所以先確認兩個前提、否則**具名地紅**
    // （R24，codex：R23 版硬寫 `/usr/bin/git`，git 不在那個路徑的環境（Nix、部分 Linux）會以「沒有 git」紅而那個理由可以自動解掉——改走 `env`。
    // R25：R24 把**執行檔**與**閘**一起換掉了，而 `/usr/bin/env` 恆在——git 那一半被整個拿掉，PATH 上沒有 git 時 `env` 以 127 離開、
    // `attrLines` 是空的，紅在下面那條、訊息讀起來像「`-diff` 屬性壞了」，正是 R17 花一輪關掉的東西。現在閘自己跑 `env git --version`，
    // 並且把 `check-attr` 的離開碼一起判——離開碼不是 0 就具名地紅在環境那一側）。
    // （不是跳過——swift-testing 這裡沒用 skip 機制；紅的訊息說明是環境不是屬性。R17 的註解與 commit 寫「跳過」，R18 更正）。
    let checkAttr = Process()
    // 兩個 `Process` 都跑 `/usr/bin/env git` 且都不設 `.environment`，所以 `git` 由**環境 PATH** 解析。
    // R24→R25 刻意用這個換掉硬寫的 `/usr/bin/git`（Nix、非 FHS 佈局），理由記了、**後果沒記**——同一個檔案為
    // `python3` 寫過這種後果句（R26，security）。後果：跑測試的人 PATH 上的 `git` 決定這條斷言驗的是什麼。
    // 量過**不可從套件內利用**：`Tests/`／`Sources/` 沒有任何 `setenv`／`putenv`，本檔所有 PATH 操作都寫進交給
    // 單一 `Process` 的 per-child 字典，父行程環境從不被改，所以沒有測試能毒化並行的另一條測試。
    func gitResolves() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/env") else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["git", "--version"]
        // 這個子行程是**環境 PATH 上的 `git`**，輸出不受本 repo 控制——走共用的 `runDraining`（兩條 pipe 同時排空）。
        guard let r = try? runDraining(probe) else { return false }
        return r.status == 0
    }
    let gitAvailable = FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) && gitResolves()
    #expect(gitAvailable, "不在 git checkout 裡，或 PATH 上沒有可執行的 git：`.gitattributes` 的 -diff 屬性這一條沒有驗到（不是屬性錯了）")
    if gitAvailable {
    checkAttr.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    checkAttr.currentDirectoryURL = root
    checkAttr.arguments = ["git", "check-attr", "diff", "--", "scripts/baseline-queries.txt", "scripts/rrf-tie-queries.txt"]
    // 走共用的 `runDraining`（R26 版 stderr 從不讀、stdout 在 wait 之後才讀；R27 把三處收成一個 runner）。
    let attrRun = try runDraining(checkAttr)
    let attrLines = String(data: attrRun.stdout, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
    // 離開碼先判：非 0 代表 git 那邊出事，紅在**環境**那一側而不是屬性那一側（R25）。到得了這一行的成因**不含
    // 127**——`gitAvailable` 為真的前提就是同一條 PATH 上的 `env git --version` 剛以 0 離開（R26：R25 版的訊息
    // 具名 127，而那個成因在這一行不可達）；到得了的是「不是 git 倉庫」「pathspec 不合法」這一類。**無臂**：
    // 套件裡沒有任何世界讓 `check-attr` 非 0 離開。
    #expect(attrRun.status == 0, Comment(rawValue: "`env git check-attr` 以 \(attrRun.status) 離開——是環境（不是 git 倉庫、pathspec 不合法…），不是 `.gitattributes` 的屬性錯了"))
    #expect(attrLines == ["scripts/baseline-queries.txt: diff: unset", "scripts/rrf-tie-queries.txt: diff: unset"], Comment(rawValue: "git check-attr：\(attrLines)"))
    }
    #expect(Set(forList) == proseNames, Comment(rawValue: "白名單：for 清單 \(forList.sorted()) ≠ 檔頭散文 \(proseNames.sorted())"))
    #expect(!sourceNames.isEmpty && sourceNames.isSubset(of: Set(forList)), Comment(rawValue: "Sources 讀的環境變數沒全部轉發：缺 \(sourceNames.subtracting(forList).sorted())"))
    #expect(Set(forList).subtracting(sourceNames) == ["LC_ALL", "LANG", "TMPDIR", "LTM_BIN", "LTM_BASELINE_QUERIES"], Comment(rawValue: "白名單裡 Sources 沒讀的名字應恰好是腳本自己用的五個：\(Set(forList).subtracting(sourceNames).sorted())"))
    let procSubs = codeText.components(separatedBy: "< <(printf '%s' \"$QF_CONTENT\")").count - 1
    let qfRefs = try! NSRegularExpression(pattern: #"\$\{?QF\b"#).numberOfMatches(in: codeText, range: NSRange(location: 0, length: (codeText as NSString).length))
    let fileNameRefs = codeText.components(separatedBy: "baseline-queries.txt").count - 1
    let envNameRefs = codeText.components(separatedBy: "LTM_BASELINE_QUERIES").count - 1
    let hasHerestring = codeText.contains("<<<")
    #expect(procSubs == 3 && qfRefs == 7 && fileNameRefs == 1 && envNameRefs == 2 && !hasHerestring, Comment(rawValue: "查詢檔的三種拼法在程式碼行出現：識別碼 \(qfRefs)（應為 7）、檔名字面 \(fileNameRefs)（應為 1）、環境變數名 \(envNameRefs)（應為 2：白名單變數 1＋QF 賦值 1）——多一次就是多一條讀取路徑或訊息；process substitution \(procSubs) 處（應為 3：指紋、行數預數、量測迴圈——R18 為空集合指紋守衛加了預數）；herestring：\(hasHerestring)"))
    // 字元比對一律字面集合、不用 `[X-Y]` range——含字母的 range 在 bash 3.2 隨 locale 排序而變（指紋檢查的 fpUpper 臂驅動）；
    // 純數字 range 找不到反例（R14），這裡釘的是同檔一致寫法。pin 認任何 `[`、可選 `!`／`^`、英數、`-`、英數 的形式
    // （R13 版只認 `[0-9]`／`[!0-9]` 兩種拼法，`[^0-9]`、`[0-9a-f]` 穿得過，R14）。
    // pin 掃括號運算式（不含空白、逗號、引號——排除 `[ -f … ]` 與 python 的 list）裡**任一位置**的 `X-Y`（R14 版只認括號第一個位置，
    // `[abc0-9]` 穿過，R15）。
    let charRanges = matches(#"(\[[!^]?[^\]\s,"']*[0-9A-Za-z]-[0-9A-Za-z][^\]\s,"']*\])"#, in: codeText)
    #expect(charRanges.isEmpty, Comment(rawValue: "程式碼行裡有 \(charRanges.count) 處含 X-Y range 的括號運算式：\(charRanges)，要改成字面集合"))

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
    // set 行之後才判定的離開碼：程式碼裡 set 行（`printf 'set sha256:`）之後出現的 `exit N` 集合 ＝ 檔頭那句列的三個（R21：R20 加了兩條
    // set 行之後的 70，檔頭那句「只有 1 與 65、其餘 stdout 都是空的」沒改——消費端契約句，先前無人釘）。
    let setLineIndex = codeLines.firstIndex { $0.element.hasPrefix("printf 'set sha256:") } ?? codeLines.count
    // 切法對 `?? codeLines.count` 這個 fallback 必須安全：R23 把兩個切片各往外挪一格（讓 set 行自己的 `|| exit 70` 恰好算一次、
    // 落在「之前或當下」那側），而 `[(count + 1)...]` 與 `[...count]` 在 fallback 上**都越界**——pin 漂掉時整個測試行程 SIGTRAP、
    // 下面那個具名守衛不可達、同行程其他測試的結果一併消失（R24 四家共證；本檔 `classifyOutputLine` 的 group 註解
    // 自己寫著「group 數變了要紅不要 trap」。**引行號會爛、引符號不會**——R24 版在這裡寫了一個行號，而同一個 commit
    // 插進來的新測試把目標推走（R25）；R25 的修法自己又在別處寫了三個新行號，三個在落地當下就指錯（R26），
    // 所以這條規則現在一個行號都不帶：要指位置就指符號，或帶 commit）。
    let setSplit = min(setLineIndex + 1, codeLines.count)
    let afterSetText = codeLines[setSplit...].map(\.element).joined(separator: "\n")
    let afterSetExits = Set(matches(#"(?<![.\w])exit ([0-9]+)"#, in: afterSetText).compactMap { Int($0) })
    let afterSetSentence = "才判定的離開碼：" + afterSetExits.sorted().map(String.init).joined(separator: "、")
    #expect(setLineIndex < codeLines.count && afterSetExits == [1, 65, 70] && script.contains(afterSetSentence), Comment(rawValue: "set 行之後的 exit 集合 \(afterSetExits.sorted()) 與檔頭那句（要含「\(afterSetSentence)」）不一致"))
    // 反向：set 行之前的 `exit N` 集合（R22：R21 版那句「其餘 stdout 都是空的」的「其餘」含走到底的 0，而 0 不是字面 exit、pin 看不到）。
    let beforeSetText = codeLines[..<setSplit].map(\.element).joined(separator: "\n")   // set 行自己的 `|| exit 70` 算在「之前或當下」（R23）
    let beforeSetExits = Set(matches(#"(?<![.\w])exit ([0-9]+)"#, in: beforeSetText).compactMap { Int($0) })
    #expect(beforeSetExits == [64, 66, 69, 70] && script.contains("及之前的必須等於 " + beforeSetExits.sorted().map(String.init).joined(separator: "、")), Comment(rawValue: "set 行之前的 exit 集合 \(beforeSetExits.sorted()) 與檔頭那句不一致"))
    // README 手抄的每一個 camelCase 識別碼都要在這個測試檔或 Sources 裡出現（R21：R20 只釘了 #function 那一個；R22：R21 只掃一節、理由為假）。
    // 帶點的路徑（`toolUseResult.stdout`）regex 本來就不吃，不必截段。
    let testSource = try String(contentsOf: root.appendingPathComponent("Tests/LTMMCPTests/BaselineQueryFileTests.swift"), encoding: .utf8)
    let sourcesText = ((FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? [])
        .filter { $0.pathExtension == "swift" }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    // 掃全檔（R23：R22 版在「三條規則」截斷，而同一 commit 把 `maxQueryScalars` 寫進那一節之後）；jsonl 欄位名是封閉例外、不得類推。
    let jsonlFieldNames: Set<String> = ["isCompactSummary", "toolUseResult", "bashEditDiff"]   // R30：Bash 編輯的 unified diff 欄位（security 量到它帶 3 行 context）
    let readmeIdentifiers = Set(matches(#"`([a-z][a-z0-9]*[A-Z][A-Za-z0-9]*)`"#, in: readme)).subtracting(jsonlFieldNames)
    let orphanIdentifiers = readmeIdentifiers.filter { !testSource.contains($0) && !sourcesText.contains($0) }
    #expect(readmeIdentifiers.count >= 3 && orphanIdentifiers.isEmpty, Comment(rawValue: "README 的 camelCase 識別碼在測試檔與 Sources 都找不到：\(orphanIdentifiers.sorted())（掃到 \(readmeIdentifiers.count) 個）"))
    // README 的兩個節標題。R23 拓寬識別碼掃描時把唯一釘住它們的那條斷言一起刪掉、沒有替補——改名或刪節不會有任何地方紅
    // （R24，regression）。指標的實況（R25 更正 R24 寫的「三個指標」——那是宣稱自己完整的列舉而只有兩項成立）：
    //   前者：README 之外有**兩個**指標（CLAUDE.md 與 CHANGELOG）——**下面的 pin 現在直接釘它們**（R27：R26 版的 pin
    //   只檢查 README 自己，訊息卻寫「CLAUDE.md 與 CHANGELOG 指著前者」；那兩個外部指標沒被任何機制釘住）。
    //   後者：README 之外**零個**；釘它只為了順序。
    //   **查法**：把下面那兩個常數的值讀出來、**剝掉 `### ` 前綴**（外部指標寫的是裸短語），再搜 `*.md` 與 `*.sh`、
    //   只列檔名（`-rl`），扣掉 README 自己。R27：R26 版的查法沒說要剝前綴，逐字跑兩個標題都回「零個」——**連續第五輪**
    //   寫下沒跑過的查法，而這一條是上一輪錯查法的替代品。
    //   兩件事不要做：**(a) 不要把標題字面打進命令列**——它們各含一條受限 sister-set 查詢的子字串，而 `command=`
    //   是被索引的七個 metadata 欄位之一（R26，security）；把常數讀出來、在行程內比對即可。**(b) 不要用 `-rn`
    //   然後心算**：R25 版在這裡寫「`-rn` 會回五行」並列了項目，兩種讀法都不是 5（帶那組 `--include` 是 3，
    //   不帶是 6，而 `.swift` 貢獻三行不是兩行——註解、常數、和查法那一行自己），列舉還短一個。**括號裡的數字
    //   也是可查證的宣稱**，這是本輪抓到的第四條寫錯的查法，而前三條我在 commit message 裡記了「跑過才發現」。
    //   腳本對前者**零命中**：它「為什麼這麼小氣」那一段是自己複述了一份索引欄位表，不是指標——那份複述沒有同步檢查。
    let idxHeading = "### 什麼會進索引", useHeading = "### 查詢集在哪、怎麼用"
    let idxAt = readme.range(of: idxHeading), useAt = readme.range(of: useHeading)
    #expect(idxAt != nil && useAt != nil && idxAt!.lowerBound < useAt!.lowerBound,
            Comment(rawValue: "README 要有「\(idxHeading)」與「\(useHeading)」兩節且前者在前（後者只釘順序）"))
    // 外部指標：CLAUDE.md 與 CHANGELOG 各要有一句提到「什麼會進索引」這個裸短語（剝掉 `### `），否則改標題時兩個指標靜默漂掉（R27）。
    let idxPhrase = String(idxHeading.dropFirst("### ".count))
    let claudeMD = try String(contentsOf: root.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
    #expect(claudeMD.contains(idxPhrase) && changelog.contains(idxPhrase),
            Comment(rawValue: "CLAUDE.md 與 CHANGELOG 都要指著 README 的「\(idxPhrase)」那一節（改標題要三處一起改）"))
    // 自動內容約束：權威是 `contentConstraints`，同步檢查 (1)–(4) 在下面（它的說明寫了買到什麼、買不到什麼；R28：檢查的
    // 條數不再寫在任何註解裡——R27 版這裡寫三、清單說明寫四、README 寫三，三份兩份錯）。
    let constraintSentence = "自動內容約束是 \(contentConstraints.count) 項"
    // 測試檔那一份的範圍是 `maxQueryScalars` **自己的 doc comment**，不是全檔（R26：R25 版對 testSource 做全檔
    // `contains`，於是同檔任何一處寫了這句都能讓它綠——而本檔當時就另有一處寫著舊數字，那個自然的修法會讓
    // pin 保持綠、同時讓這句從它訊息宣稱的位置消失）。
    let capDecl = try #require(sourceLines.firstIndex { $0.hasPrefix("private let maxQueryScalars") }, "找不到 maxQueryScalars 的宣告行")
    let capDoc = sourceLines[..<capDecl].reversed().prefix { $0.hasPrefix("///") }.joined(separator: "\n")
    #expect(readme.contains(constraintSentence) && capDoc.contains(constraintSentence),
            Comment(rawValue: "README 與 maxQueryScalars 的 doc comment 都要寫「\(constraintSentence)」（`contentConstraints` 的項數）"))
    // (2) `QueryFileReport` 的每一個欄位都要被 `contentConstraints` 列到——多一個欄位而沒列 → 紅。
    let constraintOutlets = Set(contentConstraints.map(\.outlet))
    let unlistedFields = Mirror(reflecting: QueryFileReport()).children.compactMap(\.label).filter { !constraintOutlets.contains($0) }
    #expect(unlistedFields.isEmpty, Comment(rawValue: "QueryFileReport 的這些欄位不在 contentConstraints 裡：\(unlistedFields)"))
    // (3) `checkQueryFile` 本體裡 `throw` 後接的識別碼路徑集合 == 清單裡 `throw ` 項的集合，且本體裡沒有 `try`（R27，DA：
    // R26 版只用 `Mirror` 守欄位那一邊，`throw` 那一邊零檢查——加一條真的新 `throw` 約束不列進來，三條 pin 全綠。R28，
    // requirements／logic：R27 版的 regex 是 `throw Ident(`，`throw QE.tooBig`／`throw err`／`try helper()` 全漏、兩個空格也漏——
    // 現在 `throw` 後的任何 `[A-Za-z0-9_.]` 路徑都進集合，`throw err` 會以「err 不在清單」紅、`throw X.init()` 以「X.init」紅，
    // 方向是 fail-closed；`try` 傳播這條路以「本體不准有 `try`」關掉）。這是純文字掃描，不判可達（`if false { throw X() }` 一樣算）。
    // 兩個方向都要：多一個 throw 沒列 → 紅；清單列了一個本體裡沒有的 throw → 紅（R26 DA 那個「不存在的型別」變異）。
    // 對**整個本體連接後的文字**掃一次、不逐行（R29 requirements：R28 版逐行餵 regex，`\s+` 永遠碰不到換行，`throw` 換行接
    // 型別——`swiftc -typecheck` 確認合法——整條看不見，同步全綠而本體多一個未列出口）。臂：`throwScanIsDrivenByItsOwnFixture`。
    let checkBody = try #require(topLevelBodyLines(of: "checkQueryFile", in: sourceLines), "找不到 checkQueryFile 的唯一頂層宣告或其收尾 `}`")
    let thrownTypes = thrownIdentifierPaths(in: checkBody)
    let tryLines = checkBody.filter { !matches(#"(\btry\b)"#, in: $0).isEmpty }
    #expect(tryLines.isEmpty, Comment(rawValue: "checkQueryFile 本體裡不得有 `try`（錯誤傳播會繞過 throw 集合的同步）：\(tryLines.count) 行"))
    let listedThrows = Set(contentConstraints.map(\.outlet).filter { $0.hasPrefix("throw ") }.map { String($0.dropFirst("throw ".count)) })
    #expect(thrownTypes == listedThrows, Comment(rawValue: "checkQueryFile 本體裡的 throw 型別 \(thrownTypes.sorted()) ≠ contentConstraints 的 throw 項 \(listedThrows.sorted())"))
    // (4) 欄位型出口在 **smoke**（真檔測試）與 **driven**（fixture 測試）兩條的函式本體裡各要有一句對應形狀的斷言；`throw` 型
    // 只查 driven（真檔是 UTF-8，smoke 本來就不可能有；R28 DA 更正 R27 版的全稱「每個出口兩條各一句」）。needle 從 outlet
    // 導出（R26；R27 把「指名一條測試」改成「兩條各有角色」——R26 版指名的真檔測試依建構恆綠，神經化一條約束只有 fixture
    // 測試會紅）。這條檢查買到的是「兩處都**提到**了這個出口」；「那句 driven 斷言真的會紅」沒有靜態檢查能證明，見清單
    // 說明的「買不到什麼」。driven 行的形狀（R28 收窄，各自變異過）：以 `#expect(` 開頭、含 `report(`、含 `).<欄位>`，
    // 且不在 `withKnownIssue` 區塊裡——R27 版只要 `#expect(` ＋ `).<欄位>`，DA 用無關的 `.count` 與包進 `withKnownIssue`
    // 兩個構造各自穿過。`expectOnly` 與 `report(` 的負向臂在 `drivenNeedleShapeIsDrivenByItsOwnFixture`。
    // 判定本體抽成 `unassertedOutlets(_:smokeBody:drivenBody:)`，讓生產路徑可以餵合成本體（R29 regression：R28 版只有 helper
    // `outsideKnownIssueBlocks` 有臂，生產路徑那一行換回 `drivenBody` 五條測試全綠——CLAUDE.md 記過的「回歸鎖全測在 helper 上」）。
    let smokeBody = try #require(topLevelBodyLines(of: realFileTestName, in: sourceLines, requireTest: true), "找不到 \(realFileTestName) 的唯一頂層 `@Test` 宣告或其收尾 `}`")
    let drivenBody = try #require(topLevelBodyLines(of: fixtureTestName, in: sourceLines, requireTest: true), "找不到 \(fixtureTestName) 的唯一頂層 `@Test` 宣告或其收尾 `}`")
    // 剔掉 `withKnownIssue` 之後兩個本體都不該是空的——空表示某個 wrapper 的 `{` 沒閉合（pending 吞掉其後全部），
    // 而那會讓下一條斷言對**每個**出口都報缺、看不出成因（R30 logic）。
    // **無臂**（R30 實測：換成恆真，六條測試全綠）——這是診斷用的，真本體裡沒有未閉合的 wrapper，fixture 也驅動不到
    // 這條讀真原始碼的斷言；`outsideKnownIssueBlocks` 對「pending 未閉合 → 全吞」本身有臂。
    #expect(!outsideKnownIssueBlocks(drivenBody).isEmpty && !outsideKnownIssueBlocks(smokeBody).isEmpty,
            "剔掉 withKnownIssue 之後 smoke 或 driven 本體為空——多半是某個 wrapper 的 `{` 被行尾 `//` 或 `/* */` 吃掉、pending 未閉合")
    // 真檔測試餵給 `checkQueryFile` 的兩個來源要釘住：只有 fixture 臂的話，把 `∪ retired`（或 `historicalQueryFolds`）從呼叫點
    // 整段拿掉零測試紅，而 README／CHANGELOG／清單三處都把這條接線寫成事實（R30 regression；R29 #8 的同一個形狀）。
    let wiring = ["historicalQueryFolds(", "union(retired.map(foldLikeJudge))"].filter { needle in !smokeBody.contains { $0.contains(needle) } }
    #expect(wiring.isEmpty, Comment(rawValue: "真檔測試本體要同時餵 git 可達歷史與退役清單，缺：\(wiring)"))
    let unassertedOutlets = unassertedOutlets(contentConstraints, smokeBody: smokeBody, drivenBody: drivenBody)
    #expect(unassertedOutlets.isEmpty, Comment(rawValue: "contentConstraints 的這些出口缺 smoke（真檔測試 `#expect(r.X`）或 driven（fixture 測試 `#expect(… ).X …`）斷言：\(unassertedOutlets)"))
    // 帶 `|| exit 70` 的 printf 只有兩個：檔頭那句與它的兩個數由這裡釘（R25，DA：R24 的查法數的是「用 `/bin/echo` 印訊息的
    // printf」這個別的集合，插第三個帶守衛的 printf 之後它仍回 2；而且當時沒有任何測試釘這個數）。行首錨點與查法一致。
    // 重用上方的 `codeLines`，不再有第二份定義（R27：R26 版寫了逐字相同的第二份再互相比對——那條斷言結構上驅動不了、
    // 退掉零測試紅，正是本 repo 反覆拆掉的形狀）。
    let scriptCodeLines = codeLines.map(\.element)
    let guardedPrintfLines = scriptCodeLines.filter { $0.trimmingCharacters(in: asciiWhitespace).hasPrefix("printf ") && $0.contains("||") && $0.contains("exit 70") }
    // 第二個數是**出現次數**不是行數（R26：re-exec 那一行上有三個 `builtin printf`，R25 版用 `grep -c` 數行 → 6，
    // 於是檔頭那一段的算術不閉合）。
    // 對 UTF-8 bytes 數、不對 String 數（R27，logic：`components(separatedBy:)` 走正則等價，`printf` 後面緊跟一個結合字元時
    // Swift 數不到而 `grep -o` 數得到——檔頭的查法是 grep，兩邊要同語意）。
    let printfOccurrences = byteOccurrences(of: "printf", in: scriptCodeLines)   // 臂：`byteOccurrencesIsDrivenByItsOwnFixture`（R28 regression：R27 版無臂）
    #expect(guardedPrintfLines.count == 2, Comment(rawValue: "帶 `|| exit 70` 的 printf 行應恰好兩個（set 行、每一列），得 \(guardedPrintfLines.count)"))
    #expect(script.contains("exit 70'` → \(guardedPrintfLines.count)") && script.contains("grep -o printf | wc -l` → \(printfOccurrences)"),
            Comment(rawValue: "檔頭那兩個數要與實況相同：帶守衛的行數 \(guardedPrintfLines.count)、printf 出現次數 \(printfOccurrences)"))
    // CHANGELOG 指名「檔頭第 4 點」：那一點的首句要真的是 re-exec（R23：指標沒有會變紅的檢查）。
    #expect(changelog.contains("以檔頭第 4 點為準") && script.contains("\n#   4. `builtin exec -c /usr/bin/env"), "CHANGELOG 指的「檔頭第 4 點」不是 re-exec 那一點")
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
    // 威脅模型的邊界句只有腳本檔頭一份，README 與 CHANGELOG 只留指標（R18：R17 只改了三份複本中的一份，另外兩份還在說被檔頭自己
    // 退回的「第一行之前」「只有 BASH_ENV」，而且 README 把「已 export 的函式」列在擋得住那一側）。這裡釘的是**退回過的拼法不得再出現**——
    // 負向 pin 是拼法列舉，抓得到複述、抓不到改寫；改寫由 verify 的讀者扛。
    for stale in ["在腳本第一行之前", "第一行之前就能", "只有 `BASH_ENV`", "第四行 `exec`", "不在擋不住之列"] {
        #expect(!readme.contains(stale) && !changelog.contains(stale), Comment(rawValue: "README／CHANGELOG 又出現被檔頭退回的邊界句拼法：\(stale)"))
    }
    // 空集合指紋守衛用的字面（sha256 of nothing 的前 12 個 hex）與測試自己算的一致（R18）。
    #expect(script.contains(" != e3b0c44298fc ]") && setFingerprint("") == "set sha256:e3b0c44298fc", "腳本的空集合指紋字面與 sha256(\"\") 前 12 hex 不一致")
    // 字面 token 的形狀（純小寫字母）由上方抽輸出點的 regex `^[a-z]+$` 釘住；R19 另寫的一條形狀 pin 被它與 `runtimeLiterals == expectedLiterals`
    // 完全支配、沒有變異能讓它單獨紅，R20 拆掉。
    // README 手抄了這條測試的函式名，釘住它（R20：改名時 README 對不上而無人發現）。
    #expect(readme.contains(String(#function.prefix { $0 != "(" })), "README 指名的測試函式名與本函式名不一致")
    // README 手抄的「檔頭 N 個必備短語」要等於 requiredHeaderPhrases 的個數（R19：R18 版把「四項」換成「六個」，另一個無人釘的數字）。
    #expect(readme.contains("檔頭 \(requiredHeaderPhrases.count) 個必備短語"), "README 寫的必備短語個數與 requiredHeaderPhrases.count 不一致")
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
/// Sources 裡「白名單同步看不到」的環境變數讀法：`getenv(`（容許空白）與 `environment[` 後面不是 `"大寫字面鍵"]` 的每一處
/// （內插鍵、小寫字面、變數鍵、空白都算；R17：R16 版只擋「第一個字元不是引號」）。改名綁定（`let env = …environment; env["X"]`）
/// 與 `getenv` 之外的 wrapper 仍看不到——這是拼法守衛，README 也這樣寫。抽成函式是為了讓下面的負向 fixture 驅動它
/// （R18：R17 加寬 regex 時真 Sources 裡沒有反例，退回 R16 形式全綠——三處無臂的測試側改動之二）。
private func envReadViolations(in text: String) -> [String] {
    var out: [String] = []
    if text.range(of: #"getenv\s*\("#, options: .regularExpression) != nil { out.append("getenv(") }
    out += matches(#"(environment\s*\[(?!"[A-Z][A-Z0-9_]*"\])[^\]]*\])"#, in: text)
    return out
}

@Test("envReadViolations：大寫字面鍵乾淨；內插鍵、小寫字面、變數鍵、`environment [`、`getenv (` 都紅（R18：R17 的 regex 加寬無臂）")
func envReadViolationsFixture() {
    #expect(envReadViolations(in: #"let a = env.environment["LTM_BIN"]; let b = environment["X_1"]"#).isEmpty)
    #expect(envReadViolations(in: #"environment["lowerkey"]"#).count == 1)
    #expect(envReadViolations(in: #"environment["LTM_\(x)"]"#).count == 1)      // R16 版的 regex 看不到（第一個字元是引號）
    #expect(envReadViolations(in: #"environment[key]"#).count == 1)
    #expect(envReadViolations(in: #"environment [ "LTM_BIN" ]"#).count == 1)
    #expect(envReadViolations(in: #"getenv ("X")"#) == ["getenv("])                // R16 版是字面 `getenv(`，帶空白穿得過
}

/// 檔頭「白名單：」段散文裡的名字：三個字元以上的大寫識別碼，扣掉輪次編號（`R14`…`R999`）與尾端 `_` 的殘片。
/// R16 版用 `hasPrefix("R1")` 是編號列舉，R20 起會以無關理由紅（R17）；那次加寬在真檔頭裡沒有反例可驅動，所以這裡給 fixture（R18）。
private func whitelistProseNames(_ prose: String) -> Set<String> {
    Set(matches(#"\b([A-Z][A-Z0-9_]{2,})\b"#, in: prose).filter { $0.range(of: #"^R[0-9]+$"#, options: .regularExpression) == nil && !$0.hasSuffix("_") })
}

@Test("whitelistProseNames：名字留下、R14 與 R20 都不是名字、兩個字元的大寫不算")
func whitelistProseNamesFixture() {
    #expect(whitelistProseNames("HOME、LC_ALL（R14 漏了，R20 補）與 AB 及 LTM_") == ["HOME", "LC_ALL"])
}

private func checkProducerLines(_ lines: [(line: Int, text: String)], marker: String) -> ProducerReport {
    var r = ProducerReport()
    var sides: [String] = []
    for (n, line) in lines {
        guard let m = line.range(of: marker) else { r.unsplittable.append(n); continue }
        // 整行被 `//` 註解掉的 producer 行不是活斷言（R17，codex：R10 拆掉「以 #expect( 開頭」的合取時沒補「不是註解」，註解掉的產生點會被當成活的）。
        // 這是拼法守衛：`/* … */` 區塊與 `#if false` 裡的產生點看不到（R18）——那兩種拼法在這個檔裡不用，同步測試不掃它們。
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { r.unsplittable.append(n); continue }
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
    #expect(checkProducerLines([(line: 9, text: "    // #expect(x == \"error(judge)\") \(mk) judge")], marker: mk).unsplittable == [9])  // 整行註解掉的產生點也紅（R17）
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

/// driven needle 的行過濾：`expectOnly` 要求該行以 `#expect(` 開頭且含識別碼 `report(`（R28：R27 版只有前者，無關的 `.count` 也能滿足
/// `).count`；R29 logic：`report(` 補左邊界——`subreport(`／`xreport(` 不算——與 needle 右邊界對稱），needle 的每一個出現位置都試、
/// 右邊界不得接識別碼字元（R29：R28 版只看第一個出現，`).countX == 0 || …).count == 2` 整行回 false）。
/// **副作用（R29 regression／requirements）**：driven 臂被綁在本地 helper `report` 這個名字上——直接呼叫 `checkQueryFile(`、跨行的
/// `#expect(\n …)`、`try #require(…)` 都會被報成「driven 缺」（fail-closed，但訊息指錯原因）；而 `report(` 出現在字串字面裡就算數。
private func hasNeedle(_ body: [String], _ needle: String, expectOnly: Bool) -> Bool {
    body.contains { line in
        if expectOnly {
            let t = line.trimmingCharacters(in: asciiWhitespace)
            if !t.hasPrefix("#expect(") || !hasIdentifierBounded(t, "report(") { return false }
        }
        return hasIdentifierBounded(line, needle)
    }
}

/// `needle` 出現在 `line` 裡，且 needle 以識別碼字元開頭／結尾的那一側不接識別碼字元（`_`、字母、數字）——`report(` 只查左邊、
/// `).count` 只查右邊、`#expect(throws: X.self)` 兩邊都不查。逐一檢查每個出現位置。
private func hasIdentifierBounded(_ line: String, _ needle: String) -> Bool {
    guard let first = needle.first, let last = needle.last else { return false }
    var from = line.startIndex
    while let hit = line.range(of: needle, range: from..<line.endIndex) {
        let leftOK = !isIdentifierChar(first) || hit.lowerBound == line.startIndex || !isIdentifierChar(line[line.index(before: hit.lowerBound)])
        let rightOK = !isIdentifierChar(last) || hit.upperBound == line.endIndex || !isIdentifierChar(line[hit.upperBound])
        if leftOK && rightOK { return true }
        from = line.index(after: hit.lowerBound)
    }
    return false
}
private func isIdentifierChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

/// 剔掉 `withKnownIssue` 區塊裡的行。掃描從**那一行的 `withKnownIssue` token 之後**開始（R30 requirements／logic：R29 版數整行的
/// 大括號，於是 `}; withKnownIssue("m") {` 這種行 delta == 0 被判成「同行閉合」，區塊本體漏出），本體的 `{` 是 token 之後**小括號
/// 深度回到 0** 的第一個（R30 logic／DA：R29 版在 pending 期間見到任何 `{` 就解除，多行 wrapper 的引數行含一個同行閉合的閉包
/// ——`Comment(rawValue: xs.map { $0 }.joined())`，本檔既有慣用法——就讓 pending 提早解除、`) {` 與整個本體落回 driven）。
/// 大括號與 token 都在**剝掉字串字面之後**的文字上找（R29 security／logic：訊息裡一個 `}` 會讓深度提早收平；R30：字面裡的
/// `withKnownIssue` 因此不會被當成區塊開頭——R29 的 doc 把這個方向寫反了），深度夾在 0 以上（R29 logic）。
///
/// **射程**：它只認**出現在被掃本體裡**的 `withKnownIssue` token。把 wrapper 搬到本體外（`private func knownGap(_ body: () throws -> Void)`
/// 裡呼叫 `withKnownIssue`，本體寫 `knownGap { … }`）不在射程內——那條臂執行期仍被記成 known issue 而掃描看不見（R30 DA；列在
/// `contentConstraints` 說明「買不到什麼」第 6 條）。`/* withKnownIssue */` 區塊註解會進 pending（`topLevelBodyLines` 只剝行尾 `//`），
/// 方向 fail-closed；pending 到本體結束都沒閉合時其後每一行都被吞掉，同步測試因此對每個出口都報缺——`verdictAlphabetIsStatedIdenticallyEverywhere`
/// 另有一條具名斷言指出這個成因（R30 logic）。
private func outsideKnownIssueBlocks(_ body: [String]) -> [String] {
    var depth = 0, pending = false, parens = 0, out: [String] = []
    /// 掃一段文字，更新 (pending, parens, depth)。pending 期間只找本體的 `{`；進入本體之後純數大括號。
    func scan(_ text: Substring) {
        for c in text {
            if pending {
                if c == "(" { parens += 1 }
                else if c == ")" { parens = max(0, parens - 1) }
                else if c == "{", parens == 0 { pending = false; depth = 1 }
                continue
            }
            if c == "{" { depth += 1 } else if c == "}" { depth = max(0, depth - 1) }
        }
    }
    for line in body {
        let code = stripStringLiterals(line)
        if depth == 0, !pending {
            guard let hit = code.range(of: "withKnownIssue") else { out.append(line); continue }
            pending = true; parens = 0
            scan(code[hit.upperBound...])
            continue
        }
        scan(Substring(code))
    }
    return out
}

/// 把一行裡的字串字面（含插值與插值裡的巢狀字串）整段換成 `""`。給 `outsideKnownIssueBlocks` 數大括號用：字面與插值裡的
/// 大括號都不是本體的界線（插值裡的程式碼必然自成平衡），所以整段丟掉是對的。
///
/// **性質**：只認 `"…"` 與 `\"` 逃脫，並在 `\(` 之後以小括號深度追蹤插值、插值裡再遇到 `"` 就再開一層（R30 logic：R29 版只認
/// `\"`，`"\(flag ? "}" : "")"` 會讓狀態翻轉、字面的 `}` 被當程式碼數進 delta，區塊提早收平、其後的臂漏出——fail-open）。
/// **不認**：多行字串 `"""`、raw string `#"…"#`（`\"#` 會被當逃脫、整行其餘被吞，方向 fail-closed）、字元字面。三者本檔的
/// driven 本體都沒有（查法：對 `topLevelBodyLines(of: fixtureTestName…)` 的結果 grep `\"\"\"`／`#\"` → 0）。
private func stripStringLiterals(_ line: String) -> String {
    enum Mode { case string, interpolation(Int) }
    var out = "", stack: [Mode] = [], escaped = false
    for c in line {
        guard let top = stack.last else {                     // 程式碼
            if c == "\"" { stack.append(.string); out.append("\"\"") } else { out.append(c) }
            continue
        }
        switch top {
        case .string:
            if escaped { if c == "(" { stack.append(.interpolation(1)) }; escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { stack.removeLast() }
        case .interpolation(let n):
            if c == "(" { stack[stack.count - 1] = .interpolation(n + 1) }
            else if c == ")" { if n == 1 { stack.removeLast() } else { stack[stack.count - 1] = .interpolation(n - 1) } }
            else if c == "\"" { stack.append(.string) }
        }
    }
    return out
}

/// 對 UTF-8 bytes 數子字串出現次數（不重疊、由左而右）——與 `grep -o` 同語意（R27 logic：`components(separatedBy:)` 走
/// 正則等價，`printf` 後面緊跟結合字元時 Swift 數不到而 grep 數得到）。
private func byteOccurrences(of needle: String, in lines: [String]) -> Int {
    let n = Array(needle.utf8)
    guard !n.isEmpty else { return 0 }   // 空針：`i += 0` 會是無窮迴圈（R29 logic）
    return lines.reduce(0) { acc, line in
        let b = Array(line.utf8)
        var i = 0, hits = 0
        while i + n.count <= b.count {
            if Array(b[i..<(i + n.count)]) == n { hits += 1; i += n.count } else { i += 1 }
        }
        return acc + hits
    }
}

@Test("driven needle 的行過濾由 fixture 驅動：非 #expect 行、無 report( 的 #expect 行、withKnownIssue 區塊裡的行都不算；識別碼右邊界")
func drivenNeedleShapeIsDrivenByItsOwnFixture() {
    #expect(hasNeedle(["#expect(try report(\"\").count == 0)"], ").count", expectOnly: true))
    #expect(!hasNeedle(["let x = try report(\"\").count"], ").count", expectOnly: true))                       // 不是 #expect 行
    #expect(!hasNeedle(["#expect(requiredHeaderPhrases.joined(separator: \" \").count > 0)"], ").count", expectOnly: true))   // 無 report(（R28 DA 構造）
    #expect(hasNeedle(["let x = report(\"\").count"], ").count", expectOnly: false))                          // smoke 側不過濾行形
    #expect(!hasNeedle(["#expect(try report(\"\").countX == 0)"], ").count", expectOnly: true))              // 右邊界接識別碼字元
    let body = ["#expect(try report(\"\").tooLong == [1])",
                "withKnownIssue(\"m\") {",
                "    #expect(try report(\"\").duplicateCount == 1)",
                "}",
                "#expect(try report(\"\").count == 2)"]
    #expect(outsideKnownIssueBlocks(body) == [body[0], body[4]])
    #expect(outsideKnownIssueBlocks(["withKnownIssue(\"m\") { #expect(try report(\"\").count == 2) }", "#expect(x)"]) == ["#expect(x)"])   // 單行閉合
    #expect(!hasNeedle(outsideKnownIssueBlocks(body), ").duplicateCount", expectOnly: true))   // R28 DA 構造：包進 withKnownIssue 的 driven 臂不算
    // R29：多行 wrapper（logic／requirements 配對變異）、訊息含大括號（security）、多閉一層後的下一個區塊（logic）
    let multi = ["withKnownIssue(", "    \"m\"", ") {", "    #expect(try report(\"\").tooLong == [1])", "}", "#expect(after)"]
    #expect(outsideKnownIssueBlocks(multi) == ["#expect(after)"])
    let braceInMessage = ["withKnownIssue(\"訊息含 } 括號\") {", "    #expect(try report(\"\").tooLong == [1])", "}", "#expect(after)"]
    #expect(outsideKnownIssueBlocks(braceInMessage) == ["#expect(after)"])
    let literalCloseInside = ["withKnownIssue(\"m\") {", "    #expect(try report(\"a}b\").tooLong == [1])", "    #expect(try report(\"\").duplicateCount == 1)", "}"]
    #expect(outsideKnownIssueBlocks(literalCloseInside).isEmpty)
    let overClosed = ["withKnownIssue(\"m\") { if true {", "    #expect(a)", "} } }", "withKnownIssue(\"n\") {", "    #expect(try report(\"\").tooLong == [1])", "}"]
    #expect(outsideKnownIssueBlocks(overClosed).isEmpty)
    #expect(stripStringLiterals("#expect(x == \"{\", \"a\\\"}b\")") == "#expect(x == \"\", \"\")")
    // R30：wrapper 多行**且**引數行含同行閉合的閉包（本檔既有的訊息組裝慣用法）——R29 版在那一行解除 pending，本體整段漏出
    let closureInArgs = ["withKnownIssue(", "    Comment(rawValue: [\"m\"].map { $0 }.joined())", ") {", "    #expect(try report(\"\").tooLong == [1])", "}", "#expect(after)"]
    #expect(outsideKnownIssueBlocks(closureInArgs) == ["#expect(after)"])
    // R30：外層的 `{` 排在同一行、且**比 wrapper 晚收**——掃描要從 token 之後開始，否則外層那個 `{` 先解除 pending，
    // wrapper 的 `}` 之後仍留在深度 1，後面的臂被多吞掉（fail-closed，會誤報「driven 缺」）
    let outerOnSameLine = ["if x { withKnownIssue(\"m\") {", "    #expect(try report(\"\").tooLong == [1])", "}", "    #expect(try report(\"\").duplicateCount == 1)", "}", "#expect(after)"]
    #expect(outsideKnownIssueBlocks(outerOnSameLine) == ["    #expect(try report(\"\").duplicateCount == 1)", "}", "#expect(after)"])
    // R30：`withKnownIssue` 之前有一個屬於**未追蹤外層**的 `}`——R29 版數整行 delta == 0，判成「同行閉合」
    let precedingClose = ["if x {", "    foo()", "} ; withKnownIssue(\"m\") {", "    #expect(try report(\"\").tooLong == [1])", "}", "#expect(after)"]
    #expect(outsideKnownIssueBlocks(precedingClose) == ["if x {", "    foo()", "#expect(after)"])
    // R30：插值裡的巢狀引號包著一個字面 `}`——R29 版的狀態機在 `\(` 之後翻轉，把它當程式碼數進 delta、區塊提早收平
    let interpolatedBrace = ["withKnownIssue(\"m\") {", "    #expect(try report(\"\\(flag ? \"}\" : \"\")\").count == 2)", "    #expect(try report(\"\").duplicateCount == 1)", "}", "#expect(after)"]
    #expect(outsideKnownIssueBlocks(interpolatedBrace) == ["#expect(after)"])
    #expect(stripStringLiterals("f(\"\\(g(\"}\"))\") {") == "f(\"\") {")
    // R30：字串字面裡的 `withKnownIssue` **不會**開區塊（R29 的 doc 把方向寫反了）
    #expect(outsideKnownIssueBlocks(["#expect(x, \"withKnownIssue {\")", "#expect(after)"]) == ["#expect(x, \"withKnownIssue {\")", "#expect(after)"])
    // R30：pending 到本體結束都沒閉合（`{` 被行尾 `//` 吃掉）→ 其後全吞（fail-closed）；同步測試對這個成因另有具名斷言
    #expect(outsideKnownIssueBlocks(["withKnownIssue(\"m\")   // {", "#expect(after)"]).isEmpty)
    // hasNeedle 左邊界與多重出現（R29 logic）
    #expect(!hasNeedle(["#expect(subreport(\"\").count == 0)"], ").count", expectOnly: true))                  // `report(` 要有左邊界
    #expect(hasNeedle(["#expect(try report(\"\").countX == 0 || report(\"\").count == 2)"], ").count", expectOnly: true))   // 第二個出現位置才乾淨
}

@Test("printf 出現次數對 UTF-8 bytes 數：緊跟結合字元、相鄰重複都與 grep -o 同數")
func byteOccurrencesIsDrivenByItsOwnFixture() {
    #expect(byteOccurrences(of: "printf", in: ["printf\u{0301} printf"]) == 2)   // components(separatedBy:) 在這行回 1（正則等價）
    #expect(byteOccurrences(of: "printf", in: ["printfprintf", "x"]) == 2)
    #expect(byteOccurrences(of: "printf", in: ["print"]) == 0)
    #expect(byteOccurrences(of: "aa", in: ["aaa"]) == 1)   // 不重疊，與 `grep -o aa` 同數
    #expect(byteOccurrences(of: "", in: ["abc"]) == 0)     // 空針不是無窮迴圈（R29 logic）
}

/// 同步檢查 (4) 的判定本體。欄位型出口：smoke 在真檔測試本體找 `#expect(r.<欄位>`；driven 在 fixture 測試本體找 `).<欄位>`
/// （`expectOnly`）。`throw` 型只有 driven，needle 是 `#expect(throws: X.self)`。**兩個本體、兩種出口都先剔掉 `withKnownIssue`
/// 區塊**（R28 DA：driven 臂包進 `withKnownIssue` 就永遠不紅；R29 DA：R28 版只在欄位分支剔，`throw` 分支餵原始本體；R30 DA：
/// R29 版兩個分支都剔了 driven，**smoke 本體沒剔**——把真檔測試的 `#expect(r.X…)` 包進 `withKnownIssue`，違規的查詢檔會讓真檔
/// 測試 `passed with known issue`、`swift test` exit 0，而真檔測試正是讓違規檔在 CI 變紅的那一道閘。三輪都是同一個形狀：
/// **數出口的時候要連本體一起數**）。臂：`unassertedOutletsIsDrivenByItsOwnFixture`。
private func unassertedOutlets(_ constraints: [(name: String, outlet: String)], smokeBody: [String], drivenBody: [String]) -> [String] {
    let drivenOutside = outsideKnownIssueBlocks(drivenBody)
    let smokeOutside = outsideKnownIssueBlocks(smokeBody)
    return constraints.compactMap { c -> String? in
        if c.outlet.hasPrefix("throw ") {
            let needle = "#expect(throws: \(c.outlet.dropFirst("throw ".count)).self)"
            return hasNeedle(drivenOutside, needle, expectOnly: true) ? nil : "\(c.outlet)（driven 缺）"
        }
        let smoke = hasNeedle(smokeOutside, "#expect(r.\(c.outlet)", expectOnly: false)
        let driven = hasNeedle(drivenOutside, ").\(c.outlet)", expectOnly: true)
        return (smoke && driven) ? nil : "\(c.outlet)（\(smoke ? "" : "smoke 缺")\(!smoke && !driven ? "、" : "")\(driven ? "" : "driven 缺")）"
    }
}

/// `throw` 後接的識別碼路徑集合，對整個本體連接後掃（`\s+` 因此跨行；R29 requirements）。
private func thrownIdentifierPaths(in body: [String]) -> Set<String> {
    Set(matches(#"\bthrow\s+([A-Za-z_][A-Za-z0-9_.]*)"#, in: body.joined(separator: "\n")))
}

@Test("同步檢查 (4) 的判定由合成本體驅動：欄位型 smoke／driven 各缺、throw 型 driven 缺、driven 臂在 withKnownIssue 裡不算（欄位與 throw 兩個分支都是）、全齊 → 空")
func unassertedOutletsIsDrivenByItsOwnFixture() {
    let cs: [(name: String, outlet: String)] = [("a", "count"), ("b", "throw NotUTF8")]
    let smoke = ["#expect(r.count >= 6)"]
    let driven = ["#expect(try report(\"\").count == 2)", "#expect(throws: NotUTF8.self) { try report(bytes: Data()) }"]
    #expect(unassertedOutlets(cs, smokeBody: smoke, drivenBody: driven).isEmpty)
    #expect(unassertedOutlets(cs, smokeBody: [], drivenBody: driven) == ["count（smoke 缺）"])
    #expect(unassertedOutlets(cs, smokeBody: smoke, drivenBody: [driven[1]]) == ["count（driven 缺）"])
    #expect(unassertedOutlets(cs, smokeBody: smoke, drivenBody: [driven[0]]) == ["throw NotUTF8（driven 缺）"])
    #expect(unassertedOutlets(cs, smokeBody: [], drivenBody: []) == ["count（smoke 缺、driven 缺）", "throw NotUTF8（driven 缺）"])
    let wrapped = ["withKnownIssue(\"m\") {", "    " + driven[0], "    " + driven[1], "}"]
    #expect(unassertedOutlets(cs, smokeBody: smoke, drivenBody: wrapped) == ["count（driven 缺）", "throw NotUTF8（driven 缺）"])   // R28／R29 DA 構造：兩個分支都要剔
    let wrappedSmoke = ["withKnownIssue(\"m\") {", "    " + smoke[0], "}"]
    #expect(unassertedOutlets(cs, smokeBody: wrappedSmoke, drivenBody: driven) == ["count（smoke 缺）"])   // R30 DA 構造：smoke 本體也要剔
    let wrappedMultiline = ["withKnownIssue(", "    \"m\"", ") {", "    " + driven[0], "}", driven[1]]
    #expect(unassertedOutlets(cs, smokeBody: smoke, drivenBody: wrappedMultiline) == ["count（driven 缺）"])   // R29 logic 構造：多行 wrapper
    #expect(unassertedOutlets(cs, smokeBody: smoke, drivenBody: ["let x = try report(\"\").count", driven[1]]) == ["count（driven 缺）"])   // 非 #expect 行不算（生產路徑上的 expectOnly）
}

@Test("throw 掃描由合成本體驅動：同行、換行接型別、點路徑、裸變數、兩個空格；throws 子句不算")
func throwScanIsDrivenByItsOwnFixture() {
    #expect(thrownIdentifierPaths(in: ["    throw NotUTF8()"]) == ["NotUTF8"])
    #expect(thrownIdentifierPaths(in: ["    throw", "        GitFailed(subcommand: \"x\", status: 1)"]) == ["GitFailed"])   // R29 requirements 構造
    #expect(thrownIdentifierPaths(in: ["throw QE.big", "throw err", "throw  Spaced()", "throw X.init()"]) == ["QE.big", "err", "Spaced", "X.init"])
    #expect(thrownIdentifierPaths(in: ["func f() throws(MyErr) -> Int {", "let throwsX = 1"]).isEmpty)
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
    /// 實體行切分：`components(separatedBy:)` 保留空行（R23，codex：`split` 會靜默丟掉空白行，多印空行的退化看不見）；
    /// 丟掉的只有「正常結尾」造成的那一個尾端空元素——這是**正規化，不是約束**：stdout 沒有以換行收尾時，截斷的殘行會被當成完整的一列，
    /// 這裡不檢查也不拒絕（R24 更正 R23 的「只容許…」，那句讀起來像一條會執行的約束）。臂：`physicalLinesKeepsBlankLines`。
    var physicalLines: [String] { let l = stdout.components(separatedBy: "\n"); return l.last == "" ? Array(l.dropLast()) : l }
    var setLine: String { physicalLines.first ?? "" }
    var rows: [String] { Array(physicalLines.dropFirst()) }
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
                       scriptOverride: URL? = nil, bashOperand: String? = nil, cwd: URL? = nil, extraArgs: [String] = [],
                       sentinelForged: Bool = false, forgedFd3Records: String? = nil, forgedFd3Writer: String? = nil) throws -> ScriptRun {
    let script = scriptOverride ?? repoRoot().appendingPathComponent("scripts/measure-baseline.sh")
    let process = Process()
    if sentinelForged {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")   // `bash -c '單一命令'` 不 fork：那個 shell 的 $$ 就是腳本的 PID（R16）
        // forgedFd3Records：偽造者連 fd 3 也自備——printf 格式，`%s` 是 $$（頭標記要對得上），記錄以 `\\0` 分隔。
        // forgedFd3Writer：整段 bash 當 process substitution 的本體（停住不寫、一直寫……由呼叫端組；`$$` 在那個子 shell 裡就是腳本的 PID）。
        // 長命的寫端要先關掉繼承的 stdio，否則測試端的 readDataToEndOfFile 會等到它結束（R17）；停住的寫端用 `kill -0 $$` 輪詢、腳本一走就退
        // （R18：R17 版 `sleep 120` 每跑一臂留一對 bash＋sleep 孤兒行程約兩分鐘）。
        let fd3 = forgedFd3Writer.map { " 3< <(\($0))" } ?? (forgedFd3Records.map { " 3< <(printf '\($0)' \"$$\")" } ?? "")
        process.arguments = ["-c", "LTM_MB_CLEAN=$$ exec \"$0\" \"$@\"" + fd3, script.path, k] + extraArgs
    } else if let bashOperand {
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
    let r = try runDraining(process)   // 兩條 pipe 同時排空（R27；R26 版循序排空，stderr 超過約 64 KiB 就互鎖——門檻見 runDraining 的說明）
    return ScriptRun(
        status: r.status,
        stdout: String(data: r.stdout, encoding: .utf8) ?? "",
        stderr: String(data: r.stderr, encoding: .utf8) ?? "")
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

/// 一個 PATH 目錄，只放呼叫端指定的假命令（腳本自 R10 起不再需要 `dirname`，鷹架已拆）。腳本以 `python3 -I -S …` 呼叫（R15／R16），
/// 所以判斷 judge（`-c`）／指紋（`-`）那次呼叫看**第一個非旗標引數**——R15 版看 `$1`／`$2`，加一個旗標就全部穿過；`" $* "` 又會被 judge 原始碼裡的 ` - ` 誤中（R16）。
/// `judgeFakes` 是假 python3 對 **judge 呼叫**（`python3 -c …`）的行為；其他呼叫（算查詢集指紋的
/// `python3 - <file>`）轉交真的 python3——要模擬的是 judge 掛掉，不是整個 python 壞掉。
private func makeBinDir(in dir: URL, judgeFakes: [String: String]) throws -> URL {
    let bin = dir.appendingPathComponent("bin-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for (name, body) in judgeFakes {
        let f = bin.appendingPathComponent(name)
        try "#!/bin/bash\nmode=; for a in \"$@\"; do case \"$a\" in -[ISEP]) ;; *) mode=\"$a\"; break ;; esac; done; if [ \"$mode\" = \"-c\" ]; then\n\(body)\nfi\nexec '\(realPython3())' \"$@\"\n".write(to: f, atomically: true, encoding: .utf8)
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

    // 非 ASCII 查詢在 C locale 下逐字命中要判 self（R14，codex：argv 解成 surrogate 時會判 clean）。腳本用 `python3 -I` 且還原 bytes
    // 再 strict 解；`-I` 讓 PYTHONUTF8 之類進不來、macOS 的 fs encoding 又恆為 UTF-8，所以這一臂驅動不到解碼那兩行（任何平台都不行，
    // R15）——它驅動的只是「C locale 下非 ASCII 查詢的 self 判定」這個行為本身。
    // LC_ALL 真的經白名單到了子行程（R15：白名單刪掉 `LC_ALL` 時這條測試的兩臂變成同一臂、仍綠）：stub 把它看到的 LC_ALL 寫進檔案。
    let lcProbe = dir.appendingPathComponent("lc.txt")
    let lcStub = try makeStub(in: dir, responses: [:], raw: ["ZQXJ-LC": "printf '%s' \"${LC_ALL-unset}\" > '\(lcProbe.path)'; printf '[]\\n'"])
    let lcFile = dir.appendingPathComponent("lc-q.txt")
    try "ZQXJ-LC\n".write(to: lcFile, atomically: true, encoding: .utf8)
    _ = try runScript(queries: lcFile, stub: lcStub, extraEnv: ["LC_ALL": "C", "LANG": "C"])
    #expect((try? String(contentsOf: lcProbe, encoding: .utf8)) == "C", "LC_ALL 沒有經白名單到達 ltm 子行程")
    let nonASCII = "ZQXJ-查詢-甲\n"
    let nonASCIIFile = dir.appendingPathComponent("nonascii.txt")
    try nonASCII.write(to: nonASCIIFile, atomically: true, encoding: .utf8)
    let echoStub = try makeStub(in: dir, responses: ["ZQXJ-查詢-甲": #"[{"snippet":"命中裡逐字含 ZQXJ-查詢-甲 這條","uuid":"u"}]"#])
    let cLocale = try runScript(queries: nonASCIIFile, stub: echoStub, extraEnv: ["LC_ALL": "C", "LANG": "C"])
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
        // 兩個合法 token 用空白接起來：R17 版的比對是 `" $ERROR_TOKENS "` 裡的子字串包含，`blank exec` 過得了（與 R17 #5 修掉的白名單同形，R18）。
        ("spacetoken", "printf '42 error(blank exec)\\n'; exit 0"),
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
    try "#!/bin/bash\nmode=; for a in \"$@\"; do case \"$a\" in -[ISEP]) ;; *) mode=\"$a\"; break ;; esac; done; if [ \"$mode\" = \"-\" ]; then exit 3; fi\nexec '\(realPython3())' \"$@\"\n"
        .write(to: fpBroken.appendingPathComponent("python3"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fpBroken.appendingPathComponent("python3").path)
    let fpRun = try runScript(queries: queries, stub: stub, pathOverride: fpBroken.path)
    #expect(fpRun.status == 70 && fpRun.stdout.isEmpty, Comment(rawValue: "rc=\(fpRun.status) out=\(fpRun.stdout)"))
    // 指紋印出大寫「hex」：字面集合比對在任何 locale 都拒絕；bash 3.2 的 [0-9a-f] range 在 en_US.UTF-8 下會把
    // A–E 收進去（collation），這條測試就是釘住不能退回 range 寫法。
    let fpUpper = dir.appendingPathComponent("bin-fpu")
    try FileManager.default.createDirectory(at: fpUpper, withIntermediateDirectories: true)
    try "#!/bin/bash\nmode=; for a in \"$@\"; do case \"$a\" in -[ISEP]) ;; *) mode=\"$a\"; break ;; esac; done; if [ \"$mode\" = \"-\" ]; then printf 'ABCDE1234567\\n'; exit 0; fi\nexec '\(realPython3())' \"$@\"\n"
        .write(to: fpUpper.appendingPathComponent("python3"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fpUpper.appendingPathComponent("python3").path)
    for locale in ["C", "en_US.UTF-8"] {
        let up = try runScript(queries: queries, stub: stub, pathOverride: fpUpper.path, extraEnv: ["LC_ALL": locale, "LANG": locale])
        #expect(up.status == 70 && up.stdout.isEmpty, Comment(rawValue: "LC_ALL=\(locale): rc=\(up.status) out=\(up.stdout)"))
    }
    // 13 個小寫 hex：逐字元檢查只看前 12 位，長度檢查才擋得住。
    let fpLong = dir.appendingPathComponent("bin-fpl")
    try FileManager.default.createDirectory(at: fpLong, withIntermediateDirectories: true)
    try "#!/bin/bash\nmode=; for a in \"$@\"; do case \"$a\" in -[ISEP]) ;; *) mode=\"$a\"; break ;; esac; done; if [ \"$mode\" = \"-\" ]; then printf 'abcdef0123456\\n'; exit 0; fi\nexec '\(realPython3())' \"$@\"\n"
        .write(to: fpLong.appendingPathComponent("python3"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fpLong.appendingPathComponent("python3").path)
    let long = try runScript(queries: queries, stub: stub, pathOverride: fpLong.path)
    #expect(long.status == 70 && long.stdout.isEmpty, Comment(rawValue: "rc=\(long.status) out=\(long.stdout)"))

    let onlyComments = dir.appendingPathComponent("c.txt")
    try "# a\n\n   # b\n".write(to: onlyComments, atomically: true, encoding: .utf8)
    let run = try runScript(queries: onlyComments, stub: stub)
    #expect(run.status == 65 && run.rows.isEmpty, Comment(rawValue: "rc=\(run.status) out=\(run.stdout)"))
}

@Test("measure-baseline.sh：呼叫端 shell 環境經繼承進來的那一面由 re-exec 清掉——xtrace 三條路（`bash -x`／`SHELLOPTS`／`BASH_ENV`）、errexit 兩條、BASH_ENV 定義的同名函式（exec／set／trap／read／printf——這五個名字在結構上都碰不到 `builtin X`；會碰到的只有 `builtin` 自己，而它在防禦外）、DEBUG trap（含蓋掉 `trap` 的那一種）、readonly（QF_CONTENT／SETID）、殘留哨兵（R14 的 `1`、非數字）、allexport 三條與 pre-exported 變數、ltm 組態經 fd 3 完整到達：都不漏、不撞號、不偽造指紋；偽造哨兵而沒有 fd 3 → 70；fd 3 偽造的各種形狀各 70（臂在本體，標題不數；只有 two-token 那一臂另斷言被 `export` 拒絕的記錄值不上 stderr）；恰好滿白名單的合法傳遞 → rc 0；尾標記之後的記錄到不了 judge（0、1、2、255 以外的繼承描述子都關掉；三步：無關閉迴圈時某個繼承 fd 非空、真腳本大於 3 的 fd 一個都沒有、offset 在 EOF 的 seekable 洩漏探得到）；列寫不進 stdout → 70（末行註解）；裸名 LTM_BIN 檢查與執行同一檔；PATH 上的 python3 讀光 fd 3 → 70；預數與量測迴圈的管線建不出來（mutant 複本）→ 70")
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
    // 同名函式：bash 解析名字時函式先於 builtin。`BASH_ENV` 裡把 exec／set／trap 都蓋成 no-op、再把 read／printf 蓋成丟給 /bin/cat 的
    // 函式、然後 `builtin set -x`——`builtin set +x` 沒指名 builtin 就關不掉 trace（fd 3 那個子 shell 展開 `LTM_ANCHOR_KEY`
    // 上 stderr，見各臂的 ZQXJ-KEY）；`builtin exec` 沒指名 builtin 就不會 re-exec、read 函式接走整份查詢檔上 stdout。
    // 這一臂驅動的是 set 與 exec 的 `builtin`；trap 那一個由下面「蓋掉 trap 的 DEBUG trap」臂驅動（R16：R15 版只蓋 trap 不設 trap，
    // 第一行的修飾詞只有字面 pin）。這整族是「意外留在 BASH_ENV 裡的東西」——刻意寫進 BASH_ENV 的任意程式碼不在防禦內，腳本檔頭。
    // 它不是通則（R18）：前四行每個命令字都寫成 `builtin X`，所以這五個名字的函式在結構上碰不到那四行——碰得到的只有蓋掉 `builtin`
    // 本身（`export -f builtin`／BASH_ENV 裡定義它），那一個沒有臂，因為它正是檔頭寫在防禦外的東西（R17 三個反例之一）。
    let fenv = dir.appendingPathComponent("fenv.sh")
    try "exec() { :; }; set() { :; }; trap() { :; }; read() { /bin/cat; return 1; }; printf() { /bin/cat \"$@\"; }; builtin set -x\n".write(to: fenv, atomically: true, encoding: .utf8)
    // DEBUG trap（R15，codex）：`trap 'builtin set -x' DEBUG` 在每個命令前重開 xtrace——第二行 `set +x` 關掉後，第三行執行前又打開，
    // fd 3 那個子 shell 裡展開的密鑰就上 stderr。第一行 `builtin trap - DEBUG …` 扛這一臂。
    let tenv = dir.appendingPathComponent("tenv.sh")
    try "trap 'builtin set -x' DEBUG\n".write(to: tenv, atomically: true, encoding: .utf8)
    // 同上，但 trap 也被蓋掉：`builtin trap - DEBUG …` 沒指名 builtin 就清不掉（R16：這是唯一驅動第一行那個修飾詞的組態）。
    let tenv2 = dir.appendingPathComponent("tenv2.sh")
    try "builtin trap 'builtin set -x' DEBUG; trap() { :; }\n".write(to: tenv2, atomically: true, encoding: .utf8)
    // 殘留哨兵（R15／R16）：R14 版的固定值 `1`——**只有**值 `1`——會跳過 re-exec、走裸身路徑（readonly SETID 偽造指紋 rc 0）；R15 版
    // 的臂用 12345，在 R14 版下也照常 re-exec、修法前後同綠（R16 抓到，空轉臂）。現在哨兵是 `$$`，殘留值一律當未設：兩臂各用
    // R14 的 `1` 與一個不可能是 PID 的 `x`（12345 是合法 PID，撞上時會紅在錯的理由），BASH_ENV 放 readonly SETID，指紋必須仍是真的。
    let senv = dir.appendingPathComponent("senv.sh")
    try "readonly SETID=abcdef012345\n".write(to: senv, atomically: true, encoding: .utf8)
    // readonly：呼叫端把 `QF_CONTENT` 設成 readonly 曾讓預設值冒充讀進來的內容（R13）；把 `SETID` 設成 readonly 會偽造指紋、`bad`
    // 設成 readonly 會吃掉 error 列（R14）——同一族。re-exec 之後這個 shell 裡沒有任何 readonly，指紋必須是真的。
    let renv = dir.appendingPathComponent("renv.sh")
    try "readonly QF_CONTENT='ZQXJ-PRESET'; readonly SETID=abcdef012345\n".write(to: renv, atomically: true, encoding: .utf8)
    // xtrace 各臂帶一把假密鑰：密鑰在 fd 3 那個子 shell 裡展開（不在任何 argv 上，R15），`builtin set +x` 沒生效它就會被 trace 出來
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
        ("BASH_ENV DEBUG trap", try runScript(queries: queries, stub: stub, extraEnv: key.merging(["BASH_ENV": tenv.path]) { $1 })),
        ("BASH_ENV DEBUG trap + shadowed trap", try runScript(queries: queries, stub: stub, extraEnv: key.merging(["BASH_ENV": tenv2.path]) { $1 })),
        ("stale sentinel 1 (R14 value)", try runScript(queries: queries, stub: stub, extraEnv: ["LTM_MB_CLEAN": "1", "BASH_ENV": senv.path])),
        ("stale sentinel non-pid", try runScript(queries: queries, stub: stub, extraEnv: ["LTM_MB_CLEAN": "x", "BASH_ENV": senv.path])),
        // 經**繼承**（不經 BASH_ENV）進來的匯出函式：`export -f read` 在環境裡的形狀是 `BASH_FUNC_read%%=() { … }`（bash 3.2 與 5.3 同）。
        // 檔頭說它是「經繼承進來的狀態、re-exec 之後全掉」，R16 之前零臂（R17）。
        ("inherited BASH_FUNC_read%%", try runScript(queries: queries, stub: stub, extraEnv: key.merging(["BASH_FUNC_read%%": "() { /bin/cat; return 1; }"]) { $1 })),
    ]
    for (label, run) in runs {
        #expect(run.status == 0, Comment(rawValue: "\(label): rc=\(run.status) err=\(run.stderr.count) bytes"))
        #expect(run.rows.count == 1 && run.rows[0].hasSuffix(" clean tool=0") && run.setLine == setLine("ZQXJ-TRACE-ONE\n"), Comment(rawValue: "\(label): \(run.stdout)"))
        let leaked = run.combined.contains("ZQXJ")
        #expect(!leaked, Comment(rawValue: "\(label): 漏了查詢、命中或密鑰（stderr \(run.stderr.count) bytes）"))
    }
    // allexport（R10；放在 xtrace 各臂之後——makeStub 會覆寫同一目錄的 ltm stub）：`BASH_ENV` 裡一行 `set -a` 會把裝著整份查詢集的變數匯出給每個子行程——由 re-exec 扛（R14 之前是第一行的 `set +a`）。
    // ltm stub 是 bash：`${QF_CONTENT+leaked}` 在它的環境裡看得到那個變數就展開成 leaked。
    let aenv = dir.appendingPathComponent("aenv.sh")
    try "set -a\n".write(to: aenv, atomically: true, encoding: .utf8)
    let envProbe = dir.appendingPathComponent("env.txt")
    let probeStub = try makeStub(in: dir, responses: [:], raw: ["ZQXJ-TRACE-ONE": "printf '%s' \"${QF_CONTENT+leaked}\" > '\(envProbe.path)'; printf '[]\\n'"])
    // 第三條向量：呼叫端環境裡已經 export 了同名變數——bash 的賦值會保留 export 屬性。R12–R13 由腳本開頭的 `unset QF_CONTENT` 扛；
    // R14 起由 re-exec 扛（`QF_CONTENT` 不在白名單，整個從環境消失）。變異查法是讓 `case` 的第一臂**永遠**匹配（樣式改成 `*`），
    // 不是讓哨兵永不匹配——那會無限 re-exec、整個套件掛死而不是變紅（R16 更正 R15 的查法）。
    for (label, env) in [("BASH_ENV set -a", ["BASH_ENV": aenv.path]), ("SHELLOPTS=allexport", ["SHELLOPTS": "allexport"]), ("pre-exported QF_CONTENT", ["QF_CONTENT": "pre-exported"])] {
        try? FileManager.default.removeItem(at: envProbe)
        let allexport = try runScript(queries: queries, stub: probeStub, extraEnv: env)
        #expect(allexport.status == 0, Comment(rawValue: "\(label): rc=\(allexport.status)"))
        let exported = (try? String(contentsOf: envProbe, encoding: .utf8)) ?? "(unread)"
        #expect(exported.isEmpty, Comment(rawValue: "\(label): 查詢集變數被匯出進 ltm 的環境：\(exported)"))
    }
    // ltm 自己讀的組態要經白名單到達它（R15：R14 版把 LTM_DERIVED_ROOT 這類丟掉，指向受控索引的量測會靜默量到真索引、rc 0）。
    // 值帶空白與換行也要完整（fd 3 是 NUL 分隔）。
    let cfgProbe = dir.appendingPathComponent("cfg.txt")
    let cfgStub = try makeStub(in: dir, responses: [:], raw: ["ZQXJ-TRACE-ONE": "printf '%s|%s' \"${LTM_DERIVED_ROOT-unset}\" \"${LTM_CORPUS_ROOT-unset}\" > '\(cfgProbe.path)'; printf '[]\\n'"])
    _ = try runScript(queries: queries, stub: cfgStub, extraEnv: ["LTM_DERIVED_ROOT": "/tmp/synthetic derived\nsecond line", "LTM_CORPUS_ROOT": "/tmp/synthetic-corpus"])
    #expect((try? String(contentsOf: cfgProbe, encoding: .utf8)) == "/tmp/synthetic derived\nsecond line|/tmp/synthetic-corpus", Comment(rawValue: "ltm 的組態沒有完整經白名單到達：\((try? String(contentsOf: cfgProbe, encoding: .utf8)) ?? "(unread)")"))
    // 偽造哨兵（R16）：任何在 execve 前知道子行程 PID 的父行程都對得上 `$$`（`bash -c '單一命令'` 不 fork）。對上之後 fd 3 沒有頭標記
    // → 70、零輸出，不是 R15 版的裸身跑完 rc 0。這一臂也驅動 fd 3 的 framing（把頭標記檢查拿掉就變成 rc 0 的裸身量測）。
    let forged = try runScript(queries: queries, stub: stub, sentinelForged: true)
    #expect(forged.status == 70 && forged.stdout.isEmpty && !forged.combined.contains("ZQXJ"), Comment(rawValue: "forged sentinel without fd 3: rc=\(forged.status) out=\(forged.stdout) err=\(forged.stderr)"))
    // 偽造者連 fd 3 都自備、頭尾標記都對、但塞一個名單外的名字：讀端拒絕（R16：R15 版的讀端對名字零驗證，白名單只在寫端執行）。
    let forgedFd3 = try runScript(queries: queries, stub: stub, sentinelForged: true, forgedFd3Records: "LTM_MB_FD3=%s\\0EVIL_INJECTED=yes\\0LTM_MB_END=1\\0")
    #expect(forgedFd3.status == 70 && forgedFd3.stdout.isEmpty, Comment(rawValue: "forged sentinel with forged fd 3: rc=\(forgedFd3.status) out=\(forgedFd3.stdout) err=\(forgedFd3.stderr)"))
    // 串流截斷（尾標記缺）：名字都合法、只是沒有 LTM_MB_END——讀端要當成沒到齊（70），不能靜默用部分白名單量測（R16）。
    let truncated = try runScript(queries: queries, stub: stub, sentinelForged: true, forgedFd3Records: "LTM_MB_FD3=%s\\0LC_ALL=C\\0")
    #expect(truncated.status == 70 && truncated.stdout.isEmpty, Comment(rawValue: "forged fd 3 without end marker: rc=\(truncated.status) out=\(truncated.stdout) err=\(truncated.stderr)"))
    // 頭標記的值：第一筆是合法名字而不是 `LTM_MB_FD3=$$`——讀端要拒絕；只讀不比對的話會把那一筆當頭吃掉、繼續量測（R16 變異）。
    let wrongHead = try runScript(queries: queries, stub: stub, sentinelForged: true, forgedFd3Records: "LC_ALL=C%.0s\\0LTM_MB_END=1\\0")
    #expect(wrongHead.status == 70 && wrongHead.stdout.isEmpty, Comment(rawValue: "forged fd 3 with wrong head record: rc=\(wrongHead.status) out=\(wrongHead.stdout) err=\(wrongHead.stderr)"))
    // 頭標記名字對、**值**錯（不是本行程的 PID）：R16 版只有名字那一半有臂，比對改成只看名字 16 條全綠（R17）。
    let wrongHeadValue = try runScript(queries: queries, stub: stub, sentinelForged: true, forgedFd3Records: "LTM_MB_FD3=0%.0s\\0LTM_MB_END=1\\0")
    #expect(wrongHeadValue.status == 70 && wrongHeadValue.stdout.isEmpty, Comment(rawValue: "forged fd 3 with wrong head value: rc=\(wrongHeadValue.status) out=\(wrongHeadValue.stdout) err=\(wrongHeadValue.stderr)"))
    // 記錄不是 NAME=VALUE（R17：R16 版這條 exit 70 無臂）；名字不是單一合法 token（兩個相鄰白名單名字用空白接起來，R16 版的子字串比對會過
    // ——現在由 `export` 自己拒絕非法識別碼、腳本檢查它的離開碼；另寫一道名字驗證與它重疊、無臂，R17 拆掉）。
    let junkRecord = try runScript(queries: queries, stub: stub, sentinelForged: true, forgedFd3Records: "LTM_MB_FD3=%s\\0junk\\0LTM_MB_END=1\\0")
    #expect(junkRecord.status == 70 && junkRecord.stdout.isEmpty, Comment(rawValue: "forged fd 3 with a non NAME=VALUE record: rc=\(junkRecord.status) out=\(junkRecord.stdout) err=\(junkRecord.stderr)"))
    // 記錄的值帶標記：`export` 拒絕時 bash 會把整筆記錄印上 stderr，腳本把它丟掉（R18：R17 版這個 `2>/dev/null` 無臂，拿掉之後值上 stderr、兩臂仍綠）。
    let twoTokenName = try runScript(queries: queries, stub: stub, sentinelForged: true, forgedFd3Records: "LTM_MB_FD3=%s\\0HOME LC_ALL=ZQXJ-VALUE\\0LTM_MB_END=1\\0")
    #expect(twoTokenName.status == 70 && twoTokenName.stdout.isEmpty && !twoTokenName.combined.contains("ZQXJ"), Comment(rawValue: "forged fd 3 with a two-token name: rc=\(twoTokenName.status) out=\(twoTokenName.stdout) err=\(twoTokenName.stderr)"))
    // fd 3 接到有寫端但不寫的來源：**單次讀取**不能無限期阻塞（R17，DA：hook 裡就是 30 秒逾時後被靜默丟棄）——`read -t 10` 逾時 → 70。
    // 兩臂：頭標記都還沒送就停住（驅動頭讀取的 -t）、頭標記送到後停住（驅動迴圈讀取的 -t）；各要等十秒。寫端在腳本走後一秒內自己退出，
    // 但輪詢有上界（70 秒，跨過下面 `waited < 60` 的門檻）：R18 版無上界的 `kill -0` 輪詢讓「拿掉 `read -t`」的變異從紅變成套件永久掛死
    // （寫端等腳本、腳本等寫端，R19）；有上界時那個變異在 ~70 秒後 EOF → 70、timing 斷言紅。上界用 bash 算術、不用 `seq`（R20：R19 版
    // `$(seq 70)` 在 seq 缺席時展開成空、寫端立刻退出、兩臂仍綠而 `read -t` 零臂）；下界 `waited >= 9` 區分「逾時」與「寫端自己走了」。
    let stall = "exec 2>/dev/null </dev/null; i=0; while [ $i -lt 70 ]; do kill -0 \"$$\" 2>/dev/null || exit; sleep 1; i=$((i + 1)); done"
    for (label, before) in [("before head", ""), ("after head", "printf 'LTM_MB_FD3=%s\\0' \"$$\"; ")] {
        let t0 = Date()
        let blocking = try runScript(queries: queries, stub: stub, sentinelForged: true, forgedFd3Writer: before + stall)
        let waited = Date().timeIntervalSince(t0)
        #expect(blocking.status == 70 && blocking.stdout.isEmpty && waited >= 9 && waited < 60, Comment(rawValue: "forged fd 3 that stalls \(label): rc=\(blocking.status) waited=\(Int(waited))s（沒有 -t 會等到寫端退出；小於 9 秒是寫端自己走了、-t 沒被驅動）out=\(blocking.stdout) err=\(blocking.stderr)"))
    }
    // 寫端**一直寫**合法記錄、永不送尾標記：每次 read 都在十秒內返回，`-t` 永遠不 fire——R17 版永不結束（DA 用 timeout 實測）。總時間的上界來自
    // 記錄筆數封頂（白名單名字數），第 N+1 筆 → 70（R18）。這一臂在幾秒內結束；寫端在讀端關掉管線後被 SIGPIPE 殺掉。寫端自己也有上界
    // （400 筆 × 0.2 秒 ≈ 80 秒，跨過 `dripWaited < 60`）：R19 版是 `while :`，拿掉封頂時這一臂先掛死、後面的有限臂跑不到（R20）。
    let t1 = Date()
    let drip = try runScript(queries: queries, stub: stub, sentinelForged: true, forgedFd3Writer: "printf 'LTM_MB_FD3=%s\\0' \"$$\"; exec 2>/dev/null </dev/null; i=0; while [ $i -lt 400 ]; do printf 'LC_ALL=C\\0'; sleep 0.2; i=$((i + 1)); done")
    let dripWaited = Date().timeIntervalSince(t1)
    #expect(drip.status == 70 && drip.stdout.isEmpty && dripWaited < 60, Comment(rawValue: "forged fd 3 that never stops writing: rc=\(drip.status) waited=\(Int(dripWaited))s out=\(drip.stdout) err=\(drip.stderr)"))
    // 同一個守衛的**有限**形狀：比白名單名字數多的合法記錄、然後正常送尾標記。拿掉筆數封頂時上面那臂紅在逾時（寫端 80 秒後退出），
    // 這一臂是 rc 0 照量——紅在對的理由。
    let whitelistLine = try String(contentsOf: repoRoot().appendingPathComponent("scripts/measure-baseline.sh"), encoding: .utf8).split(separator: "\n").first { $0.hasPrefix("LTM_MB_WHITELIST=\"") } ?? ""
    let whitelistNames = whitelistLine.dropFirst("LTM_MB_WHITELIST=\"".count).dropLast().split(separator: " ").map(String.init)
    #expect(whitelistNames.count >= 6, "白名單變數抽不出來，下面兩臂沒有意義")
    let overLength = try runScript(queries: queries, stub: stub, sentinelForged: true, forgedFd3Records: "LTM_MB_FD3=%s\\0" + String(repeating: "LC_ALL=C\\0", count: whitelistNames.count + 1) + "LTM_MB_END=1\\0")
    #expect(overLength.status == 70 && overLength.stdout.isEmpty, Comment(rawValue: "forged fd 3 with more records than whitelist names: rc=\(overLength.status) out=\(overLength.stdout) err=\(overLength.stderr)"))
    // 邊界值：恰好 N 筆（每個白名單名字一筆，值都合法）＋尾標記是合法的滿白名單傳遞 → rc 0（R19：`-le` 改 `-lt` 全綠、卻會拒絕這種合法傳遞）。
    let fullValues: [String: String] = ["HOME": dir.path, "LC_ALL": "C", "LANG": "C", "TMPDIR": dir.path, "LTM_BIN": stub.path, "LTM_BASELINE_QUERIES": queries.path]
    // fullValues 的鍵是腳本自己會讀的名字（同步測試釘的「白名單 − Sources」那五個＋HOME）；其餘是 ltm 的組態，餵 stub 所以 `x` 無害。
    // 鍵集合要是白名單的子集（R20：白名單長出腳本自己會讀的新名字時，這裡拿到 `x` 會紅在錯的理由——那時把它加進 fullValues）。
    #expect(Set(fullValues.keys).isSubset(of: Set(whitelistNames)), Comment(rawValue: "fullValues 有不在白名單的名字：\(Set(fullValues.keys).subtracting(whitelistNames).sorted())"))
    let fullRecords = whitelistNames.map { "\($0)=\(fullValues[$0] ?? "x")\\0" }.joined()
    let fullHouse = try runScript(queries: queries, stub: stub, sentinelForged: true, forgedFd3Records: "LTM_MB_FD3=%s\\0" + fullRecords + "LTM_MB_END=1\\0")
    #expect(fullHouse.status == 0 && fullHouse.rows.count == 1, Comment(rawValue: "exactly whitelist-count records must be accepted: rc=\(fullHouse.status) out=\(fullHouse.stdout) err=\(fullHouse.stderr)"))
    // 尾標記之後再塞一筆：讀端看到尾標記就 `exec 3<&-`（無條件，R23 放回）並在 `/dev/fd` 列得出來時關掉 0、1、2、255 以外的每一個繼承描述子
    // （R20：R19 版只關 fd 3 這個別名，同一條管線的 procsub 讀端副本（63）judge 照樣繼承；R19 的臂把「讀得到」釘成契約——修好洩漏反而紅）。
    // 三步：(1) 對「拿掉關閉迴圈」的 mutant 複本跑探針，斷言某個繼承 fd 非空（前置；R20 版的紅燈只掛在 fixture 字面上）；(2) 對真腳本斷言每個
    // judge 大於 3 的 fd 一個都沒有（0／1／2 由 stdio 隔離那條測試扛；讀失敗印 `?` 也算紅——這兩處嚴格化今天無臂，R23 標）；(3) 負向臂：把整份
    // 查詢檔開在 fd 9、用一條查詢的檔讀掉那一行讓 offset 在 EOF，探針的 `lseek(0)` 必須看得到（R22：R21 版餵兩條、`lseek` 零臂）。
    // 探針是真 python3（每個 fd 先 `lseek(0)` 再讀）、只印 X／?／空不印內容、附加寫入（第二步兩條查詢、兩個 judge）。
    let fd3Probe = dir.appendingPathComponent("fd3-after-end.txt")
    let probePy = "import os\nout=['fd3=closed;']\ntry:\n    os.fstat(3); out[0]='fd3=open;'\nexcept OSError:\n    pass\nfds=sorted(int(x) for x in os.listdir('/dev/fd'))\nout.append('n=%d;' % len(fds))\nfor fd in fds:\n    if fd <= 3: continue\n    try: os.fstat(fd)\n    except OSError: continue\n    try: os.lseek(fd, 0, 0)\n    except OSError: pass\n    try: data = os.read(fd, 65536)\n    except OSError: data = None\n    out.append('fd%d=%s;' % (fd, '?' if data is None else ('X' if data else '')))\nopen('\(fd3Probe.path)', 'a').write(''.join(out) + '\\n')\n"
    let probeFile = dir.appendingPathComponent("fdprobe.py")
    try probePy.write(to: probeFile, atomically: true, encoding: .utf8)
    let fd3Bin = try makeBinDir(in: dir, judgeFakes: ["python3": "'\(realPython3())' -I -S '\(probeFile.path)'"])
    let scriptText = try String(contentsOf: repoRoot().appendingPathComponent("scripts/measure-baseline.sh"), encoding: .utf8)
    let twoQueries = dir.appendingPathComponent("q2.txt")
    try "ZQXJ-TRACE-ONE\nZQXJ-TRACE-TWO\n".write(to: twoQueries, atomically: true, encoding: .utf8)
    let closeLoop = "        for mb_fd in /dev/fd/*; do"
    #expect(scriptText.components(separatedBy: closeLoop).count == 2, "關閉迴圈那一行找不到或不只一處")
    func mutantScript(_ name: String, _ transform: (String) -> String) throws -> URL {
        let url = dir.appendingPathComponent("mutant-\(name).sh")
        try transform(scriptText).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
    func probeLines() -> [String] { ((try? String(contentsOf: fd3Probe, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    let afterEndRecords = "LTM_MB_FD3=%s\\0LTM_MB_END=1\\0AFTER_END_ZQXJ=1\\0"
    // (1) 前置：沒有關閉迴圈時某個繼承 fd 讀得到東西（探針不印內容，所以證的是「有一個非空的繼承 fd」，今天是 63 上那筆記錄；R22 標明）。
    let noClose = try mutantScript("no-close-loop") { $0.replacingOccurrences(of: closeLoop, with: "        for mb_fd in; do") }
    _ = try runScript(queries: twoQueries, stub: stub, pathPrefix: fd3Bin.path, scriptOverride: noClose, sentinelForged: true, forgedFd3Records: afterEndRecords)
    let leakSeen = probeLines()
    #expect(leakSeen.contains { $0.contains("=X;") },
            Comment(rawValue: "precondition: without the close loop the post-end record must be readable by some judge: \(leakSeen)"))
    // 同一份 mutant 也是 `exec 3<&-` 那一行的臂（R24：R23 放回它時標「無臂」，而這個世界正是它被放回的理由——迴圈 no-op 時
    // 只有它會關掉 fd 3；R25 的 DA 兩次對照確認新合取項是唯一在扛的東西）。**射程**：它釘的是「少一個別名」這個衛生事實，
    // **不是**那一行所支撐的性質——這條斷言**通過**的世界裡 `fd63=X` 仍然成立，紀錄照樣讀得到（fd 3 與 procsub 讀端 63 是
    // 同一條管線的兩個別名）。拆成獨立的 `#expect` 是因為 `&&` 會短路：合在一起時第一半為假就永遠看不到第二半（R25，DA）。
    #expect(leakSeen.allSatisfy { $0.hasPrefix("fd3=closed;") },
            Comment(rawValue: "`exec 3<&-` must still have closed fd 3 even when the close loop is a no-op (it only removes one alias; fd 63 stays): \(leakSeen)"))
    try? FileManager.default.removeItem(at: fd3Probe)
    // (2) 真腳本：每個 judge 的 fd 3 關、3 以外**沒有任何 fd**（R22：R21 版斷言「讀不出 bytes」——唯寫 fd、目錄 fd、讀失敗都會綠；`n>=3` 底線數的是
    // /dev/fd 總數、恆 ≥4、零鑑別力，拆掉；`n=` 只留作診斷）。探針對讀失敗印 `?`，任何 `fdN=` 條目都紅。
    let afterEnd = try runScript(queries: twoQueries, stub: stub, pathPrefix: fd3Bin.path, sentinelForged: true, forgedFd3Records: afterEndRecords)
    let seen = probeLines()
    let allClean = seen.count == 2 && seen.allSatisfy { $0.hasPrefix("fd3=closed;n=") && $0.range(of: #";fd[0-9]+="#, options: .regularExpression) == nil }
    #expect(afterEnd.status == 0 && afterEnd.rows.count == 2 && allClean, Comment(rawValue: "post-end-marker record: every judge must see fd 3 closed and no other fd at all: rc=\(afterEnd.status) probes=\(seen)"))
    try? FileManager.default.removeItem(at: fd3Probe)
    // (3) 負向：整份查詢檔開在 fd 9、讀掉一行——用**一條**查詢的檔，offset 才真的在 EOF，探針的 `lseek(0)` 才被驅動（R22：R21 版餵兩條，
    // 第二行還在目前 offset 之後、不 lseek 也看得到，`lseek` 零臂）。
    let leaky = try mutantScript("leaky-fd9") { $0.replacingOccurrences(of: "n=0; bad=0\n", with: "exec 9< \"$QF\"; IFS= read -r mut9 <&9\nn=0; bad=0\n") }
    #expect(scriptText.components(separatedBy: "n=0; bad=0\n").count == 2, "量測迴圈前的 `n=0; bad=0` 找不到或不只一處")
    let leakyRun = try runScript(queries: queries, stub: stub, pathPrefix: fd3Bin.path, scriptOverride: leaky)
    let leakyProbe = probeLines()
    #expect(leakyRun.status == 0 && leakyProbe.contains { $0.contains("fd9=X;") }, Comment(rawValue: "probe must see a seekable fd holding the query file even when its offset is at EOF: rc=\(leakyRun.status) probes=\(leakyProbe)"))
    try? FileManager.default.removeItem(at: fd3Probe)
    // 兩條重導失敗的 70：預數迴圈、量測迴圈的 `done < <(…)` 建不出來。自然成因（fd 耗盡）走不到這兩個 `||`（bash 自己印 dup 診斷後繼續、或直接
    // 結束 shell），所以分支用**改掉重導目標的 mutant 複本**驅動（R20：R19 版標「無臂：重現不出來」；複本只含腳本、不含查詢檔）。
    let redirect = "done < <(printf '%s' \"$QF_CONTENT\") || { echo \""
    #expect(scriptText.components(separatedBy: redirect).count == 3, "腳本裡帶 || 的 QF_CONTENT 迴圈重導應恰好兩處（預數、量測迴圈）")
    // 述詞抽成具名函式，**下面那條負向臂用同一個**。**射程**：負向臂只驅動 `setLine.hasPrefix` 這一項——
    // 那正是抽出來要達成的事（R24 把述詞換成 `stdout.isEmpty` 時把正向那半弱化了，而這個強化當時無臂）。
    // 其餘四項由正向迴圈斷言為**真**，刪掉合取只會弱化述詞、只會讓 `== true` 更容易成立，所以**結構上驅動不到**
    // （R26，DA 逐條實測：五個合取退掉四個全綠、只有 `hasPrefix` 紅；R25 版寫「把其中**任何一項**拿掉都會紅」，
    // 對五項中的四項為假。不補那四條臂：補了等於再造四個驅動不了的守衛）。
    func redirectArmHolds(_ r: ScriptRun, _ marker: String, _ expectSetLine: Bool) -> Bool {
        r.status == 70 && r.stderr.contains(marker) && r.rows.isEmpty
            && r.stdout.isEmpty == !expectSetLine
            && r.setLine.hasPrefix("set sha256:") == expectSetLine
    }
    for (label, marker, expectSetLine) in [("pre-count", "行數預數的管線建不出來", false), ("measurement loop", "量測迴圈的管線建不出來", true)] {
        let mutant = dir.appendingPathComponent("mutant-\(label.replacingOccurrences(of: " ", with: "-")).sh")
        try scriptText.replacingOccurrences(of: redirect + marker, with: "done < /nonexistent/zqxj-mutant || { echo \"" + marker).write(to: mutant, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mutant.path)
        let broken = try runScript(queries: queries, stub: stub, scriptOverride: mutant)
        // 兩個方向分開判（R25：R24 把整個述詞換成 `stdout.isEmpty`，負向那半確實加強了——`setLine.isEmpty` 對「只印了一個
        // 空行」也為真——但**正向那半被弱化**成「stdout 非空」，實測：把 mutant 的 set 行 printf 改成只印 `\n`，量測迴圈
        // 那一臂就通過，退回 `setLine.isEmpty` 則紅。兩個舊版本都從不檢查印出來的**是** set 行）。
        #expect(redirectArmHolds(broken, marker, expectSetLine), Comment(rawValue: "\(label) redirect failure: rc=\(broken.status) out=\(broken.stdout) err=\(broken.stderr)"))
    }
    // 上面那條 `setLine.hasPrefix("set sha256:")` 的臂（R25：它是本輪新加的強化，自然驅動不到——要驅動得讓
    // stdout 的第一行**不是** set 行）。mutant 在量測迴圈重導壞掉的基礎上，再把 set 行的 printf 改成只印一個換行：
    // 舊述詞（`stdout.isEmpty != expectSetLine`，甚至 R23 的 `setLine.isEmpty != expectSetLine`）對它都會通過。
    let setPrintfOperands = "printf 'set sha256:%s k=%s\\n' \"$SETID\" \"$K\""
    #expect(scriptText.components(separatedBy: setPrintfOperands).count == 2, "set 行 printf 的運算元字面找不到或不只一處")
    let blankSet = try mutantScript("blank-set-line") {
        $0.replacingOccurrences(of: redirect + "量測迴圈的管線建不出來", with: "done < /nonexistent/zqxj-mutant || { echo \"" + "量測迴圈的管線建不出來")
          .replacingOccurrences(of: setPrintfOperands, with: "printf '\\n'")
    }
    let blank = try runScript(queries: queries, stub: stub, scriptOverride: blankSet)
    #expect(blank.status == 70 && blank.rows.isEmpty && !blank.stdout.isEmpty
            && !redirectArmHolds(blank, "量測迴圈的管線建不出來", true),
            Comment(rawValue: "blank set line: 第一行不是 set 行時，正向臂必須拒絕它（R24 的 `stdout.isEmpty` 與 R23 的 `setLine.isEmpty` 兩個舊述詞都會通過）：rc=\(blank.status) out=\(blank.stdout.debugDescription) err=\(blank.stderr)"))
    // 兩個迴圈看到的條數不同 → 70（R20：量測迴圈少跑時 R19 版是 rc 0 配完整集合的指紋與不完整的列，硬規則過）。mutant 複本讓量測迴圈印完第一列就 break。
    let rowLine = "    printf '#%d %sms %s\\n' \"$n\" \"${row%% *}\" \"${row#* }\" || { /bin/echo \"列寫不進 stdout\" >&2; exit 70; }\n"
    #expect(scriptText.components(separatedBy: rowLine).count == 2, "量測迴圈印列的那一行找不到或不只一處")
    let shortLoop = dir.appendingPathComponent("mutant-short-loop.sh")
    try scriptText.replacingOccurrences(of: rowLine, with: rowLine + "    break\n").write(to: shortLoop, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shortLoop.path)
    let short = try runScript(queries: twoQueries, stub: stub, scriptOverride: shortLoop)
    #expect(short.status == 70 && short.rows.count == 1 && short.stderr.contains("量測迴圈看到的條數與預數不同"), Comment(rawValue: "short measurement loop: rc=\(short.status) rows=\(short.rows.count) err=\(short.stderr)"))
    // 列寫不進 stdout → 70（R22：R21 版掛在迴圈的 `||` 上，查詢檔末行是註解時最後執行的是 `continue`、printf 失敗被蓋掉、rc 0 少一列）。
    // mutant 在 set 行之後關掉 stdout；查詢檔刻意以註解收尾。
    let trailingComment = dir.appendingPathComponent("q-trailing-comment.txt")
    try "ZQXJ-TRACE-ONE\n# trailing comment\n".write(to: trailingComment, atomically: true, encoding: .utf8)
    let setPrintf = "printf 'set sha256:%s k=%s\\n' \"$SETID\" \"$K\" || { /bin/echo \"set 行寫不進 stdout\" >&2; exit 70; }\n"
    #expect(scriptText.components(separatedBy: setPrintf).count == 2, "set 行的 printf 找不到或不只一處")
    let closedOut = try mutantScript("closed-stdout") { $0.replacingOccurrences(of: setPrintf, with: setPrintf + "exec 1>&-\n") }
    let noStdout = try runScript(queries: trailingComment, stub: stub, scriptOverride: closedOut)
    #expect(noStdout.status == 70 && noStdout.stderr.contains("列寫不進 stdout") && !noStdout.stderr.contains("#1 "), Comment(rawValue: "row printf failure must be named and the row must not be flushed onto stderr: rc=\(noStdout.status) err=\(noStdout.stderr)"))
    // set 行自己寫不進 stdout → 70（R23，codex：R22 只給每一列加 `||`，set 行寫失敗後腳本繼續、緩衝被 flush 進 procsub 子行程、set 行成了被量測的
    // 「查詢」，只有註解的檔走到 65）。mutant 在 set 行**之前**關掉 stdout；非空檔與只有註解的檔各一臂，stdout 必須空、stderr 不含 set 行。
    let closedBefore = try mutantScript("closed-stdout-before-set") { $0.replacingOccurrences(of: setPrintf, with: "exec 1>&-\n" + setPrintf) }
    let commentsOnly = dir.appendingPathComponent("q-comments-only.txt")
    try "# only a comment\n".write(to: commentsOnly, atomically: true, encoding: .utf8)
    for (label, file) in [("nonempty", queries), ("comments-only", commentsOnly)] {
        let r = try runScript(queries: file, stub: stub, scriptOverride: closedBefore)
        #expect(r.status == 70 && r.stdout.isEmpty && r.stderr.contains("set 行寫不進 stdout") && !r.stderr.contains("set sha256:"), Comment(rawValue: "set-line printf failure (\(label)): rc=\(r.status) out=\(r.stdout) err=\(r.stderr)"))
    }
    // re-exec 那一行的 `|| exit 70`（R23：R16–R22 標「無臂：重現不出來」，其實兩行 mutant 就驅動）：把 `3< <(…)` 換成不存在的路徑 → 70、零輸出。
    let reexecFrom = " 3< <(builtin printf '%s\\0' \"LTM_MB_FD3=$$\";"
    let reexecTo = "LTM_MB_END=1) || exit 70 ;;"
    #expect(scriptText.components(separatedBy: reexecFrom).count == 2, "re-exec 那一行的 process substitution 找不到或不只一處")
    // 第二個 anchor 也釘（R24：R23 版只釘了 `reexecFrom`，另一半漂掉時 guard 退回原文、紅燈由 fallback 扛——fail-closed、一定紅，
    // 但「守衛被拿掉」與「anchor 漂掉」從訊息上分不出來。DA 更正 regression：這是可診斷性，不是「臂會空過」）。
    #expect(scriptText.components(separatedBy: reexecTo).count == 2, "re-exec 那一行的尾標記分支（`\(reexecTo)`）找不到或不只一處")
    let reexecBroken = try mutantScript("reexec-redirect") { text in
        guard let a = text.range(of: reexecFrom), let b = text.range(of: reexecTo, range: a.upperBound..<text.endIndex) else { return text }
        return text.replacingCharacters(in: a.lowerBound..<b.upperBound, with: " 3< /nonexistent/zqxj-reexec-mutant || exit 70 ;;")
    }
    let reexecRun = try runScript(queries: queries, stub: stub, scriptOverride: reexecBroken)
    #expect(reexecRun.status == 70 && reexecRun.stdout.isEmpty && !reexecRun.combined.contains("ZQXJ"), Comment(rawValue: "re-exec redirect failure: rc=\(reexecRun.status) out=\(reexecRun.stdout) err=\(reexecRun.stderr)"))
    // LTM_BIN 裸名（codex R22）：bash 的 `-f` 看 cwd、python 的 execvp 沿 PATH——腳本把不含 `/` 的值固定成 `./`。cwd 與 PATH 各一支同名 stub，
    // cwd 那支回一列命中、PATH 那支以 rc 9 死：跑的必須是 cwd 那支（`./` 規則的臂——退掉它就跑到 PATH 那支、error(9)）；cwd 沒有時 → 69，
    // 這一臂扛的是 `-f`／`-x` 守衛、不是 `./` 規則（bash 的 `-f` 對裸名本來就看 cwd；R23 更正 R22 的註解）。
    let cwdDir = dir.appendingPathComponent("cwd-ltm"); try FileManager.default.createDirectory(at: cwdDir, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: try makeStub(in: cwdDir, responses: ["ZQXJ-TRACE-ONE": #"[{"snippet":"ZQXJ-SNIPPET 一段命中","uuid":"u"}]"#]), to: cwdDir.appendingPathComponent("zqxjltm"))
    let pathDir = dir.appendingPathComponent("path-ltm"); try FileManager.default.createDirectory(at: pathDir, withIntermediateDirectories: true)
    try "#!/bin/bash\nexit 9\n".write(to: pathDir.appendingPathComponent("zqxjltm"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pathDir.appendingPathComponent("zqxjltm").path)
    let bareCwd = try runScript(queries: queries, stub: stub, ltmBinOverride: "zqxjltm", pathPrefix: pathDir.path, cwd: cwdDir)
    #expect(bareCwd.status == 0 && bareCwd.rows.count == 1 && bareCwd.rows[0].hasSuffix(" clean tool=0"), Comment(rawValue: "bare LTM_BIN must run the cwd file the check looked at: rc=\(bareCwd.status) out=\(bareCwd.stdout) err=\(bareCwd.stderr)"))
    let cwdEmpty = dir.appendingPathComponent("cwd-empty"); try FileManager.default.createDirectory(at: cwdEmpty, withIntermediateDirectories: true)
    let bareAbsent = try runScript(queries: queries, stub: stub, ltmBinOverride: "zqxjltm", pathPrefix: pathDir.path, cwd: cwdEmpty)
    #expect(bareAbsent.status == 69 && bareAbsent.stdout.isEmpty, Comment(rawValue: "bare LTM_BIN absent from cwd must be 69 even if PATH has it: rc=\(bareAbsent.status) out=\(bareAbsent.stdout)"))
    // PATH 上的 python3 wrapper 在指紋呼叫（`-`）先把 fd 3 讀光再交給真的 python3：指紋是空集合的、每一列照量、rc 0——完整性缺口（R18，DA）。
    // 有非註解行卻算出空集合的指紋 → 70、零輸出。
    let drainBin = dir.appendingPathComponent("bin-drain")
    try FileManager.default.createDirectory(at: drainBin, withIntermediateDirectories: true)
    try "#!/bin/bash\nmode=; for a in \"$@\"; do case \"$a\" in -[ISEP]) ;; *) mode=\"$a\"; break ;; esac; done; if [ \"$mode\" = \"-\" ]; then /bin/cat <&3 >/dev/null; fi\nexec '\(realPython3())' \"$@\"\n"
        .write(to: drainBin.appendingPathComponent("python3"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: drainBin.appendingPathComponent("python3").path)
    let drained = try runScript(queries: queries, stub: stub, pathPrefix: drainBin.path)
    #expect(drained.status == 70 && drained.stdout.isEmpty && drained.stderr.contains("空集合") && !drained.combined.contains("ZQXJ"), Comment(rawValue: "fingerprint python drained on fd 3: rc=\(drained.status) out=\(drained.stdout) err=\(drained.stderr)"))
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
    try "#!/bin/bash\necho 'ZQXJ-STDERR-NOISE' >&2\nmode=; for a in \"$@\"; do case \"$a\" in -[ISEP]) ;; *) mode=\"$a\"; break ;; esac; done; if [ \"$mode\" = \"-c\" ]; then /bin/cat >/dev/null; fi\nmode=; for a in \"$@\"; do case \"$a\" in -[ISEP]) ;; *) mode=\"$a\"; break ;; esac; done; if [ \"$mode\" = \"-\" ]; then { [ -p /dev/fd/3 ] && printf pipe || printf notpipe; } > '\(fdProbe.path)'; fi\nexec '\(realPython3())' \"$@\"\n"
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

@Test("measure-baseline.sh：查詢檔預設在腳本旁，走訪仿 bash 找腳本運算元的順序——裸名經 PATH 解到腳本目錄而非 cwd 誘餌；相對路徑；cwd 與 PATH 各一份時用 cwd；644 排在 755 前用 644；000 排在 755 前跳過 000；PATH 元素字面 `~/…`、裸 `~` 展開；`~+/…`（後面另有一份）與 HOME 沒設的 `~/…` → 66；cwd 放假 hashlib.py／json.py 指紋與 verdict 仍真")
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
    //    R15：`~+/a` **後面再放一份**同名腳本（A）——R14 版跳過不仿的元素後繼續往後找，會量到 A 而 rc 0；現在一遇到就停、66。
    let plus = try runScript(queries: unused, stub: stub, pathPrefix: "~+/a:" + a.path, unsetting: ["LTM_BASELINE_QUERIES"], bashOperand: "measure-baseline.sh", cwd: dir)
    #expect(plus.status == 66 && plus.stdout.isEmpty && plus.stderr.contains("/nonexistent/"), Comment(rawValue: "~+ in PATH: rc=\(plus.status) \(plus.stdout) err=\(plus.stderr)"))
    // 9. PATH 元素只有 `~`（HOME=H，腳本複本與查詢檔就在 H 裡）：bash 展開成 H → 指紋是 H 的（R15：R14 版這一分支無臂）。
    let h = dir.appendingPathComponent("h")
    try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: h.appendingPathComponent("measure-baseline.sh"))
    let inHome = "ZQXJ-HOME-ONE\nZQXJ-HOME-TWO\nZQXJ-HOME-THREE\nZQXJ-HOME-FOUR\n"
    try inHome.write(to: h.appendingPathComponent("baseline-queries.txt"), atomically: true, encoding: .utf8)
    let bareTilde = try runScript(queries: unused, stub: stub, pathPrefix: "~", extraEnv: ["HOME": h.path], unsetting: ["LTM_BASELINE_QUERIES"], bashOperand: "measure-baseline.sh", cwd: b)
    #expect(bareTilde.status == 0 && bareTilde.rows.count == 4 && bareTilde.setLine == setLine(inHome), Comment(rawValue: "bare ~ in PATH: rc=\(bareTilde.status) \(bareTilde.stdout) err=\(bareTilde.stderr)"))
    // 10. PATH 元素 `~/a` 而 HOME 沒設：走訪當作找不到 → 66（bash 自己會用 passwd 的家目錄，這裡刻意不仿；R15：R14 版這一分支無臂）。
    //     bash 找腳本時也要 HOME——所以 PATH 另放一份 A 在後面讓 bash 找得到、走訪卻在 `~/a` 就停。
    let noHome = try runScript(queries: unused, stub: stub, pathPrefix: "~/a:" + a.path, unsetting: ["LTM_BASELINE_QUERIES", "HOME"], bashOperand: "measure-baseline.sh", cwd: b)
    #expect(noHome.status == 66 && noHome.stdout.isEmpty && noHome.stderr.contains("/nonexistent/"), Comment(rawValue: "~/ with HOME unset: rc=\(noHome.status) \(noHome.stdout) err=\(noHome.stderr)"))
    // 11. cwd 放一支假 `hashlib.py`（回一個合形狀的假指紋、把內容寫進探針檔）：`python3 -I` 不把 cwd 放進 sys.path，指紋必須仍是真的、
    //     探針檔不存在（R15，DA：re-exec 只清環境，cwd 那一半 python 的模組搜尋路徑要另外關）。
    let shimProbe = dir.appendingPathComponent("shim.txt")
    try "import sys\nclass _H:\n    def update(self, b):\n        open('\(shimProbe.path)', 'ab').write(b)\n    def hexdigest(self):\n        return 'deadbeefcafe' + '0' * 52\ndef sha256():\n    return _H()\n".write(to: a.appendingPathComponent("hashlib.py"), atomically: true, encoding: .utf8)
    //     judge 那一支同理（R16：R15 只給指紋那支一臂）：cwd 放一支 `json.py` 讓 `loads` 回空陣列，沒有 `-I` 時每一列都變成 `empty`。
    try "def loads(x):\n    return []\n".write(to: a.appendingPathComponent("json.py"), atomically: true, encoding: .utf8)
    let shim = try runScript(queries: unused, stub: stub, unsetting: ["LTM_BASELINE_QUERIES"], bashOperand: "measure-baseline.sh", cwd: a)
    #expect(shim.status == 0 && shim.setLine == setLine(real) && shim.rows.map(tail) == ["clean tool=0", "clean tool=0"] && !FileManager.default.fileExists(atPath: shimProbe.path), Comment(rawValue: "hashlib.py/json.py in cwd: rc=\(shim.status) \(shim.stdout) probe=\(FileManager.default.fileExists(atPath: shimProbe.path))"))
}
