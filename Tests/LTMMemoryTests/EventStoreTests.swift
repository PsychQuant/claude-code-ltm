import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

// 已知的合成字串。測試會在序列化輸出裡逐一搜尋這三者，全部必須 0 次命中。
private let 語料原文 = "標記某個節點然後做對照，這是合成語料裡不該外洩的一句話。"

private func tempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func anchor(_ text: String, id: String = "t1") -> Anchor {
    Anchor(
        source: ProjectFingerprint.of("fixture-a"),
        turn: Turn(id: id, role: "user", timestamp: Date(), text: text),
        span: 0..<min(10, text.unicodeScalars.count), key: .forTesting)
}

private let gen = GenerationID("build-1")
private let policy = RankingPolicyID("archival")

// MARK: - 3.2 序列化不得含任何原文

@Test func serializedStoreContainsNoVerbatimContent() throws {
    let store = try FileEventStore(url: try tempDir().appendingPathComponent("events.jsonl"))

    // **只有語料原文真的走過這條路**：它以「被雜湊」的形式進入 anchor，所以
    // 「它沒出現在輸出裡」是一個有內容的斷言。
    //
    // 查詢原文與 note 原文則**沒有任何參數收得下它們**。先前這條測試把三者
    // 一起斷言，於是其中兩條是空的——輸入從未包含的東西，輸出當然找不到
    // （#1 verify R4）。空斷言比沒有斷言更糟：它讓覆蓋率看起來是三倍。
    //
    // 那兩件事的真正證據在型別層，不在這裡：`note` 走 UUID storage
    // （`noteAndPresentationReferencesCannotExpressFreeTextAtAll`），而
    // 「沒有一個可序列化欄位收得下自由文字」由
    // `everyStringFieldInAnEncodedEventRejectsFreeText` 從編碼輸出導出欄位
    // 清單來驗——那條不會因為我想不到某個欄位而漏掉它。
    let a = anchor(語料原文)
    try store.append(.interaction(.shown, anchor: a, at: Date(), generation: gen, policy: policy))
    try store.append(.interaction(.opened, anchor: a, at: Date(), generation: gen, policy: policy))
    try store.append(.pin(anchor: a, at: Date(), generation: gen, policy: policy))

    let bytes = try store.serializedBytes()
    let text = String(decoding: bytes, as: UTF8.self)

    #expect(!text.contains(語料原文), "序列化輸出不得含語料原文")
    // 也不得含較長的子字串片段（防「只切掉尾巴就當作沒外洩」）。
    #expect(!text.contains("標記某個節點"))

    // 反向確認：指標與識別碼確實有被寫出去，否則上面的斷言可能只是因為檔案是空的。
    #expect(text.contains(a.contentHash.hex))
    #expect(text.contains("build-1"))
}

// MARK: - 3.3 append-only、順序、失敗外顯

@Test func rangeReadPreservesAppendOrder() throws {
    let store = try FileEventStore(url: try tempDir().appendingPathComponent("events.jsonl"))
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
    let store = try FileEventStore(url: try tempDir().appendingPathComponent("events.jsonl"))
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

    let store = try FileEventStore(url: dir.appendingPathComponent("events.jsonl"))
    #expect(throws: (any Error).self) {
        try store.append(
            .interaction(.shown, anchor: anchor(語料原文), at: Date(), generation: gen, policy: policy))
    }
}

@Test func corruptRecordSurfacesInsteadOfBeingSkipped() throws {
    let url = try tempDir().appendingPathComponent("events.jsonl")
    let store = try FileEventStore(url: url)
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

@Test func corruptLineCanBeIsolatedForRepairWithoutLosingTheRestOfTheStore() throws {
    // #1 verify R3：R2 的註解宣稱「補換行封口讓損壞侷限在那一筆」——**不成立**，
    // 因為讀取端對壞行 fail-loud，一行壞掉整份就讀不出來。封口只讓壞的範圍
    // 停在一行，沒讓資料救得回來。
    //
    // 真正讓「侷限」成立的是這條路徑：預設仍 fail-loud（不可重建的資料不該
    // 安靜地少讀幾筆），但修復情境可以明確要求跳過，並拿到跳過了哪幾行。
    let url = try tempDir().appendingPathComponent("events.jsonl")
    let store = try FileEventStore(url: url)
    try store.append(
        .interaction(.shown, anchor: anchor(語料原文, id: "t0"), at: Date(), generation: gen, policy: policy))

    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"kind\":\"truncated\n".utf8))  // 半行
    try handle.close()

    try store.append(
        .interaction(.cited, anchor: anchor(語料原文, id: "t2"), at: Date(), generation: gen, policy: policy))

    // 預設路徑：仍然整份失敗。
    #expect(throws: (any Error).self) { _ = try store.allEvents() }

    // 修復路徑：兩筆好的都救得回來，壞的那一行被具名回報。
    let salvaged = try store.allEvents(skippingUnusable: true)
    #expect(salvaged.events.count == 2)
    #expect(salvaged.corruptLines == [2])
    #expect(salvaged.events.map(\.anchor.turnID) == ["t0", "t2"])
}


