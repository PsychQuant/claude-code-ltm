import Foundation
import Testing

@testable import LTMCore
@testable import LTMEval
@testable import LTMMemory

// 全部走合成語料。真實 `~/.claude/projects/` 一次都沒被碰到。

/// 帶**現行規則**指紋的 anchor。
///
/// 同 target 的 `evalAnchor` 用 `source: "fixture-a"`——那不是現行規則的形狀
/// （32 個小寫十六進位字元），所以它在這裡用不得：本檔要驗的正是「舊規則被拒」，
/// 而拿一個本來就不合規的 fixture 去驗，會讓兩條測試都通過而其中一條什麼都沒驗到。
private func currentRuleAnchor(_ n: Int) -> Anchor {
    Anchor(
        source: ProjectFingerprint.of("proj-one"),
        turn: Turn(
            id: String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", n),
            role: "user", timestamp: Date(timeIntervalSince1970: 1_755_400_000),
            text: "合成候選 \(n)，長度足夠切 span。"),
        span: 0..<8, key: .forTesting)
}

/// 帶**舊規則** source（sessionId）的 anchor。
private func supersededAnchor(_ n: Int) -> Anchor {
    Anchor(
        source: "11111111-2222-3333-4444-555555555555",
        turn: Turn(
            id: String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", n),
            role: "user", timestamp: Date(timeIntervalSince1970: 1_755_400_000),
            text: "合成候選 \(n)，長度足夠切 span。"),
        span: 0..<8, key: .forTesting)
}

/// 確定性的 `PresentationID`——不是 `random()`。
///
/// 斷言要能指名「救回來的是哪幾筆」，而隨機 id 只能斷言筆數。理由與
/// `InterleavingHarness.Side.balanced` 用 SplitMix64 相同：可重現的實驗分派。
private func presentationID(_ n: Int) -> PresentationID {
    PresentationID(id: UUID(uuidString: String(format: "%08x-0000-4000-8000-000000000000", n))!)
}

private func record(_ n: Int, anchors: [Anchor]) throws -> PresentationRecord {
    try PresentationRecord(
        id: presentationID(n), queryClass: .cjk2char,
        strategyA: RankingPolicyID("archival"), strategyB: RankingPolicyID("human-like"),
        generation: GenerationID("g-0000000000000000"),
        attribution: anchors.map { AnchorAttribution(anchor: $0, creditedTo: nil) },
        startingSide: .a, isNullComparison: true)
}

private func makeStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-pres-\(UUID().uuidString)")
        .appendingPathComponent("presentations.jsonl")
}

// MARK: - #36 階段 2：呈現紀錄的可修復性

@Test("半截 append 之後，預設讀取仍然 fail-loud——不靜默少讀")
func aTruncatedLineMakesTheDefaultReadFail() throws {
    let url = makeStoreURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = try FilePresentationRecordStore(url: url)
    try store.append(try record(1, anchors: [currentRuleAnchor(0)]))
    try store.append(try record(2, anchors: [currentRuleAnchor(1)]))
    // 第三筆寫到一半就中斷——`CanonicalStore.appendLine` 的封口緩解涵蓋不了
    // 行程在 write 中途被殺的情形。
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"id":"p-3","queryCla"#.utf8))
    try handle.close()

    // `EventStoreError` 不 `Equatable`，所以斷言下在**解構出的內容**上——這比
    // `throws: EventStoreError.self` 強：後者連「拋對了型別但行號錯了」都會通過。
    var thrown: EventStoreError?
    do { _ = try store.allRecords() } catch let error as EventStoreError { thrown = error }
    guard case .corruptRecord(let path, let lineNumber) = thrown else {
        Issue.record("預期 corruptRecord，實得 \(String(describing: thrown))")
        return
    }
    #expect(path == url.path)
    #expect(lineNumber == 3, "行號要對得上檔案的第 3 行，不是「第 3 筆紀錄」")
}

@Test("修復模式救回其餘紀錄並回報跳過的行號——一行壞資料不再鎖死整份歷史")
func repairModeRecoversTheRestAndReportsTheLine() throws {
    let url = makeStoreURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = try FilePresentationRecordStore(url: url)
    try store.append(try record(1, anchors: [currentRuleAnchor(0)]))
    try store.append(try record(2, anchors: [currentRuleAnchor(1)]))
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    // **先寫一個空行，再寫壞行。**
    //
    // 這不是裝飾：沒有它，壞行的檔案行號（3）與「已收的紀錄數 + 1」（3）剛好
    // 相同，於是「行號用的是檔案行還是紀錄序」這個區別在斷言上看不出來——實測
    // 過：把 `index + 1` 換成 `result.count + 1`，四條測試零紅。
    //
    // 加一個空行之後兩者分岔（檔案第 4 行 vs 紀錄序 3）。使用者拿到行號的唯一
    // 用途是去編輯那個檔案，所以錯的那個值會讓他刪掉一筆好紀錄。事件檔那側踩過
    // 同一個坑（#1 verify R5）。
    try handle.write(contentsOf: Data("\n".utf8))
    try handle.write(contentsOf: Data("{\"id\":\"p-3\",\"queryCla\n".utf8))
    try handle.close()
    try store.append(try record(4, anchors: [currentRuleAnchor(3)]))

    let result = try store.allRecords(skippingUnusable: true)
    #expect(
        result.records.map(\.id) == [presentationID(1), presentationID(2), presentationID(4)],
        "壞掉的那一行前後的紀錄都要救得回來")
    #expect(
        result.corruptLines == [4],
        "行號要對得上**檔案的第 4 行**（空行也佔一行），不是「第 3 筆紀錄」")
    #expect(result.supersededLines.isEmpty)
}

@Test("舊定址規則寫的紀錄被具名拒絕，而且用真實檔案行號")
func supersededAnchorRuleRecordsAreNamed() throws {
    let url = makeStoreURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = try FilePresentationRecordStore(url: url)
    try store.append(try record(1, anchors: [currentRuleAnchor(0)]))
    try store.append(try record(2, anchors: [supersededAnchor(1)]))

    var thrown: EventStoreError?
    do { _ = try store.allRecords() } catch let error as EventStoreError { thrown = error }
    guard case .supersededAnchorRule(let path, let lineNumbers) = thrown else {
        Issue.record("預期 supersededAnchorRule，實得 \(String(describing: thrown))")
        return
    }
    #expect(path == url.path)
    #expect(lineNumbers == [2])

    // 修復模式一樣跳過它們，並與損壞行**分開**回報——處置不同：損壞的是壞資料，
    // 舊規則的是好資料但指向已經不成立的定址方式。
    let result = try store.allRecords(skippingUnusable: true)
    #expect(result.records.map(\.id) == [presentationID(1)])
    #expect(result.supersededLines == [2])
    #expect(result.corruptLines.isEmpty)
}

@Test("一筆紀錄裡任何一個 anchor 是舊規則，整筆就不可用")
func anyStaleAnchorMakesTheWholeRecordUnusable() throws {
    let url = makeStoreURL()
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let store = try FilePresentationRecordStore(url: url)
    // 混合：第一個 anchor 合規、第二個是舊規則。
    try store.append(try record(1, anchors: [currentRuleAnchor(0), supersededAnchor(1)]))

    // 這筆紀錄的用途是把事件歸屬到位置，而歸屬需要**每個** anchor 都解析得回去。
    // 部分解析等於部分歸屬，而部分歸屬的分母是錯的。
    let result = try store.allRecords(skippingUnusable: true)
    #expect(result.records.isEmpty, "部分可解析不等於可用")
    #expect(result.supersededLines == [1])
}
