import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

// `Anchor.source` 的值從 sessionId 換成 project 指紋（change
// `fix-band-semantics-and-turn-identity` task 2.1）。這一組釘住指紋本身的三個性質：
// 穩定、合法、不洩漏本機路徑。
//
// 為什麼需要指紋而不是直接存 project 名：實測 311 個 project 目錄有 173 個名稱
// 超過 64 字元，而 `OpaqueIdentifier` 的上限是 64。而且 project 目錄名是路徑轉寫
// （含使用者家目錄），直接存會把本機路徑寫進 canonical event store。

@Test("同一個 project 名永遠得到同一個指紋")
func fingerprintIsStable() {
    let name = "-Users-someone-Developer-some-project"
    #expect(ProjectFingerprint.of(name) == ProjectFingerprint.of(name))
}

@Test("不同 project 名得到不同指紋")
func fingerprintDiscriminates() {
    #expect(ProjectFingerprint.of("-Users-a-proj-one") != ProjectFingerprint.of("-Users-a-proj-two"))
}

@Test("指紋符合 OpaqueIdentifier 的形狀約束")
func fingerprintIsALegalIdentifier() throws {
    // 實測最長的 project 目錄名是 152 字元；指紋必須把它壓進 64 字元的上限內，
    // 且只用 ASCII 英數——否則 `Anchor` 的建構子會 trap。
    let long = String(repeating: "-Users-che-Developer-very-long-path", count: 8)
    let fingerprint = ProjectFingerprint.of(long)
    try OpaqueIdentifier.validate(fingerprint)
    #expect(fingerprint.count == 32)
    #expect(fingerprint.allSatisfy { $0.isHexDigit && !$0.isUppercase })
}

@Test("指紋不含原本的路徑片段")
func fingerprintLeaksNoPath() {
    // 這一條是隱私邊界：指紋會被寫進 canonical event store，而 project 目錄名
    // 是本機路徑的轉寫。
    let name = "-Users-che-Developer-claude-LTM"
    let fingerprint = ProjectFingerprint.of(name)
    for fragment in ["Users", "che", "Developer", "claude", "LTM"] {
        #expect(!fingerprint.lowercased().contains(fragment.lowercased()))
    }
}

@Test("指紋可以直接當 Anchor.source 用")
func fingerprintWorksAsAnchorSource() {
    let turn = Turn(
        id: "aaaaaaaa-0000-0000-0000-000000000001", role: "user",
        timestamp: Date(timeIntervalSince1970: 1), text: "合成的內容，長度足夠切出 span。")
    let anchor = Anchor(
        source: ProjectFingerprint.of("-Users-a-proj"), turn: turn, span: 0..<6, key: .forTesting)
    #expect(anchor.source.count == 32)
}

// MARK: - 事件層對舊規則 anchor 的具名拒絕（round-2 verify CRITICAL #1）
//
// 這一組原本被 task 2.3 宣稱存在，實際上沒有寫。索引層的拒絕有實作也有測試，
// 事件層兩者皆無 —— 而 memory-events spec 的 ADDED requirement 講的正是事件層。

@Test("當前規則的形狀判定：32 個小寫 hex")
func currentRuleShapeDiscriminates() {
    #expect(ProjectFingerprint.hasCurrentRuleShape(ProjectFingerprint.of("proj")))
    // 舊規則是 sessionId：36 字元、含連字號。
    #expect(!ProjectFingerprint.hasCurrentRuleShape("11111111-2222-3333-4444-555555555555"))
    #expect(!ProjectFingerprint.hasCurrentRuleShape("fixture-a"))
    #expect(!ProjectFingerprint.hasCurrentRuleShape(String(repeating: "A", count: 32)), "大寫不是當前形狀")
    #expect(!ProjectFingerprint.hasCurrentRuleShape(String(repeating: "a", count: 31)), "長度不符")
}

@Test("事件存放讀到舊規則 anchor 時具名拒絕，不重新詮釋")
func eventStoreRefusesSupersededAnchorRule() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-superseded-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try FileEventStore(url: dir.appendingPathComponent("events.jsonl"))

    let text = "被舊規則 anchor 指向的內容"
    let turn = Turn(id: "aaaaaaaa-0000-0000-0000-000000000001", role: "user",
                    timestamp: Date(timeIntervalSince1970: 1), text: text)
    // 用舊規則寫一筆：source 是 sessionId，不是指紋。
    let legacy = Anchor(source: "11111111-2222-3333-4444-555555555555", turn: turn, span: 0..<6, key: .forTesting)
    try store.append(Event(kind: .shown, anchor: legacy, timestamp: Date(timeIntervalSince1970: 10),
                           generation: GenerationID("g-1"), policy: RankingPolicyID("archival"),
                           noteRef: nil, presentation: nil))

    var thrown: Error?
    do { _ = try store.allEvents() } catch { thrown = error }
    guard case .some(EventStoreError.supersededAnchorRule(_, let lines)) =
        thrown as? EventStoreError
    else {
        Issue.record("舊規則 anchor 必須被具名拒絕，實際：\(String(describing: thrown))")
        return
    }
    #expect(lines == [1], "拒絕必須指名受影響的紀錄——spec 明寫 Refusal SHALL name the affected records")
}

