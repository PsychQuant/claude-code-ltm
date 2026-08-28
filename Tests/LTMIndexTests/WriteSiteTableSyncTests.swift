import Foundation
import Testing

@testable import LTMIndex

/// 那張寫入站點表**不宣稱自己完整**（標題已於 R12 改掉），而這兩條檢查也不能
/// 證明完整——它們證明的是一組**有界**的性質，逐條寫在下方的誠實邊界裡。
///
/// **這行字本身是一次收回的第二份副本。** R12 把完整性宣稱從 `IndexBuilder.swift`
/// 的標題撤掉了，而這個檔頭原樣留著「宣稱自己完整」——同一個形狀第二次
/// （#44 R13 verify，codex）：收回只改了其中一份寫者。
///
/// ## 上一版是假的，而且假在兩個方向
///
/// 上一版掃 grep pattern 數出一個數字，與**測試檔裡的一個常數**比對。它從來
/// 沒有打開過那張表（#44 R10 verify，requirements lens 實測）：
///
/// - 把表裡兩列刪掉 → **綠**（刪列是隱形的）
/// - 用記憶層實際使用的 primitive（`open(` / `write(`）加一個新站點 → **綠**
///   （那兩個字串不在 pattern 清單裡）
///
/// 而我為它寫的「誠實邊界」說它比對數量不比對身分——**那句話本身就是這個
/// cluster 那條規律的第十輪實例**：一句把某個東西劃到檢查之外的話，而真正的
/// 界線比我承認的還大一層。
///
/// 我當時的 commit message 還寫「它一建立就紅（14 vs 我宣稱的 12），而那兩處
/// 正是我沒列的記憶層站點」——**重跑不重現**（同一個算法在 `37a5bc4` 上是 13）。
/// 那 14 裡有一個是 helper 自己的宣告行，是 grep 的偽陽性，不是漏掉的表列。
/// **我調 `declared` 調到綠，然後編了一個解釋。**
///
/// ## 現在的機制：身分，不是數量
///
/// 每個**已知的**站點在原始碼裡掛一個 `// WRITE-SITE: <name>` 標記，表的第一欄就是那些
/// 名字。這條檢查比對**兩個集合**：
///
/// - 表裡有、原始碼沒有 → 站點被刪掉而表沒改
/// - 原始碼有、表裡沒有 → 新增站點而表沒改
///
/// 兩個方向都會紅，而且訊息會指名是哪一個。
@Test("每個 WRITE-SITE 標記都在表裡，表裡每一列都有對應的標記")
func everyWriteSiteAppearsInTheTable() throws {
    let root = try repositoryRootForWriteSites()

    // 1. 原始碼裡的標記。
    let marked = Set(WriteSiteScan.markers(in: try sourceFiles(root)).map(\.name))
    #expect(!marked.isEmpty, "一個標記都沒抓到——這條檢查就失去意義，比失敗更糟")

    // 2. 表的第一欄。表活在 `IndexBuilder.swift` 的 doc comment 裡。
    let source = try String(
        contentsOf: root.appendingPathComponent("Sources/LTMIndex/IndexBuilder.swift"),
        encoding: .utf8)
    var tabled: Set<String> = []
    var inTable = false
    for line in source.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/// | `WRITE-SITE` 標記") { inTable = true; continue }
        guard inTable else { continue }
        // **表結束就停。** 先前這裡對非表格的 `///` 行 `continue`，於是它一路
        // 讀進了下方 `replaceItemAt` 那張量測表，把「dest」「hard link → 別的檔案」
        // 當成站點名字。一條會把別的表當成自己的檢查，比沒有檢查更難看。
        guard trimmed.hasPrefix("/// |") else { break }
        let columns = trimmed.dropFirst("/// |".count).components(separatedBy: "|")
        guard let first = columns.first else { continue }
        let cell = first.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        if !cell.isEmpty, !cell.hasPrefix("-") { tabled.insert(cell) }
    }

    #expect(
        marked.subtracting(tabled).isEmpty,
        "原始碼有標記但表裡沒有：\(marked.subtracting(tabled).sorted())——新增站點時表必須跟著改")
    #expect(
        tabled.subtracting(marked).isEmpty,
        "表裡有但原始碼找不到標記：\(tabled.subtracting(marked).sorted())——站點被移除時表必須跟著改")
}