@Test func corruptLineNumbersAreTrueFileLineNumbers() throws {
    // R5：`omittingEmptySubsequences: true` 讓回報的是「第幾個非空行」，於是每個
    // 空行都讓後面的行號往前偏。這個方法存在的全部理由是修復情境，而照著偏掉的
    // 行號去編輯檔案會刪錯紀錄。空行是可達的——錯誤路徑的 `terminatePartialLine`
    // 會補一個裸換行，而本 store 從未宣稱自己是唯一寫入者。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-lineno-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("events.jsonl")

    let good = String(decoding: try canonicalLineForLineNumberTest(), as: UTF8.self)
    // 第 1 行合法、第 2 行空、第 3 行合法、第 4 行空、第 5 行損壞。
    let contents = good + "\n\n" + good + "\n\n" + "{ 這不是合法 JSON\n"
    try Data(contents.utf8).write(to: path)

    let store = try FileEventStore(url: path)
    let result = try store.allEvents(skippingUnusable: true)
    #expect(result.events.count == 2)
    #expect(result.corruptLines == [5], "回報的必須是檔案第 5 行，不是第 3 個非空行")
}

/// 與隱私測試那條同形，複製一份以免跨檔耦合。
private func canonicalLineForLineNumberTest() throws -> Data {
    let a = Anchor(
        source: ProjectFingerprint.of("fixture-a"),
        turn: Turn(id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 1), text: "合成文字"),
        span: 0..<4, key: .forTesting)
    let e = Event.interaction(
        .shown, anchor: a, at: Date(timeIntervalSince1970: 12_345),
        generation: GenerationID("build-1"), policy: RankingPolicyID("archival"))
    return try CanonicalCoding.encoder.encode(e)
}


@Test(.timeLimit(.minutes(1))) func appendFailsRatherThanBlockingWhenTheLockIsHeld() throws {
    // R6：R5 加的 `flock` 沒有任何測試，而它當時用的是阻塞版 `LOCK_EX`——
    // 註解寫「取不到鎖就拋」，code 卻會無限期停在那裡。這條同時釘住兩件事：
    // 鎖真的存在（拿不到就失敗），以及**失敗而不是掛住**（時間上限在此）。
    //
    // `flock` 綁在 open file description 上，所以同一個 process 的第二個 fd
    // 會真的衝突——不需要 spawn 子行程。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-lock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("events.jsonl")
    FileManager.default.createFile(atPath: path.path, contents: Data())

    let holder = open(path.path, O_WRONLY)
    #expect(holder >= 0)
    defer { close(holder) }
    #expect(flock(holder, LOCK_EX | LOCK_NB) == 0, "沒拿到鎖的話這條測試什麼都沒測")

    let store = try FileEventStore(url: path)
    #expect(throws: (any Error).self) {
        try store.append(
            .interaction(
                .shown, anchor: anchorForLockTest(), at: Date(),
                generation: GenerationID("g1"), policy: RankingPolicyID("archival")))
    }

    // 放開之後必須恢復正常——沒有這條，一個「永遠失敗」的 append 也會通過上面。
    #expect(flock(holder, LOCK_UN) == 0)
    #expect(throws: Never.self) {
        try store.append(
            .interaction(
                .shown, anchor: anchorForLockTest(), at: Date(),
                generation: GenerationID("g1"), policy: RankingPolicyID("archival")))
    }
}

private func anchorForLockTest() -> Anchor {
    Anchor(
        source: ProjectFingerprint.of("fixture-a"),
        turn: Turn(id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 1), text: "合成文字"),
        span: 0..<4, key: .forTesting)
}

/// #42：讀取端逾時後**照讀**，而寫入端逾時後**失敗**——不對稱要兩邊都有執行點。
///
/// 上面那條釘住寫入端。沒有這一條，把讀取端也改成「逾時就拋」不會有任何測試
/// 變紅——而那個改動會讓一次進行中的 append 把整個查詢變成錯誤。
///
/// 這條測試會真的等滿約 2 秒（讀取端的重試上限），那是被測行為本身。
@Test(.timeLimit(.minutes(1))) func readingProceedsAfterTheLockWaitExpires() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-rlock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("events.jsonl")
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = try FileEventStore(url: path)
    try store.append(
        .interaction(
            .shown, anchor: anchorForLockTest(), at: Date(),
            generation: GenerationID("g1"), policy: RankingPolicyID("archival")))

    let holder = open(path.path, O_WRONLY)
    #expect(holder >= 0)
    defer { close(holder) }
    #expect(flock(holder, LOCK_EX | LOCK_NB) == 0, "沒拿到鎖的話這條測試什麼都沒測")

    // 前提對照：同樣被鎖住時，寫入端**會**失敗。兩條斷言擺在一起，不對稱才是
    // 被斷言的東西，而不是「讀取剛好會成功」。
    #expect(throws: (any Error).self) {
        try store.append(
            .interaction(
                .shown, anchor: anchorForLockTest(), at: Date(),
                generation: GenerationID("g1"), policy: RankingPolicyID("archival")))
    }
    #expect(throws: Never.self) {
        _ = try store.allEvents()
    }
}