@Test("當前規則的 anchor 照常讀得出來")
func eventStoreAcceptsCurrentRuleAnchors() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-current-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = try FileEventStore(url: dir.appendingPathComponent("events.jsonl"))

    let text = "當前規則 anchor 指向的內容"
    let turn = Turn(id: "aaaaaaaa-0000-0000-0000-000000000002", role: "user",
                    timestamp: Date(timeIntervalSince1970: 1), text: text)
    let current = Anchor(source: ProjectFingerprint.of("proj-one"), turn: turn, span: 0..<6, key: .forTesting)
    try store.append(Event(kind: .shown, anchor: current, timestamp: Date(timeIntervalSince1970: 10),
                           generation: GenerationID("g-1"), policy: RankingPolicyID("archival"),
                           noteRef: nil, presentation: nil))

    #expect(try store.allEvents().count == 1)
}

// MARK: - 舊規則紀錄的行號、修復路徑與非重新詮釋（round-3 verify HIGH）

private func supersededFixture() throws -> (URL, FileEventStore) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-sup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("events.jsonl")
    return (dir, try FileEventStore(url: url))
}

private func event(source: String, id: String) throws -> Event {
    let text = "被 anchor 指向的內容"
    let turn = Turn(id: id, role: "user", timestamp: Date(timeIntervalSince1970: 1), text: text)
    return try Event(
        kind: .shown, anchor: Anchor(source: source, turn: turn, span: 0..<6, key: .forTesting),
        timestamp: Date(timeIntervalSince1970: 10), generation: GenerationID("g-1"),
        policy: RankingPolicyID("archival"), noteRef: nil, presentation: nil)
}

@Test("舊規則紀錄回報的是**檔案行號**，空行不會讓它偏移")
func supersededLineNumbersAreTrueFileLineNumbers() throws {
    let (dir, store) = try supersededFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    let legacy = "11111111-2222-3333-4444-555555555555"

    // 手工鋪一份含空行的檔案：第 1 行合法、第 2 行空、第 3 行是舊規則。
    let good = String(
        decoding: try CanonicalCoding.encoder.encode(
            try event(source: ProjectFingerprint.of("proj"), id: "aaaaaaaa-0000-0000-0000-000000000001")),
        as: UTF8.self)
    let old = String(
        decoding: try CanonicalCoding.encoder.encode(
            try event(source: legacy, id: "aaaaaaaa-0000-0000-0000-000000000002")),
        as: UTF8.self)
    try Data((good + "\n\n" + old + "\n").utf8).write(to: store.url)

    var thrown: Error?
    do { _ = try store.allEvents() } catch { thrown = error }
    guard case .some(EventStoreError.supersededAnchorRule(_, let lines)) =
        thrown as? EventStoreError
    else {
        Issue.record("必須具名拒絕，實際：\(String(describing: thrown))")
        return
    }
    // 舊規則那筆是**第 3 行**。先前的實作對解碼後的陣列做 enumerated()，
    // 空行不入陣列，於是回報 2——照著它去編輯檔案會刪錯紀錄。
    #expect(lines == [3], "空行佔一個行號，這才是行號有意義的前提")
}

@Test("修復路徑跳過舊規則紀錄並回報，不把它原樣交出去")
func repairPathSkipsSupersededRatherThanReinterpreting() throws {
    let (dir, store) = try supersededFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try store.append(try event(source: ProjectFingerprint.of("proj"), id: "aaaaaaaa-0000-0000-0000-000000000001"))
    let good = try Data(contentsOf: store.url)
    let old = try CanonicalCoding.encoder.encode(
        try event(source: "11111111-2222-3333-4444-555555555555",
              id: "aaaaaaaa-0000-0000-0000-000000000002"))
    try (good + old + Data("\n".utf8)).write(to: store.url)

    let salvaged = try store.allEvents(skippingUnusable: true)
    #expect(salvaged.events.count == 1, "好的那一筆必須救得回來")
    #expect(salvaged.supersededLines == [2])
    #expect(salvaged.corruptLines.isEmpty, "舊規則紀錄不是損壞，兩類要分開報")
    #expect(
        salvaged.events.allSatisfy { ProjectFingerprint.hasCurrentRuleShape($0.anchor.source) },
        "spec 的主語是 reading——修復路徑也不得把舊規則 anchor 原樣交給呼叫端")
}