/// **標記是自願的，所以還需要第二半。** 上一條比對的是「標記 ↔ 表」——它擋得住
/// 表漂移，擋不住「加了一個站點而**沒掛標記**」。那正是 R10 用記憶層真正的
/// primitive（`open(` / `write(`）示範的那個洞。
///
/// 這一條掃會改變檔案系統的呼叫，要求每一個上方 **3 行內**有 `// WRITE-SITE:`。
///
/// ## 誠實邊界（第四次寫；前三次都把界線畫小了一級）
///
/// 四次的紀錄一起留著，因為它們是**同一個錯的四個變體**——每一次的修法都是再
/// 列舉一次限度，每一次都有下一個沒被列到的：
///
/// 1. R10：說它「比對數量不比對身分」，而真相是**它連表都沒讀**。
/// 2. R11：說它「涵蓋範圍等於那份 primitive 清單」，而真相是清單 ∩ 兩個模組 ∩
///    非遞迴 ∩ 單行連續文字。三個額外的限制一個都沒寫出來，其中一個讓
///    **R10 用來殺死上一版的那個變異對新版照樣全綠**。
/// 3. R14：收緊成「一個標記只背書一個呼叫」，而實作是**逐行**認領——同一行上的
///    兩個呼叫仍然共用一個標記，包含它剛「修掉」的那個三元運算子形狀折成一行。
/// 4. R15（本次）：又一個沒被寫進來的限度——**排除是整行的**。一行只要出現
///    `O_RDONLY` 就整行跳過，同一行上真正的寫入呼叫一起隱形。
///
/// 而 R14 那次還有一個不在「限度」這個軸上的問題：**那個機制沒有執行點**。
/// 檢查跑在真實的樹上，而樹裡按定義不含它要防的反例，所以退掉整段
/// `claimedMarkers` 是全綠的。修法見 `WriteSiteScan` 的 doc comment：把掃描抽成
/// 純函式，反例用合成輸入餵進來。
///
/// 現在的界線，逐條寫出來：
///
/// - **範圍**：`Sources/` 底下每一個 `.swift`，遞迴。不再限模組。
/// - **手段**：下方 `primitives` 清單。它現在含 `open(` / `write(`（記憶層實際
///   使用的那兩個），但**它仍然是一份會漏的列舉**——一個經由 `Process` 呼叫外部
///   程式、或用清單外 syscall 的新站點仍然隱形。
/// - **形式**：**單行連續文字比對**，標記要在呼叫上方 **3 行內**。呼叫被換行
///   拆開就抓不到（`try data\n    .write(to: …)` 逃得掉，實測過），拆得比 3 行
///   更開也逃得掉。兩者是同一個限制的兩面：這條檢查看的是文字，不是語法樹。
/// - **粒度**：逐**呼叫**（同一行上的每一個），逐**比對**排除。不是逐行——那是
///   R14 與 R15 各自踩到的一次。
/// - **標記名稱唯一**，由 `writeSiteMarkerNamesAreUnique` 執行。沒有這條的話，
///   複製一個既有名字就能讓新站點在兩個 `Set` 的比對裡隱形。
///
/// **為什麼不寫成性質**：「會改變檔案系統」在 Swift 型別層沒有表達方式。要真正
/// 關掉它需要 SwiftSyntax／lint 層的 AST 檢查，或禁止業務模組直接呼叫這些 API
/// 而強制走少數可稽核的 wrapper。**兩者都沒做，這是一個具名的未完成，不是邊界。**
@Test("每一個寫入 primitive 的呼叫都掛了 WRITE-SITE 標記")
func everyWritePrimitiveCarriesAMarker() throws {
    let root = try repositoryRootForWriteSites()
    let unmarked = WriteSiteScan.unmarked(in: try sourceFiles(root))
    #expect(
        unmarked.isEmpty,
        "這些呼叫會改變檔案系統但沒掛 WRITE-SITE 標記：\n\(unmarked.joined(separator: "\n"))")
}

