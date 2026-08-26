import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

// #12：anchor 內容摘要改用 HMAC。這幾條鎖住的是**加密鑰真的有作用**——
// 一個「換了密鑰卻算出同樣摘要」的實作會讓整件事變成裝飾。

@Test("同一段文字、不同密鑰，摘要不同")
func differentKeysProduceDifferentDigests() {
    let a = AnchorKey(material: Data(repeating: 0x01, count: 32))
    let b = AnchorKey(material: Data(repeating: 0x02, count: 32))
    #expect(Anchor.hash("繼續", key: a) != Anchor.hash("繼續", key: b))
    // 而同一把密鑰必須穩定——否則 anchor 每次重算都變 orphan。
    #expect(Anchor.hash("繼續", key: a) == Anchor.hash("繼續", key: a))
}

@Test("拿別把密鑰解析 anchor 會是 orphan，不會誤判成命中")
func anAnchorDoesNotDereferenceUnderAnotherKey() {
    let turn = Turn(
        id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 0),
        text: "這段文字夠長，足以切出一個 span。")
    let corpus = KeyFixtureCorpus(turns: ["fixture-a": [turn.id: turn]])

    let mine = AnchorKey(material: Data(repeating: 0x11, count: 32))
    let theirs = AnchorKey(material: Data(repeating: 0x22, count: 32))
    let anchor = Anchor(source: "fixture-a", turn: turn, span: 0..<6, key: mine)

    // 這是這件事的**安全性質**：只拿到記憶層備份的人，即使有語料，也對不回內容。
    #expect(anchor.dereference(in: corpus, key: mine).resolvedText != nil)
    #expect(anchor.dereference(in: corpus, key: theirs).resolvedText == nil)
}

@Test("hex 解析拒絕壞輸入，而不是產生一把弱密鑰")
func hexParsingRejectsRatherThanDegrading() {
    #expect(AnchorKey(hex: String(repeating: "2a", count: 32)) != nil)
    #expect(AnchorKey(hex: "2a2") == nil, "奇數長度")
    #expect(AnchorKey(hex: String(repeating: "zz", count: 32)) == nil, "非十六進位")
    #expect(AnchorKey(hex: String(repeating: "2a", count: 16)) == nil, "只有 16 bytes，不足")
    // round-trip：匯出再匯入必須是同一把，否則遷移路徑是壞的。
    let key = AnchorKey.generate()
    #expect(AnchorKey(hex: key.hexEncoded) == key)
}

private struct KeyFixtureCorpus: CorpusReader {
    var turns: [String: [String: Turn]] = [:]
    func turn(id: String, inSource source: String) -> Turn? { turns[source]?[id] }
}
