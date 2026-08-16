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

@Test func anExistingWorldReadableStoreIsTightenedOnNextAppend() throws {
    // #1 verify R3：`open(..., O_CREAT, 0o600)` 的 mode 只在**新建**時生效。
    // 舊版建立、備份還原、或不同 umask 產生的既有 events.jsonl 會維持它原本的
    // mode，於是同機其他使用者讀得到全部 anchor 與互動歷史。原本的測試只驗
    // 新建的檔案，抓不到升級／還原情境。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-tighten-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("events.jsonl")

    // 模擬既有的 world-readable store。
    FileManager.default.createFile(atPath: url.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

    let store = try FileEventStore(url: url)
    try store.append(
        .interaction(
            .shown,
            anchor: Anchor(
                source: "fixture-a",
                turn: Turn(id: "t1", role: "user", timestamp: Date(), text: "合成文字內容"),
                span: 0..<4),
            at: Date(), generation: GenerationID("build-1"), policy: RankingPolicyID("archival")))

    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    #expect(perms & 0o077 == 0, "既有檔案未被收緊：\(String(perms, radix: 8))")
}

// 「非一般檔案要被拒絕」這條**現在有測試了**。
//
// 先前這裡寫著不寫測試的理由：「用 FIFO 當標的的話，`open(O_WRONLY)` 在沒有
// 讀者時會阻塞，測試會掛住而不是失敗」。**那個理由已經被同一輪的修復推翻**
// （#1 verify R5）：`append` 現在帶 `O_NONBLOCK`，無讀者 FIFO 的 open 會立刻
// 以 ENXIO 失敗。也就是說 R4 標為 CRITICAL 的 non-termination 修復本身，
// 讓「為什麼不能測」的理由失效了——而我沒有回頭把測試補上。
//
// 一般化的教訓：**「這條測不了」的理由要跟著實作一起複查。** 它在寫下的當下
// 可能是對的，而修掉那個原因的正是下一個 commit。

@Test(.timeLimit(.minutes(1))) func aFifoIsRejectedRatherThanBlockingForever() throws {
    // R4 的 CRITICAL：沒有 `O_NONBLOCK` 時，這一行會**永久阻塞**——生產路徑
    // 掛住而不是回錯。這條測試若回歸，症狀是測試套件跑不完，本身就是訊號。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-fifo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fifo = dir.appendingPathComponent("events.jsonl")
    #expect(mkfifo(fifo.path, 0o600) == 0, "mkfifo 失敗，這條測試沒測到東西")

    let store = try FileEventStore(url: fifo)
    #expect(throws: (any Error).self) {
        try store.append(
            .interaction(
                .shown, anchor: anchorForFifoTest(), at: Date(),
                generation: GenerationID("g1"), policy: RankingPolicyID("archival")))
    }
}

@Test(.timeLimit(.minutes(1))) func aFifoWithAReaderIsStillRejectedBecauseItIsNotARegularFile() throws {
    // 上一條走的是 ENXIO（沒有讀者）。這條先開一個非阻塞的讀端，讓 open 成功，
    // 於是真正走到 `enforceOwnerOnlyRegularFile` 的 `S_IFREG` 拒絕分支——
    // 那個分支先前同樣沒有任何測試覆蓋。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-fifo2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let fifo = dir.appendingPathComponent("events.jsonl")
    #expect(mkfifo(fifo.path, 0o600) == 0)

    let reader = open(fifo.path, O_RDONLY | O_NONBLOCK)
    #expect(reader >= 0, "讀端開不起來，這條測試沒走到 S_IFREG 分支")
    defer { close(reader) }

    let store = try FileEventStore(url: fifo)
    #expect(throws: (any Error).self) {
        try store.append(
            .interaction(
                .shown, anchor: anchorForFifoTest(), at: Date(),
                generation: GenerationID("g1"), policy: RankingPolicyID("archival")))
    }
}

private func anchorForFifoTest() -> Anchor {
    Anchor(
        source: "fixture-a",
        turn: Turn(id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 1), text: "合成文字"),
        span: 0..<4)
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


// MARK: - 存放目錄的權限（#1 verify R5）

@Test func aWorldWritableDirectoryWithoutStickyBitIsRejected() throws {
    // 檔案 0o600 在一個誰都能寫的目錄裡保護不了什麼：別人換掉整個檔案即可。
    // 先前權限檢查只在 append 裡、只看檔案本身。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-perm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o777])

    #expect(throws: (any Error).self) {
        _ = try FileEventStore(url: dir.appendingPathComponent("events.jsonl"))
    }

    // 對照：收緊之後可以建。沒有這條，一個無條件拒絕也能讓上面變綠。
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(throws: Never.self) {
        _ = try FileEventStore(url: dir.appendingPathComponent("events.jsonl"))
    }
}

@Test func aStickyWorldWritableDirectoryIsAccepted() throws {
    // `/tmp` 是 1777——sticky 讓非擁有者無法 unlink 別人的檔案，所以那個組合
    // 是可接受的。沒有這個例外，任何直接放在 /tmp 的 store 都會被拒絕。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-sticky-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o1777])
    #expect(throws: Never.self) {
        _ = try FileEventStore(url: dir.appendingPathComponent("events.jsonl"))
    }
}
