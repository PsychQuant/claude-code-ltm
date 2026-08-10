import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

// 已知的合成字串。測試會在序列化輸出裡逐一搜尋這三者，全部必須 0 次命中。
private let 語料原文 = "標記某個節點然後做對照，這是合成語料裡不該外洩的一句話。"
private let 查詢原文 = "釘選版本 做比較"
private let note原文 = "這是使用者自己寫的 pin 註記，屬於自由文字。"

private func tempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func anchor(_ text: String, id: String = "t1") -> Anchor {
    Anchor(
        source: "fixture-a",
        turn: Turn(id: id, role: "user", timestamp: Date(), text: text),
        span: 0..<min(10, text.unicodeScalars.count))
}

private let gen = GenerationID("build-1")
private let policy = RankingPolicyID("archival")

// MARK: - 3.2 序列化不得含任何原文

@Test func serializedStoreContainsNoVerbatimContent() throws {
    let store = FileEventStore(url: try tempDir().appendingPathComponent("events.jsonl"))

    // 語料原文只以「被雜湊」的形式進入 anchor；查詢原文與 note 原文根本沒有
    // 可以傳進來的參數——這正是設計要的，測試只是把它釘死。
    _ = 查詢原文
    _ = note原文
    let a = anchor(語料原文)
    try store.append(.interaction(.shown, anchor: a, at: Date(), generation: gen, policy: policy))
    try store.append(.interaction(.opened, anchor: a, at: Date(), generation: gen, policy: policy))
    try store.append(.pin(anchor: a, at: Date(), generation: gen, policy: policy))

    let bytes = try store.serializedBytes()
    let text = String(decoding: bytes, as: UTF8.self)

    for 原文 in [語料原文, 查詢原文, note原文] {
        #expect(!text.contains(原文), "序列化輸出不得含原文：\(原文)")
    }
    // 也不得含任何較長的子字串片段（防「只切掉尾巴就當作沒外洩」）。
    #expect(!text.contains("標記某個節點"))
    #expect(!text.contains("釘選版本"))
    #expect(!text.contains("pin 註記"))

    // 反向確認：指標與識別碼確實有被寫出去，否則上面的斷言可能只是因為檔案是空的。
    #expect(text.contains(a.contentHash.hex))
    #expect(text.contains("build-1"))
}

// MARK: - 3.3 append-only、順序、失敗外顯

@Test func rangeReadPreservesAppendOrder() throws {
    let store = FileEventStore(url: try tempDir().appendingPathComponent("events.jsonl"))
    let base = Date(timeIntervalSince1970: 1_000_000)
    let kinds: [NonPinKind] = [.shown, .opened, .cited, .dismissed, .shown]

    for (i, kind) in kinds.enumerated() {
        try store.append(
            .interaction(
                kind, anchor: anchor(語料原文, id: "t\(i)"),
                at: base.addingTimeInterval(Double(i)), generation: gen, policy: policy))
    }

    let read = try store.events(from: base, to: base.addingTimeInterval(10))
    #expect(read.count == 5)
    #expect(read.map(\.kind) == kinds.map(\.eventKind))
    #expect(read.map(\.anchor.turnID) == ["t0", "t1", "t2", "t3", "t4"])
}

@Test func rangeReadIsBoundedByTimestamp() throws {
    let store = FileEventStore(url: try tempDir().appendingPathComponent("events.jsonl"))
    let base = Date(timeIntervalSince1970: 1_000_000)
    for i in 0..<5 {
        try store.append(
            .interaction(
                .shown, anchor: anchor(語料原文, id: "t\(i)"),
                at: base.addingTimeInterval(Double(i)), generation: gen, policy: policy))
    }

    let middle = try store.events(
        from: base.addingTimeInterval(1), to: base.addingTimeInterval(3))
    #expect(middle.map(\.anchor.turnID) == ["t1", "t2"])  // 上界排除
}

@Test func appendToUnwritableLocationSurfacesFailure() throws {
    let dir = try tempDir()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

    let store = FileEventStore(url: dir.appendingPathComponent("events.jsonl"))
    #expect(throws: (any Error).self) {
        try store.append(
            .interaction(.shown, anchor: anchor(語料原文), at: Date(), generation: gen, policy: policy))
    }
}

@Test func corruptRecordSurfacesInsteadOfBeingSkipped() throws {
    let url = try tempDir().appendingPathComponent("events.jsonl")
    let store = FileEventStore(url: url)
    try store.append(
        .interaction(.shown, anchor: anchor(語料原文), at: Date(), generation: gen, policy: policy))
    // 模擬外來寫入者塞進一種本 schema 不認得的 kind。
    let foreign = #"{"kind":"bookmarked"}"# + "\n"
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(foreign.utf8))
    try handle.close()

    #expect(throws: (any Error).self) {
        _ = try store.events(from: .distantPast, to: .distantFuture)
    }
}
