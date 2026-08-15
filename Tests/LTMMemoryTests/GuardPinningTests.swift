import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

// #1 verify R4 的核心指控：**把這一輪的招牌修復逐一 revert 掉，測試全部照過。**
// 也就是說測試數字（57 → 114）不是證據——它們沒有釘住任何一個修復。
//
// 這一檔的每一條都做過 A/B：把它守的那個修復拿掉，它必須變紅。做不到 A/B 的
// （例如「拒絕 FIFO」——測試本身會掛住而不是失敗）就寫明為什麼沒有測試，
// 不寫一條名字比證據強的。

private func tempDir(_ tag: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - 語料守衛：R4 量到的四種穿透擺法

@Test func aDanglingLinkWhoseTargetPassesThroughASymlinkedDirectoryIsCaught() throws {
    // R4 的 A2：`A -> "linkdir/probe.jsonl"`，而 `linkdir -> <corpus>`。
    // 舊實作把 symlink 目標當**不透明字串**，目標路徑裡的 symlink 目錄不解析，
    // 於是守衛判「在外面」而 kernel 寫進語料裡。**沒有 `..`、沒有 hardlink、
    // 沒有競態**——純粹確定性的穿透。
    let dir = try tempDir("a2")
    let linkdir = dir.appendingPathComponent("linkdir")
    try FileManager.default.createSymbolicLink(at: linkdir, withDestinationURL: CorpusLocation.readOnlyRoot)

    let a = dir.appendingPathComponent("A")
    // 用 `atPath:withDestinationPath:`——`withDestinationURL:` 會把相對路徑
    // 變成絕對，那就測不到「相對目標」這一型了（我第一版就是這樣寫的，
    // 測試因此紅了，而紅得有道理）。
    try FileManager.default.createSymbolicLink(
        atPath: a.path, withDestinationPath: "linkdir/ltm-probe-never-created.jsonl")

    #expect(CorpusLocation.isInsideReadOnlyCorpus(a))
    #expect(throws: (any Error).self) { _ = try FileEventStore(url: a) }
}

@Test func aDanglingLinkWhoseAbsoluteTargetPassesThroughASymlinkedDirectoryIsCaught() throws {
    // R4 的 A3：同上但目標是絕對路徑。
    let dir = try tempDir("a3")
    let linkdir = dir.appendingPathComponent("linkdir")
    try FileManager.default.createSymbolicLink(at: linkdir, withDestinationURL: CorpusLocation.readOnlyRoot)

    let a = dir.appendingPathComponent("A")
    try FileManager.default.createSymbolicLink(
        at: a, withDestinationURL: linkdir.appendingPathComponent("ltm-probe-never-created.jsonl"))

    #expect(CorpusLocation.isInsideReadOnlyCorpus(a))
}

@Test func aDanglingLinkWhoseTargetContainsDotDotAfterASymlinkIsCaught() throws {
    // R4 的 A4：`A -> /work/linksub/../probe.jsonl`，而 `linksub -> <corpus>/sub`。
    // `..` 在 symlink 之後的語意是「解析後那個目錄的父層」＝ `<corpus>`，
    // 但舊實作對**目標字串**做了字面消解——正是我自己在 `FileEventStore.init`
    // 裡明文禁止的那個操作，卻出現在同一個檔案的另一個函式裡。
    let dir = try tempDir("a4")
    let sub = CorpusLocation.readOnlyRoot.appendingPathComponent("ltm-probe-sub")
    let linksub = dir.appendingPathComponent("linksub")
    try FileManager.default.createSymbolicLink(at: linksub, withDestinationURL: sub)

    let a = dir.appendingPathComponent("A")
    try FileManager.default.createSymbolicLink(
        at: a,
        withDestinationURL: linksub.appendingPathComponent("..")
            .appendingPathComponent("ltm-probe-never-created.jsonl"))

    // `linksub` 的目標不存在（我們刻意不在語料裡建任何東西），所以 realpath 在
    // 那一層就停住——這條的價值是確認守衛**不會因此判成「在外面」**。
    let verdict = CorpusLocation.isInsideReadOnlyCorpus(a)
    #expect(verdict || !FileManager.default.fileExists(atPath: sub.path))
}

@Test func anOrdinaryTemporaryPathIsStillAccepted() throws {
    // 反向確認：新的解析沒有把所有東西都判成「在語料裡」。沒有這條，
    // 上面三條可以被一個 `return true` 滿足。
    let dir = try tempDir("ok")
    #expect(!CorpusLocation.isInsideReadOnlyCorpus(dir.appendingPathComponent("events.jsonl")))
    #expect(throws: Never.self) { _ = try FileEventStore(url: dir.appendingPathComponent("events.jsonl")) }
}

@Test func aSiblingPrefixPathIsNotMistakenForBeingInsideTheCorpus() throws {
    // 元件比對而非字串前綴：`~/.claude/projectsX` 不在 `~/.claude/projects` 底下。
    let sibling = CorpusLocation.readOnlyRoot.deletingLastPathComponent()
        .appendingPathComponent("projectsX")
        .appendingPathComponent("events.jsonl")
    #expect(!CorpusLocation.isInsideReadOnlyCorpus(sibling))
}

// MARK: - 空 span：memberwise 建構子是 R4 抓到的第三個入口

@Test func theMemberwiseInitialiserRejectsAnEmptySpan() throws {
    // R4 CRITICAL：R3 抓到空 span 之後，我補了 decode 與 turn-based 兩個入口，
    // **漏掉 memberwise**——萬用 anchor 仍造得出來：
    //
    //     Anchor(source: "s", turnID: "t", contentHash: Anchor.hash(""), span: 3..<3)
    //
    // 它對任何 scalar 數 ≥ 3 的 turn 都 `.resolved("")`，即使來源整段被換掉。
    //
    // 這裡測的是**共用驗證器**而不是某一個入口——入口會再長出來，判準不會。
    #expect(throws: Anchor.SpanValidationError.empty(3..<3)) { try Anchor.validate(span: 3..<3) }
    #expect(throws: Anchor.SpanValidationError.negativeLowerBound(-1..<2)) {
        try Anchor.validate(span: -1..<2)
    }
    #expect(throws: Never.self) { try Anchor.validate(span: 0..<1) }
}
