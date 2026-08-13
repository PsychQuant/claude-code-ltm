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

/// 形狀合法的雜湊。用它當基準，才能讓「解碼失敗」歸因到我要測的那個欄位，
/// 而不是被別的欄位形狀先擋下來。
///
/// #1 verify R2（devils-advocate）指出：先前這幾條測試用 `"hex":"00"`，於是
/// 它們 throw 的原因其實是雜湊形狀不合法，**與它們宣稱要驗的自由文字無關**。
/// 測試名字比證據強，第二次犯同一類錯。
private let 合法雜湊 = String(repeating: "ab", count: 32)

@Test func decodingAnEventWhoseIdentifiersCarryFreeTextFails() {
    // 外來寫入者（或被竄改的備份）把原文塞進識別碼欄位。必須在解碼邊界被擋下，
    // 而不是原樣讀回來繼續流通。
    func hostile(generation: String) -> Data {
        Data("""
            {"kind":"opened","anchor":{"source":"s","turnID":"t1",
            "contentHash":{"hex":"\(合法雜湊)"},"span":[0,1]},
            "timestamp":0,"generation":"\(generation)","policy":"archival"}
            """.utf8)
    }

    // 先確認基準可解——否則下面的 throw 可能只是形狀問題。
    #expect(throws: Never.self) { _ = try JSONDecoder().decode(Event.self, from: hostile(generation: "build-1")) }
    // 只換掉 generation，其餘完全相同 → 失敗必然歸因於它。
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Event.self, from: hostile(generation: 原文)) }
}

@Test func decodingAnAnchorWhoseSourceCarriesFreeTextFails() {
    func hostile(source: String) -> Data {
        Data("""
            {"source":"\(source)","turnID":"t1",
            "contentHash":{"hex":"\(合法雜湊)"},"span":[0,1]}
            """.utf8)
    }

    #expect(throws: Never.self) { _ = try JSONDecoder().decode(Anchor.self, from: hostile(source: "fixture-a")) }
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Anchor.self, from: hostile(source: 原文)) }
}

@Test func contentHashRejectsFreeTextAtBothConstructionAndDecoding() {
    // R1 的加固逐一列舉了六個識別碼型別，**漏了這一個**——而它在每一筆 Event 裡。
    #expect(throws: ContentHash.ValidationError.self) { try ContentHash.validate(原文) }
    #expect(throws: ContentHash.ValidationError.wrongLength(2)) { try ContentHash.validate("00") }
    #expect(throws: ContentHash.ValidationError.self) { try ContentHash.validate(合法雜湊.uppercased()) }
    #expect(throws: Never.self) { try ContentHash.validate(合法雜湊) }

    // 解碼邊界同樣要擋——先前 Anchor.init(from:) 驗了 source/turnID 卻直接 decode 雜湊。
    let hostile = Data("""
        {"source":"s","turnID":"t1","contentHash":{"hex":"\(原文)"},
        "span":[0,1]}
        """.utf8)
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Anchor.self, from: hostile) }
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
