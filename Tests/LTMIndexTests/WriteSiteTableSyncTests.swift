import Foundation
import Testing

@testable import LTMIndex

/// `openDerivedFileNoFollow` 上方那張「derived root 底下每一個會改變檔案系統的
/// 站點」的表，宣稱自己完整——**而本 repo 的規則是：宣稱完整的列舉要附上證明它
/// 完整的檢查**（CLAUDE.md，這個 cluster 已經因為它出過七次錯）。
///
/// R9 的 codex 指出那張表沒有附查法，而同一輪的 security lens 與 DA 找到的
/// CRITICAL 正是**表底下那一行排除**（記憶層）——一個沒量過的「安全」判定。
/// 兩件事同源：一張沒有機制守著的表，它的邊界會安靜地錯。
///
/// 這條檢查是那個機制。它不聰明：掃 `Sources/LTMIndex` 與 `Sources/LTMMemory`
/// 裡會改變檔案系統的呼叫，數出來，與表宣告的數字比對。**新增一個寫入站點而
/// 沒更新表，它會紅。**
///
/// ## 誠實邊界
///
/// 它比對的是**數量**，不是身分——所以「換掉一個站點」它抓不到（那正是
/// `ProgressDocSyncTests` 早期版本的缺陷，而那條後來改成比對名字集合）。
/// 這裡沒有跟著做，理由是站點沒有像 enum case 那樣的穩定名字可比；**這是一個
/// 已知的較弱形式，不是疏漏**。它擋得住的是「加了一個沒進表的站點」，那是
/// R6→R9 每一輪都實際發生過的那一種。
@Test("derived 寫入站點的數量與表宣告的一致")
func theWriteSiteTableCountsEverySite() throws {
    let root = try repositoryRootForWriteSites()
    // 表裡宣告的數字。**改表就要改這裡，改這裡就要改表**——那正是這條檢查要
    // 強迫的那個動作。
    let declared = 13

    let patterns = [
        "openDerivedFileNoFollow(", "FileHandle(forWritingTo:", "FileHandle(forUpdating:",
        ".write(to:", "removeItem(", "replaceItemAt(", "createDirectory(",
        "sqlite3_open_v2(", "ftruncate(", "mkfifo(",
    ]
    var found = 0
    for module in ["LTMIndex", "LTMMemory"] {
        let dir = root.appendingPathComponent("Sources/\(module)")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // 註解不算——這張表自己就寫在註解裡，數它會自我指涉。
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                // helper 自身的宣告行不是站點——它是**所有走它的站點的實作**。
                guard !trimmed.hasPrefix("func openDerivedFileNoFollow") else { continue }
                if patterns.contains(where: { trimmed.contains($0) }) { found += 1 }
            }
        }
    }

    #expect(
        found == declared,
        "會改變檔案系統的呼叫有 \(found) 處，而表宣告 \(declared) 處——新增或移除站點時，那張表必須跟著改")
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