/// **標記名稱必須唯一。**
///
/// 上面那條「標記 ↔ 表」比對的是兩個 `Set`，所以**重複的名字會被去重吃掉**：
/// 在另一個檔案複製一個既有的 `// WRITE-SITE: derived-open-helper` 並在它下面
/// 加一個新的 `open(...)`，兩條檢查都綠——新站點沒有自己的表列，而表宣稱每一列
/// 對應一個站點（#44 R15 verify，codex 提出、本輪以合成輸入實測）。
///
/// R14 收緊的是「不得借用同一個標記**行**」，而同一個逃逸往下移了一層變成
/// 「複製同一個標記**名**」。本 repo 記過這個形狀：**關掉一個自報的洞時，先問
/// 「我用什麼當鍵」——那個鍵通常就是下一個同形狀的自報**（#34→#37）。這次的鍵
/// 是名字，所以名字必須唯一，否則那張表與站點就不是一對一。
@Test("WRITE-SITE 標記名稱在整棵 Sources/ 樹裡唯一")
func writeSiteMarkerNamesAreUnique() throws {
    let root = try repositoryRootForWriteSites()
    let markers = WriteSiteScan.markers(in: try sourceFiles(root))
    var seen: [String: [String]] = [:]
    for marker in markers { seen[marker.name, default: []].append(marker.location) }
    let duplicated = seen.filter { $0.value.count > 1 }
        .map { "\($0.key): \($0.value.joined(separator: ", "))" }
        .sorted()
    #expect(
        duplicated.isEmpty,
        """
        這些 WRITE-SITE 名稱出現超過一次——表的每一列對應一個站點，重名讓集合比對看不見新站點：
        \(duplicated.joined(separator: "\n"))
        """)
}

// MARK: - 掃描器自己的執行點（合成輸入）

/// 下面這組測試存在的理由寫在 `WriteSiteScan` 的 doc comment 裡：真實的樹按定義
/// 不含這些反例，所以機制在那裡驅動不到。**逐一退掉 `WriteSiteScan` 的任一機制，
/// 這組裡都至少有一條變紅**——這是 R14 那版沒有的性質。
private func synthetic(_ body: String) -> [(path: String, lines: [String])] {
    [(path: "Synthetic.swift", lines: body.components(separatedBy: "\n"))]
}

@Test("同一行上的兩個呼叫不能共用一個標記")
func writeSiteScannerRejectsTwoCallsOnOneLine() {
    let flagged = WriteSiteScan.unmarked(
        in: synthetic(
            """
            // WRITE-SITE: only-one
            let a = open(p1, O_WRONLY); let b = open(p2, O_WRONLY | O_CREAT, 0o600)
            """))
    #expect(flagged.count == 1, "第二個呼叫必須被抓出來，實得 \(flagged)")
}

@Test("折成一行的三元運算子不能共用一個標記")
func writeSiteScannerRejectsSingleLineTernary() {
    // 這正是本輪在 `openDerivedFileNoFollow` 折掉的那個形狀。R14 的版本把它折成
    // 一個**呼叫**所以綠了；折成一**行**（兩個呼叫）在 R14 的版本也是綠的。
    let flagged = WriteSiteScan.unmarked(
        in: synthetic(
            """
            // WRITE-SITE: only-one
            let fd = (flags & O_CREAT) != 0 ? open(p, flags, mode) : open(p, flags)
            """))
    #expect(flagged.count == 1, "三元的第二個分支必須被抓出來，實得 \(flagged)")
}