// MARK: - 記憶層不得寫進語料（#44 R9 verify）

/// **`ltm memory --prune` 把 hard link 成 `events.jsonl` 的語料檔截成 0。**
///
/// 實測（R9，security lens 與 devil's advocate 各自重現）：
///
/// ```
/// BEFORE size=12510 nlink=2 ino=610865743
/// AFTER  size=0     nlink=2 ino=610865743     ← 同一個 inode
///   ✓ 已備份原檔：events.jsonl.bak-5CADB437
/// ```
///
/// **違反不變式 1，而且印的是「✓」。** 第二個傷害更難看：那份備份把語料的逐字
/// 內容原封不動寫進 `~/.claude-ltm/memory/`，而 CLAUDE.md 對記憶層的硬約束逐字
/// 寫著「如此它**即使被備份或同步**也不含第三方逐字內容」。
///
/// 這一格先前被我用「記憶層有自己的守衛與自己的威脅模型（#40）」排除在檢查表外
/// ——**那是一個沒有量過的「安全」判定**，比一個具名的未知更糟。
@Test("prune 不得截短 hard link 成 events.jsonl 的檔案")
func pruneRefusesAHardLinkedStore() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-mem-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let outsider = root.appendingPathComponent("outsider.jsonl")
    let payload = Data(repeating: 0x41, count: 2_048)
    try payload.write(to: outsider)

    let events = root.appendingPathComponent("events.jsonl")
    #expect(link(outsider.path, events.path) == 0, "前提：hard link 要建得起來")

    let store = try FileEventStore(url: events)
    #expect(throws: (any Error).self) { _ = try store.pruneUnusable() }
    #expect(try Data(contentsOf: outsider) == payload, "prune 截短了另一個名字持有的檔案")
}

/// symlink 版同理——`O_NOFOLLOW` 那一半。
@Test("prune 不得跟著 symlink 走")
func pruneRefusesASymlinkedStore() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-mem-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let outsider = root.appendingPathComponent("outsider.jsonl")
    let payload = Data(repeating: 0x41, count: 2_048)
    try payload.write(to: outsider)
    let events = root.appendingPathComponent("events.jsonl")
    try FileManager.default.createSymbolicLink(at: events, withDestinationURL: outsider)

    let store = try FileEventStore(url: events)
    #expect(throws: (any Error).self) { _ = try store.pruneUnusable() }
    #expect(try Data(contentsOf: outsider) == payload, "prune 跟著 symlink 走了")
}

/// append 那一半：`O_APPEND` 不截短，但把事件行 append 進語料仍然是寫進語料。
@Test("append 不得寫進 hard link 成 events.jsonl 的檔案")
func appendRefusesAHardLinkedStore() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-mem-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let outsider = root.appendingPathComponent("outsider.jsonl")
    let payload = Data(repeating: 0x41, count: 512)
    try payload.write(to: outsider)
    let events = root.appendingPathComponent("events.jsonl")
    #expect(link(outsider.path, events.path) == 0, "前提：hard link 要建得起來")

    let store = try FileEventStore(url: events)
    #expect(throws: (any Error).self) {
        try store.append(
            .interaction(
                .shown, anchor: anchor("內容"), at: Date(), generation: gen, policy: policy))
    }
    #expect(try Data(contentsOf: outsider) == payload, "append 把事件行寫進了別人的檔案")
}

/// `append` 的 symlink 那一半——`O_NOFOLLOW`。
///
/// R10 指出：`pruneUnusable` 的 symlink 版有測試，`appendLine` 的沒有
/// （拿掉它的 `O_NOFOLLOW`，512 條全綠）。同族的兩半只補了一半，這是這個
/// cluster 反覆出現的形狀。
@Test("append 不得跟著 symlink 走")
func appendRefusesASymlinkedStore() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-mem-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let outsider = root.appendingPathComponent("outsider.jsonl")
    let payload = Data(repeating: 0x41, count: 512)
    try payload.write(to: outsider)
    let events = root.appendingPathComponent("events.jsonl")
    try FileManager.default.createSymbolicLink(at: events, withDestinationURL: outsider)

    let store = try FileEventStore(url: events)
    #expect(throws: (any Error).self) {
        try store.append(
            .interaction(.shown, anchor: anchor("內容"), at: Date(), generation: gen, policy: policy))
    }
    #expect(try Data(contentsOf: outsider) == payload, "append 跟著 symlink 寫進了別人的檔案")
}
