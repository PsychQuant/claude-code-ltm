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
        source: ProjectFingerprint.of("-Users-a-proj"), turn: turn, span: 0..<6)
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
    let legacy = Anchor(source: "11111111-2222-3333-4444-555555555555", turn: turn, span: 0..<6)
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
    let current = Anchor(source: ProjectFingerprint.of("proj-one"), turn: turn, span: 0..<6)
    try store.append(Event(kind: .shown, anchor: current, timestamp: Date(timeIntervalSince1970: 10),
                           generation: GenerationID("g-1"), policy: RankingPolicyID("archival"),
                           noteRef: nil, presentation: nil))

    #expect(try store.allEvents().count == 1)
}