@Test("相鄰的第二個站點不能借用前一個站點的標記")
func writeSiteScannerRejectsBorrowedMarker() {
    // R14 關掉的那個洞的回歸鎖。
    let flagged = WriteSiteScan.unmarked(
        in: synthetic(
            """
            // WRITE-SITE: existing
            open(existingPath, O_WRONLY)
            open(newPath, O_WRONLY | O_CREAT, 0o600)
            """))
    #expect(flagged.count == 1, "借用標記的那個呼叫必須被抓出來，實得 \(flagged)")
}

@Test("同一行上的唯讀 open 不會讓同一行的寫入 open 隱形")
func writeSiteScannerScopesExclusionsPerCall() {
    // 上一版對整行 `continue`：這一行含 `O_RDONLY`，於是**兩個**呼叫一起隱形。
    let flagged = WriteSiteScan.unmarked(
        in: synthetic("let r = open(a, O_RDONLY); let w = open(b, O_WRONLY)"))
    #expect(flagged.count == 1, "唯讀那個要放行、寫入那個要抓出來，實得 \(flagged)")
}

@Test("巢狀的 pattern 只算一個呼叫")
func writeSiteScannerMergesNestedPatterns() {
    // `.write(to:` 內含 `write(`。數成兩個會要求兩個標記，那是偽陽性。
    #expect(WriteSiteScan.writeCallOffsets(in: "try data.write(to: url)").count == 1)
}

@Test("掛好標記的單一呼叫是乾淨的")
func writeSiteScannerAcceptsAProperlyMarkedCall() {
    let flagged = WriteSiteScan.unmarked(
        in: synthetic(
            """
            // WRITE-SITE: proper
            open(path, O_WRONLY | O_CREAT, 0o600)
            """))
    #expect(flagged.isEmpty, "正常掛好標記的呼叫不該被抓，實得 \(flagged)")
}

@Test("重名的標記在 markers() 裡看得見")
func writeSiteScannerSurfacesDuplicateNames() {
    // 這是 `writeSiteMarkerNamesAreUnique` 的執行點：真實的樹沒有重名，所以那條
    // 測試在樹上永遠綠，驅動不到它自己的判準。
    let names = WriteSiteScan.markers(
        in: synthetic(
            """
            // WRITE-SITE: dup
            open(a, O_WRONLY)
            // WRITE-SITE: dup
            open(b, O_WRONLY)
            """)
    ).map(\.name)
    #expect(names == ["dup", "dup"], "重複的名字必須都在，不能被去重，實得 \(names)")
}

// MARK: - 掃描器（純函式，抽出來是為了讓它有執行點）

/// **為什麼這是一個純函式，而不是寫在測試迴圈裡。**
///
/// 上一版（R14）把「一個標記只背書一個呼叫」直接寫進 `#Test` 的迴圈，掃的是
/// **真實的 `Sources/` 樹**。而那個機制要防的缺陷，按定義不可能存在於一棵通過
/// 檢查的樹裡——所以**沒有任何測試能驅動它**：退掉整段 `claimedMarkers`，516
/// 條測試全綠（#44 R15 verify，三個 lens 各自實測到這件事）。
///
/// 本 repo 對這種東西的既定處置是**刪掉，不是留著加註解**——我在 R14 用這條規則
/// 刪過一個 `O_NOFOLLOW`。這裡不刪而是給它執行點，理由是它防的缺陷真實存在
/// （R14 收緊當下就在 `openDerivedFileNoFollow` 抓到一個），差別只在於**檢查跑在
/// 一棵不可能含有反例的樹上**。把掃描抽成吃 `[(path, lines)]` 的純函式之後，
/// 反例可以用合成輸入餵進來——下方 `writeSiteScannerRejects*` 那組測試就是它的
/// 執行點，逐一退掉任一機制都會變紅。
enum WriteSiteScan {
    /// **它仍然是一份會漏的列舉。** 經由 `Process` 呼叫外部程式、或用清單外
    /// syscall 的新站點仍然隱形。這是具名的限度，不是「檢查涵蓋所有寫入」。
    static let primitives = [
        "FileHandle(forWritingTo:", "FileHandle(forUpdating:", ".write(to:",
        "removeItem(", "replaceItemAt(", "createDirectory(", "sqlite3_open_v2(",
        "ftruncate(", "mkfifo(", "openDerivedFileNoFollow(",
        "open(", "write(", "pwrite(", "truncate(", "rename(", "link(", "copyItem(",
        "moveItem(", "createFile(", "createSymbolicLink(",
    ]

