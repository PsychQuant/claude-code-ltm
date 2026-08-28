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
    var marked: Set<String> = []
    for file in try swiftSourcesUnderSources(root) {
        do {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("// WRITE-SITE:") else { continue }
                marked.insert(
                    trimmed.dropFirst("// WRITE-SITE:".count).trimmingCharacters(in: .whitespaces))
            }
        }
    }
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
/// 這一條掃會改變檔案系統的呼叫，要求每一個上方兩行內有 `// WRITE-SITE:`。
///
/// ## 誠實邊界（第三次寫，前兩次都把界線畫小了一級）
///
/// 前兩次的紀錄，因為它們是同一個錯的兩個變體：
///
/// 1. R10：說它「比對數量不比對身分」，而真相是**它連表都沒讀**。
/// 2. R11：說它「涵蓋範圍等於那份 primitive 清單」，而真相是清單 ∩ 兩個模組 ∩
///    非遞迴 ∩ 單行連續文字。三個額外的限制一個都沒寫出來，其中一個讓
///    **R10 用來殺死上一版的那個變異對新版照樣全綠**。
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
///
/// **為什麼不寫成性質**：「會改變檔案系統」在 Swift 型別層沒有表達方式。要真正
/// 關掉它需要 SwiftSyntax／lint 層的 AST 檢查，或禁止業務模組直接呼叫這些 API
/// 而強制走少數可稽核的 wrapper。**兩者都沒做，這是一個具名的未完成，不是邊界。**
@Test("每一個寫入 primitive 的呼叫都掛了 WRITE-SITE 標記")
func everyWritePrimitiveCarriesAMarker() throws {
    let root = try repositoryRootForWriteSites()
    // **`open(` 與 `write(` 在清單裡。** 上一版沒有它們，而它們是記憶層**實際
    // 使用**的寫入手段——`memory-prune-open` / `memory-append-open` / `lock-open`
    // / `derived-open-helper` 全部走它。更難看的是：R10 用來證明上一版檢查無效的
    // 那個變異，用的正是 `open(` / `write(`，而我把它們寫進了敘述、沒寫進清單，
    // 於是同一個變異對新版**照樣全綠**（#44 R11 verify，實測）。
    let primitives = [
        "FileHandle(forWritingTo:", "FileHandle(forUpdating:", ".write(to:",
        "removeItem(", "replaceItemAt(", "createDirectory(", "sqlite3_open_v2(",
        "ftruncate(", "mkfifo(", "openDerivedFileNoFollow(",
        "open(", "write(", "pwrite(", "truncate(", "rename(", "link(", "copyItem(",
        "moveItem(", "createFile(", "createSymbolicLink(",
    ]
    var unmarked: [String] = []
    var claimedMarkers: Set<String> = []
    for file in try swiftSourcesUnderSources(root) {
        do {
            let name = file.lastPathComponent
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // helper 自身的宣告不是站點，它是所有走它的站點的實作。
                guard !trimmed.hasPrefix("func openDerivedFileNoFollow") else { continue }
                guard primitives.contains(where: { trimmed.contains($0) }) else { continue }
                // **三類精確排除，逐條寫出理由——不是靠放寬誠實邊界。**
                //
                // 1. `O_RDONLY` 的 open：唯讀，不改變檔案系統。
                // 2. `.open(` 前面有點：那是 Swift 的方法名（`VectorSidecar.open`），
                //    不是 `open(2)`。`open(` 這個 pattern 抓不出這個差別。
                // 3. 寫到 stdout／stderr 的 `FileHandle.standard*.write`：那是串流，
                //    不是檔案系統。
                if trimmed.contains("O_RDONLY") { continue }
                if trimmed.contains(".open(") { continue }
                if trimmed.contains("FileHandle.standard") { continue }
                // 4. 函式**宣告**不是呼叫站點（`public static func open(url:…)`）。
                if trimmed.hasPrefix("func ") || trimmed.contains(" func ") { continue }
                // **每個標記只背書一個呼叫。** 三行視窗讓相鄰的第二個站點借用前一個
                // 站點的標記——實測形狀：
                //
                //     // WRITE-SITE: existing-open
                //     open(existingPath, O_WRONLY)
                //     open(newPath, O_WRONLY | O_CREAT, 0o600)   ← 借用上面那個標記
                //
                // 兩條檢查都綠：`marked` 沒有新名字，所以集合比對也不動
                // （#44 R14 verify，codex）。這不是「primitive 清單不完整」那條
                // 已承認的邊界——是連清單內、單行可見的 `open(` 都逃得掉。
                //
                // 改法：標記必須在呼叫的**正上方三行內**，而且**同一個標記不得
                // 背書兩個呼叫**——用過就從可用集合裡拿掉。
                let window = lines[max(0, index - 3)..<index]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let nearby = window.enumerated().compactMap { offset, line -> Int? in
                    line.hasPrefix("// WRITE-SITE:") ? max(0, index - 3) + offset : nil
                }
                // 找一個**還沒被用掉**的標記。
                if let claimable = nearby.first(where: { !claimedMarkers.contains("\(name):\($0)") }) {
                    claimedMarkers.insert("\(name):\(claimable)")
                    continue
                }
                unmarked.append("\(name):\(index + 1) \(trimmed.prefix(60))")
            }
        }
    }
    #expect(
        unmarked.isEmpty,
        "這些呼叫會改變檔案系統但沒掛 WRITE-SITE 標記：\n\(unmarked.joined(separator: "\n"))")
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
