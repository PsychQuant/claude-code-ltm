import Foundation
import Testing

// 零第三方依賴是隱私邊界的一部分：每一個套件依賴都是一條需要自己審的供應鏈，
// 而這個 repo 的語料含第三方逐字內容。這條約束靠 code review 記得是不可靠的
// ——review 會漏，測試不會。
//
// 檢查的是 `Package.swift` 的**宣告**而不是解析後的圖：`.package(` 出現在
// manifest 裡就是引入了一個外部來源，不論它後來有沒有被某個 target 用到。

@Test("Package.swift 不宣告任何第三方套件依賴")
func packageManifestDeclaresNoExternalDependencies() throws {
    let manifest = try packageManifestSource()
    // `.package(url:` / `.package(path:` / `.package(name:` 全部涵蓋——判準是
    // 「有沒有引入外部來源」，不是「用了哪一種寫法」。
    #expect(
        !manifest.contains(".package("),
        "Package.swift 出現 .package( —— 引入第三方依賴會擴大供應鏈審查面，而本專案的語料含第三方逐字內容")
}

@Test("ltm 是宣告出來的可執行產品")
func packageDeclaresLTMExecutable() throws {
    let manifest = try packageManifestSource()
    #expect(manifest.contains(#".executable(name: "ltm""#))
    #expect(manifest.contains(#".executableTarget(name: "ltm""#))
}

/// 從測試檔位置往上找 repo 根的 `Package.swift`。
///
/// 不用 cwd：`swift test` 的工作目錄不保證是 repo 根，而 `#filePath` 是編譯期
/// 就固定的絕對路徑。
private func packageManifestSource(file: StaticString = #filePath) throws -> String {
    var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    while directory.path != "/" {
        let candidate = directory.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return try String(contentsOf: candidate, encoding: .utf8)
        }
        directory = directory.deletingLastPathComponent()
    }
    throw PackageManifestNotFound()
}

private struct PackageManifestNotFound: Error {}