    /// 一行上**每一個**寫入呼叫的起點。
    ///
    /// **回傳呼叫，不是「這行有沒有」。** 上一版數的是**行**，於是同一行上的兩個
    /// 呼叫共用一個標記——包含本輪剛「修掉」的那個三元運算子形狀：把它折成一
    /// **行**（而不是一個呼叫）就照樣全綠（#44 R15 verify，logic lens 用合成輸入
    /// 逐字重現）。
    ///
    /// 重疊／巢狀的比對會被合併：`.write(to:` 內含 `write(`，那是**一個**呼叫。
    static func writeCallOffsets(in line: String) -> [Int] {
        let chars = Array(line)
        var spans: [(start: Int, end: Int, pattern: String)] = []
        for pattern in primitives {
            let pat = Array(pattern)
            guard !pat.isEmpty, chars.count >= pat.count else { continue }
            for start in 0...(chars.count - pat.count)
            where Array(chars[start..<(start + pat.count)]) == pat {
                spans.append((start, start + pat.count, pattern))
            }
        }
        spans = spans.filter { !excluded(chars: chars, span: $0) }
        guard !spans.isEmpty else { return [] }
        spans.sort { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }
        var merged: [(start: Int, end: Int)] = []
        for span in spans {
            if let last = merged.last, span.start < last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append((span.start, span.end))
            }
        }
        return merged.map(\.start)
    }

    /// **排除是逐個比對，不是逐行。**
    ///
    /// 上一版對整行 `continue`：一行只要出現 `O_RDONLY`／`.open(`／
    /// `FileHandle.standard`，**同一行上真正的寫入呼叫就一起隱形**。那是第四個
    /// 沒被寫進誠實邊界的限度，而那份邊界當時已經是第三次改寫（#44 R15 verify）。
    private static func excluded(
        chars: [Character], span: (start: Int, end: Int, pattern: String)
    ) -> Bool {
        let lead = String(chars[max(0, span.start - 60)..<span.start])
        // 1. 函式**宣告**不是呼叫站點（`public static func open(url:…)`）。
        if lead.hasSuffix("func ") { return true }
        // 2. `VectorSidecar.open(` 是 Swift 方法名，不是 `open(2)`。
        //    只對 `open(` 這個名字套用——`.write(to:` 前面也是點，但它是真呼叫。
        if span.pattern == "open(", span.start > 0, chars[span.start - 1] == "." { return true }
        // 3. 寫到 stdout／stderr 的 `FileHandle.standard*.write`：串流不是檔案系統。
        if span.pattern == "write(" || span.pattern == ".write(to:",
            lead.contains("FileHandle.standard")
        {
            return true
        }
        // 4. `O_RDONLY` 的 open 是唯讀。**只看這個呼叫自己的引數**——用括號配對
        //    取出來，而不是問「這一行有沒有出現 O_RDONLY」。
        if ["open(", "sqlite3_open_v2(", "openDerivedFileNoFollow("].contains(span.pattern) {
            if argumentText(chars: chars, openParenAt: span.end - 1).contains("O_RDONLY") {
                return true
            }
        }
        return false
    }

    /// 從 `(` 起算的括號配對內容。呼叫被換行拆開時括號不會閉合，於是取到行尾
    /// ——那是「單行文字比對」這個既有限度的延伸，不是新的洞。
    private static func argumentText(chars: [Character], openParenAt index: Int) -> String {
        var depth = 0
        var out: [Character] = []
        var cursor = index
        while cursor < chars.count {
            if chars[cursor] == "(" {
                depth += 1
            } else if chars[cursor] == ")" {
                depth -= 1
                if depth == 0 { break }
            } else if depth > 0 {
                out.append(chars[cursor])
            }
            cursor += 1
        }
        return String(out)
    }

    /// 每一個標記的名字與位置。**回傳陣列不是集合**——重複的名字必須看得見
    /// （見 `writeSiteMarkerNamesAreUnique`）。
    static func markers(in files: [(path: String, lines: [String])]) -> [(
        name: String, location: String
    )] {
        var out: [(String, String)] = []
        for file in files {
            for (index, line) in file.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("// WRITE-SITE:") else { continue }
                let name = trimmed.dropFirst("// WRITE-SITE:".count)
                    .trimmingCharacters(in: .whitespaces)
                out.append((name, "\(file.path):\(index + 1)"))
            }
        }
        return out
    }

    /// 沒掛標記的寫入呼叫。
    ///
    /// **claimed 是每個檔案自己一份的行號集合**，所以不需要任何檔案識別鍵。
    /// 上一版用 `lastPathComponent` 當鍵的一半，而 `Sources/` 有兩組重名檔
    /// （`Module.swift`／`Projection.swift`）——那個碰撞目前不可達（重名檔一個
    /// 標記都沒有），但把鍵整個拿掉比說明它為什麼還沒炸要好。
    static func unmarked(in files: [(path: String, lines: [String])]) -> [String] {
        var out: [String] = []
        for file in files {
            var claimed: Set<Int> = []
            for (index, line) in file.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // helper 自身的宣告不是站點，它是所有走它的站點的實作。
                guard !trimmed.hasPrefix("func openDerivedFileNoFollow") else { continue }
                let calls = writeCallOffsets(in: trimmed)
                guard !calls.isEmpty else { continue }
                let nearby = (max(0, index - 3)..<index).filter {
                    file.lines[$0].trimmingCharacters(in: .whitespaces)
                        .hasPrefix("// WRITE-SITE:")
                }
                // **一個標記背書一個呼叫**，而「呼叫」是這一行上的每一個。
                for _ in calls {
                    guard let claimable = nearby.first(where: { !claimed.contains($0) }) else {
                        out.append("\(file.path):\(index + 1) \(trimmed.prefix(60))")
                        continue
                    }
                    claimed.insert(claimable)
                }
            }
        }
        return out
    }
}

