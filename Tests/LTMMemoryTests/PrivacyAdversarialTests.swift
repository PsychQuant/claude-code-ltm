import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

// #1 verify 2026-08-11（devils-advocate + codex）：原本的隱私測試只證明了
// 「我挑的那幾個 fixture 字串沒出現在輸出裡」，那跟「沒有原文」是兩回事。
// DA 用公開 API 把整段語料原文寫進 canonical 檔並通過了既有測試。
//
// 這一檔改成**對抗式**：逐一嘗試把自由文字塞進每一個可序列化的識別碼欄位，
// 斷言建構或解碼失敗。測試的形狀從「搜尋輸出」換成「攻擊輸入」。

private let 原文 = "這是一段不該進入 canonical 層的第三方逐字內容"

@Test func identifierValidatorRejectsFreeText() {
    #expect(throws: OpaqueIdentifier.ValidationError.self) {
        try OpaqueIdentifier.validate(原文)
    }
    #expect(throws: OpaqueIdentifier.ValidationError.empty) {
        try OpaqueIdentifier.validate("")
    }
    #expect(throws: OpaqueIdentifier.ValidationError.self) {
        try OpaqueIdentifier.validate(String(repeating: "a", count: 65))
    }
    #expect(throws: OpaqueIdentifier.ValidationError.self) {
        try OpaqueIdentifier.validate("has space")
    }
    // 合法的識別碼形狀仍然通過。
    #expect(throws: Never.self) { try OpaqueIdentifier.validate("build-2026-08-11") }
    #expect(throws: Never.self) { try OpaqueIdentifier.validate("human-like") }
}

@Test func generationAndPolicyIdentifiersRejectFreeTextFromForeignData() {
    #expect(throws: OpaqueIdentifier.ValidationError.self) {
        _ = try GenerationID(validating: 原文)
    }
    #expect(throws: OpaqueIdentifier.ValidationError.self) {
        _ = try RankingPolicyID(validating: 原文)
    }
}

@Test func decodingAnEventWhoseIdentifiersCarryFreeTextFails() {
    // 外來寫入者（或被竄改的備份）把原文塞進識別碼欄位。必須在解碼邊界被擋下，
    // 而不是原樣讀回來繼續流通。
    let hostile = """
        {"kind":"opened","anchor":{"source":"s","turnID":"t1",
        "contentHash":{"hex":"00"},"span":{"lowerBound":0,"upperBound":1}},
        "timestamp":0,"generation":"\(原文)","policy":"archival"}
        """
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(Event.self, from: Data(hostile.utf8))
    }
}

@Test func decodingAnAnchorWhoseSourceCarriesFreeTextFails() {
    let hostile = """
        {"source":"\(原文)","turnID":"t1",
        "contentHash":{"hex":"00"},"span":{"lowerBound":0,"upperBound":1}}
        """
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(Anchor.self, from: Data(hostile.utf8))
    }
}

@Test func noteAndPresentationReferencesCannotExpressFreeTextAtAll() throws {
    // 這兩個型別的 storage 是 UUID——沒有任何 initializer 收得下字串，
    // 所以「塞原文」在型別層不可表達，不需要驗證邏輯。
    let ref = NoteReference.random()
    #expect(UUID(uuidString: ref.description) != nil)

    // 解碼路徑同樣只接受 UUID 形狀。
    let hostile = "\"\(原文)\""
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(NoteReference.self, from: Data(hostile.utf8))
    }
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(PresentationID.self, from: Data(hostile.utf8))
    }
}

@Test func serializedStoreContainsNoNonAsciiAtAll() throws {
    // 比「搜尋已知 fixture 字串」強的斷言：canonical 檔的每一個 byte 都必須是
    // ASCII。第三方逐字內容在本專案的語料裡幾乎必然含 CJK，所以這條把「原文
    // 外洩」從「我有沒有想到要搜這個字串」變成一個結構性質。
    //
    // 誠實邊界：它擋不掉純 ASCII 的英文原文。真正的結構解是識別碼字元集 +
    // UUID storage（上面幾條測的就是那個）；這條是額外的一層。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-privacy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try FileEventStore(url: dir.appendingPathComponent("events.jsonl"))

    let anchor = Anchor(
        source: "fixture-a",
        turn: Turn(id: "t1", role: "user", timestamp: Date(), text: 原文),
        span: 0..<8)
    try store.append(
        .interaction(
            .cited, anchor: anchor, at: Date(),
            generation: GenerationID("build-1"), policy: RankingPolicyID("human-like")))
    try store.append(
        .pin(
            anchor: anchor, at: Date(),
            generation: GenerationID("build-1"), policy: RankingPolicyID("human-like")))

    let bytes = try store.serializedBytes()
    let nonASCII = bytes.filter { $0 > 0x7F }
    #expect(nonASCII.isEmpty, "canonical 檔出現 \(nonASCII.count) 個非 ASCII byte")
}
