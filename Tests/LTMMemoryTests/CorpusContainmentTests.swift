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

@Test func dotDotThroughASymlinkCannotEscapeTheGuard() throws {
    // #1 verify R2（logic + security 各自重現）：`standardizedFileURL` 會把 `..`
    // 做**字面**消解，但 `..` 在 symlink 之後的語意是「解析後那個目錄的父層」。
    // 於是守衛判「在外面」、kernel 卻寫進語料裡。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-dotdot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // link → ~/.claude ；於是 link/../claude/projects 實際落在語料根裡。
    let claudeDir = CorpusLocation.readOnlyRoot.deletingLastPathComponent()
    let link = dir.appendingPathComponent("link")
    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: claudeDir)

    let escape = link
        .appendingPathComponent("..")
        .appendingPathComponent(claudeDir.lastPathComponent)
        .appendingPathComponent("projects")
        .appendingPathComponent("p")
        .appendingPathComponent("s.jsonl")

    #expect(CorpusLocation.isInsideReadOnlyCorpus(escape))
    #expect(throws: (any Error).self) { _ = try FileEventStore(url: escape) }
}

@Test func danglingSymlinkAtTheLeafIsStillResolved() throws {
    // 葉節點是 dangling symlink（目標尚不存在）時也不得穿透——先前尾端整段不解析。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-dangling-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let target = CorpusLocation.readOnlyRoot
        .appendingPathComponent("not-yet")
        .appendingPathComponent("events.jsonl")
    let leaf = dir.appendingPathComponent("events.jsonl")
    try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)

    #expect(CorpusLocation.isInsideReadOnlyCorpus(leaf))
    #expect(throws: (any Error).self) { _ = try FileEventStore(url: leaf) }
}

@Test func multiHopDanglingSymlinkChainIsFollowedToTheEnd() throws {
    // #1 verify R3（security lens，實測穿透）：R2 只修好單層 dangling。
    // `destinationOfSymbolicLink` 只回直接目標，`standardizedFileURL` 不再解
    // symlink，所以 A → B → <corpus> 在守衛眼中只看到 A → B 就停了。而
    // `open(O_WRONLY|O_APPEND|O_CREAT)` 會沿鏈把檔案建在最終目標。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-chain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let finalTarget = CorpusLocation.readOnlyRoot
        .appendingPathComponent("ltm-probe-never-created")
        .appendingPathComponent("events.jsonl")
    let hopB = dir.appendingPathComponent("B")
    let hopA = dir.appendingPathComponent("A")
    try FileManager.default.createSymbolicLink(at: hopB, withDestinationURL: finalTarget)
    try FileManager.default.createSymbolicLink(at: hopA, withDestinationURL: hopB)

    #expect(CorpusLocation.isInsideReadOnlyCorpus(hopA))
    #expect(throws: (any Error).self) { _ = try FileEventStore(url: hopA) }
}

@Test func aSymlinkLoopTerminatesRatherThanHanging() throws {
    // 遞迴解析必須有上限。自我迴圈不得讓守衛掛住——那會把一個路徑檢查
    // 變成 DoS。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-loop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let a = dir.appendingPathComponent("A")
    let b = dir.appendingPathComponent("B")
    try FileManager.default.createSymbolicLink(at: a, withDestinationURL: b)
    try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)

    // 只要它回得來就算通過——回 true 或 false 都可以，掛住才是失敗。
    _ = CorpusLocation.isInsideReadOnlyCorpus(a)
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