/// `Sources/` 底下每一個 `.swift` 的 (repo 相對路徑, 行)。
private func sourceFiles(_ root: URL) throws -> [(path: String, lines: [String])] {
    try swiftSourcesUnderSources(root).map { file in
        let relative =
            file.path.hasPrefix(root.path + "/")
            ? String(file.path.dropFirst(root.path.count + 1))
            : file.path
        return (
            path: relative,
            lines: try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        )
    }
}

/// `Sources/` 底下**每一個** `.swift`，遞迴。
///
/// 上一版寫 `for module in ["LTMIndex", "LTMMemory"]` + 非遞迴的
/// `contentsOfDirectory`——而 `Sources/` 有 8 個模組，其中 `Sources/ltm/Commands.swift`
/// 就有兩個 `createDirectory`（建的正是**記憶層根目錄**）逃掉了。那兩處用的是
/// **清單內**的 primitive，逃掉純粹因為所在模組沒被打開，而我寫的誠實邊界說
/// 「涵蓋範圍等於那份清單」——**第二次把界線寫小了一級**（#44 R11 verify）。
private func swiftSourcesUnderSources(_ root: URL) throws -> [URL] {
    let sources = root.appendingPathComponent("Sources")
    guard
        let walker = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else {
        struct SourcesUnreadable: Error {}
        throw SourcesUnreadable()
    }
    return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

private func repositoryRootForWriteSites(file: StaticString = #filePath) throws -> URL {
    var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path)
        {
            return directory
        }
        directory = directory.deletingLastPathComponent()
    }
    struct RootNotFound: Error {}
    throw RootNotFound()
}
