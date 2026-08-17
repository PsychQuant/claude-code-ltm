import Foundation
import Testing

@testable import LTMCore

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
