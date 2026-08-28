import Foundation
import Testing

@testable import LTMIndex

/// 那張「derived root 底下每一個會改變檔案系統的站點」的表，宣稱自己完整——
/// **而本 repo 的規則是：宣稱完整的列舉要附上證明它完整的檢查。**
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
/// 每個站點在原始碼裡掛一個 `// WRITE-SITE: <name>` 標記，表的第一欄就是那些
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
    for module in ["LTMIndex", "LTMMemory"] {
        let dir = root.appendingPathComponent("Sources/\(module)")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
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
/// ## 誠實邊界（這次要寫準——上一次我把它寫小了一級）
///
/// 它的涵蓋範圍**等於下面那份 primitive 清單**，不多也不少。一個用清單外的手段
/// 寫檔的新站點仍然隱形（例如 `FileManager.copyItem`、`link(2)`、`rename(2)`、
/// 或任何經由 `Process` 呼叫的外部程式）。**這不是「較弱的形式」，是一份會漏的
/// 列舉**——而本 repo 對會漏的列舉的處置是把判準寫成性質。這裡做不到：
/// 「會改變檔案系統」在 Swift 的型別層沒有表達方式，沒有 AST 工具就只能列舉。
///
/// 所以這條檢查買到的是：**清單內的手段一定要掛標記**。清單外的要靠人。
@Test("每一個寫入 primitive 的呼叫都掛了 WRITE-SITE 標記")
func everyWritePrimitiveCarriesAMarker() throws {
    let root = try repositoryRootForWriteSites()
    let primitives = [
        "FileHandle(forWritingTo:", "FileHandle(forUpdating:", ".write(to:",
        "removeItem(", "replaceItemAt(", "createDirectory(", "sqlite3_open_v2(",
        "ftruncate(", "mkfifo(", "openDerivedFileNoFollow(",
    ]
    var unmarked: [String] = []
    for module in ["LTMIndex", "LTMMemory"] {
        let dir = root.appendingPathComponent("Sources/\(module)")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where name.hasSuffix(".swift") {
            let lines = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // helper 自身的宣告不是站點，它是所有走它的站點的實作。
                guard !trimmed.hasPrefix("func openDerivedFileNoFollow") else { continue }
                guard primitives.contains(where: { trimmed.contains($0) }) else { continue }
                let window = lines[max(0, index - 2)..<index]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard !window.contains(where: { $0.hasPrefix("// WRITE-SITE:") }) else { continue }
                unmarked.append("\(name):\(index + 1) \(trimmed.prefix(60))")
            }
        }
    }
    #expect(
        unmarked.isEmpty,
        "這些呼叫會改變檔案系統但沒掛 WRITE-SITE 標記：\n\(unmarked.joined(separator: "\n"))")
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
