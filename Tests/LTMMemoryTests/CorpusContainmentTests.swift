import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

// 不變式 1：`~/.claude/projects/` 唯讀。#1 verify 指出，在 `FileEventStore(url:)`
// 吃任意 URL 的情況下，違反它的寫入路徑**就是公開 API 的一部分**——不是呼叫端
// 紀律問題。這一檔把那條不變式釘在建構子上。
//
// 這些測試不建立、不寫入、也不讀取真實語料；只檢查建構子的拒絕行為。

@Test func storeRefusesAPathInsideTheReadOnlyCorpus() {
    let inside = CorpusLocation.readOnlyRoot
        .appendingPathComponent("some-project")
        .appendingPathComponent("session.jsonl")

    #expect(throws: (any Error).self) {
        _ = try FileEventStore(url: inside)
    }
}

@Test func storeRefusesTheCorpusRootItself() {
    #expect(throws: (any Error).self) {
        _ = try FileEventStore(url: CorpusLocation.readOnlyRoot)
    }
}

@Test func storeRefusesASymlinkPointingIntoTheCorpus() throws {
    // 表面路徑在暫存目錄，實際指向語料根。只比字串會穿透，必須先解 symlink。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-symlink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let link = dir.appendingPathComponent("looks-innocent")
    try FileManager.default.createSymbolicLink(
        at: link, withDestinationURL: CorpusLocation.readOnlyRoot)

    #expect(throws: (any Error).self) {
        _ = try FileEventStore(url: link.appendingPathComponent("p").appendingPathComponent("s.jsonl"))
    }
}

@Test func storeAcceptsAPathOutsideTheCorpus() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-ok-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    #expect(throws: Never.self) {
        _ = try FileEventStore(url: dir.appendingPathComponent("events.jsonl"))
    }
}

@Test func memoryFileIsNotWorldReadable() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-perm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("events.jsonl")
    let store = try FileEventStore(url: url)

    try store.append(
        .interaction(
            .shown,
            anchor: Anchor(
                source: "fixture-a",
                turn: Turn(id: "t1", role: "user", timestamp: Date(), text: "合成文字內容"),
                span: 0..<4),
            at: Date(), generation: GenerationID("build-1"),
            policy: RankingPolicyID("archival")))

    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    // 記憶層是本專案唯一必須備份的資料，不該讓同機其他使用者讀得到。
    #expect(perms & 0o077 == 0, "權限為 \(String(perms, radix: 8))，group/other 不得有任何權限")
}