@Test("修剪之後歷史讀得回來，且只丟掉讀不回來的那些")
func rewriteKeepsUsableRecordsOnly() throws {
    let (dir, store) = try supersededFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try store.append(try event(source: ProjectFingerprint.of("proj"), id: "aaaaaaaa-0000-0000-0000-000000000001"))
    let good = try Data(contentsOf: store.url)
    let old = try CanonicalCoding.encoder.encode(
        try event(source: "11111111-2222-3333-4444-555555555555",
              id: "aaaaaaaa-0000-0000-0000-000000000002"))
    try (good + old + Data("\n".utf8) + Data("{壞掉的一行}\n".utf8)).write(to: store.url)

    // 修剪前：整份讀不出來。
    #expect(throws: (any Error).self) { _ = try store.allEvents() }

    let salvaged = try store.allEvents(skippingUnusable: true)
    #expect(salvaged.supersededLines == [2] && salvaged.corruptLines == [3])

    let pruned = try store.pruneUnusable()
    #expect(pruned.kept == 1)
    #expect(pruned.supersededLines == [2] && pruned.corruptLines == [3])

    // 修剪後：讀得回來，而且寫回去的東西自己通得過 canonical 往返檢查。
    #expect(try store.allEvents().count == 1)
    #expect(try store.allEvents(skippingUnusable: true).supersededLines.isEmpty)
}

@Test("修剪不換 inode——換掉會讓 append 的 flock 失效，並發寫入靜默消失")
func pruneKeepsTheInodeSoTheAppendLockStillMeansSomething() throws {
    let (dir, store) = try supersededFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    try store.append(
        try event(source: ProjectFingerprint.of("proj"), id: "aaaaaaaa-0000-0000-0000-000000000001"))
    let good = try Data(contentsOf: store.url)
    let old = try CanonicalCoding.encoder.encode(
        try event(source: "11111111-2222-3333-4444-555555555555",
                  id: "aaaaaaaa-0000-0000-0000-000000000002"))
    try (good + old + Data("\n".utf8)).write(to: store.url)

    func inode() throws -> UInt64 {
        let values = try store.url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        var info = stat()
        _ = values
        guard stat(store.url.path, &info) == 0 else { return 0 }
        return UInt64(info.st_ino)
    }
    let before = try inode()
    _ = try store.pruneUnusable()
    let after = try inode()

    // `flock` 綁在 inode 上。用 temp+rename 落地會換掉 inode，於是另一個行程持有
    // 的 `LOCK_EX` 變成守著一個已被 unlink 的舊 inode——它接下來的 write 沒有任何
    // 錯誤地消失。實測過：持鎖期間 replace 照樣成功。
    #expect(before == after && before != 0, "修剪必須就地覆寫，不得換 inode")
}

// 這裡曾經有一條 `pruneDoesNotSwallowConcurrentAppends`。它斷言的性質是對的，
// 但它**不可能失敗**：`pruneUnusable()` 沒有參數可以讓呼叫端交進一份過期的清單，
// 所以「用了過期清單」這個回歸在型別上就不可達。實測也確認了——我把寫入依據換成
// 鎖外先讀的快照，它照樣綠。
//
// 刪掉而不是留著：不可能失敗的測試在覆蓋率與閱讀上都算數，於是那個性質看起來
// 有人守。真正在守它的是**簽章**（沒有 `keeping:` 參數）與 `LOCK_EX` 內的重讀，
// 而型別層的保證比測試強。
//
// 要真的鎖住並發語意，需要一個在 prune 持鎖期間從另一條執行緒 append 的測試——
// 那會是時序相依的，而本 repo 已經有過「時序相依的測試變成偶爾成功」的代價
// （見 `deterministicSeed` 的註解）。目前選擇不寫，並把這個缺口寫在這裡。


@Test("全部紀錄都讀不回來時，修剪必須明示——那正是換代情境的預設情況")
func pruningEverythingNeedsAnExplicitDecision() throws {
    // anchor 定址規則換代之後，換代前寫的**每一筆**都是舊規則。所以「全部讀不回來」
    // 不是邊角情形，是主要觸發情境——而使用者是照著一個錯誤訊息的指示走到這裡的，
    // 那個訊息說的是「丟掉讀不回來的那些」，不是「清空歷史」。
    //
    // 實測過：先前 `ltm memory --prune` 在這個情境下把 1,425 bytes 的歷史清成 0，
    // 沒有任何確認，而互動提示同時寫著「保留其餘」——那裡沒有其餘。
    let (dir, store) = try supersededFixture()
    defer { try? FileManager.default.removeItem(at: dir) }
    var data = Data()
    for index in 1...3 {
        data.append(
            try CanonicalCoding.encoder.encode(
                try event(
                    source: "11111111-2222-3333-4444-555555555555",
                    id: String(format: "%08x-0000-0000-0000-000000000001", index))))
        data.append(Data("\n".utf8))
    }
    try data.write(to: store.url)

    // store 層照樣做它該做的（它不管 UI 決策）——這條測試釘的是**呼叫端必須看得見
    // 「一筆都不剩」這件事**：`kept == 0` 是那個決策的判準，所以它必須被回報。
    let survey = try store.allEvents(skippingUnusable: true)
    #expect(survey.events.isEmpty, "前提：全部都讀不回來")
    #expect(survey.supersededLines == [1, 2, 3])
}
