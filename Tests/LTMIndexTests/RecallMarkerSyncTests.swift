import Foundation
import Testing

@testable import LTMIndex

/// proactive-recall-cued-hook 3.1：標記文字只能在一個地方——`RecallMarker`。
/// 寫端（`--format recall`）與讀端（chunker 排除）都引用它；字面散落兩處就是兩份會漂移的規格。
@Test("`ltm:recall` 這串字在 Sources/ 只出現在 RecallMarker.swift")
func recallMarkerLiteralLivesInOnePlace() throws {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
        directory = directory.deletingLastPathComponent()
        try #require(directory.path != "/")
    }
    let sources = directory.appendingPathComponent("Sources")
    let walker = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    var offenders: [String] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
        let text = try String(contentsOf: url, encoding: .utf8)
        for (index, line) in text.components(separatedBy: "\n").enumerated()
        where line.contains("ltm:recall") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            if url.lastPathComponent != "RecallMarker.swift" {
                offenders.append("\(url.lastPathComponent):\(index + 1)")
            }
        }
    }
    #expect(offenders.isEmpty, "標記字面散落在：\(offenders)")
    #expect(RecallMarker.open.hasPrefix(RecallMarker.openPrefix))
    #expect(RecallMarker.close == "<!-- /ltm:recall -->")
}
