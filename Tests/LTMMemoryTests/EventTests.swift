import Foundation
import Testing

@testable import LTMCore

private func sampleAnchor() -> Anchor {
    Anchor(
        source: "fixture-a",
        turn: Turn(id: "t1", role: "user", timestamp: Date(), text: fixtureText),
        span: 0..<10, key: .forTesting)
}

private let gen = GenerationID("build-2026-08-10")
private let policy = RankingPolicyID("archival")

@Test func eventKindSetIsClosed() {
    #expect(EventKind.allCases.count == 5)
    #expect(Set(EventKind.allCases.map(\.rawValue))
        == ["shown", "opened", "cited", "pinned", "dismissed"])
    #expect(EventKind(rawValue: "bookmarked") == nil)
}

@Test func decodingAnUnknownKindFailsAndYieldsNoRecord() throws {
    // 型別層擋不到「別人寫進檔案的第六種 kind」——這才是封閉集合真正會被
    // 攻破的地方，所以斷言下在解碼邊界上。
    //
    // #1 verify R2：先前這條的 fixture 在 `contentHash`、`span`、`generation`
    // 三個欄位的形狀全都是錯的，所以它 throw 的原因根本不是 kind。加一條
    // **基準斷言**（只換 kind、其餘完全相同、且必須可解）才能讓歸因成立。
    func record(kind: String) -> Data {
        Data("""
            {"kind":"\(kind)","anchor":{"source":"s","turnID":"t1",
            "contentHash":{"hex":"\(String(repeating: "ab", count: 32))"},"span":[0,1]},
            "timestamp":0,"generation":"build-1","policy":"archival"}
            """.utf8)
    }

    #expect(throws: Never.self) { _ = try JSONDecoder().decode(Event.self, from: record(kind: "opened")) }

    var decoded: Event?
    #expect(throws: (any Error).self) {
        decoded = try JSONDecoder().decode(Event.self, from: record(kind: "bookmarked"))
    }
    #expect(decoded == nil)
}

@Test func pinNoteReferencesAreRandomNotContentDerived() {
    // note 原文根本到不了這一層——pin 事件只拿得到一個隨機 ref。所以「同樣的
    // note 內容」在 API 上不可表達，而這正是設計要的：內容雜湊可被字典攻擊
    // 還原短句。
    let anchor = sampleAnchor()
    let a = Event.pin(anchor: anchor, at: Date(), generation: gen, policy: policy)
    let b = Event.pin(anchor: anchor, at: Date(), generation: gen, policy: policy)

    #expect(a.noteRef != nil)
    #expect(a.noteRef != b.noteRef)
}

@Test func pinKindRequiresANoteReference() {
    #expect(throws: EventValidationError.pinRequiresNoteReference) {
        _ = try Event(
            kind: .pinned, anchor: sampleAnchor(), timestamp: Date(),
            generation: gen, policy: policy, noteRef: nil)
    }
}

@Test func nonPinKindsRejectANoteReference() {
    #expect(throws: EventValidationError.noteReferenceOnNonPinEvent) {
        _ = try Event(
            kind: .opened, anchor: sampleAnchor(), timestamp: Date(),
            generation: gen, policy: policy, noteRef: NoteReference.random())
    }
}

@Test func interactionEventsCarryPointersAndIdentifiersOnly() {
    let event = Event.interaction(
        .cited, anchor: sampleAnchor(), at: Date(), generation: gen, policy: policy)

    #expect(event.kind == .cited)
    #expect(event.generation == gen)
    #expect(event.policy == policy)
    #expect(event.noteRef == nil)
}


@Test func presentationIdentifiersAreContentIndependent() {
    // memory-events 的 scenario「Presentation identifier is content-independent」
    // 先前沒有任何測試（#1 verify R5）。它要防的是「用內容雜湊當 id」——
    // 短字串的雜湊可被字典攻擊還原，那等同把內容放進 canonical 層。
    //
    // 「content-independent」是**否定命題**，證不了；能證的是它的可觀察後果：
    // 同樣的輸入產生**不同**的識別碼，所以識別碼不是輸入的函數。
    let a = PresentationID.random()
    let b = PresentationID.random()
    #expect(a != b)

    let n = NoteReference.random()
    let m = NoteReference.random()
    #expect(n != m)

    // 而且型別上收不下內容：storage 是 UUID，沒有任何 initializer 接受字串。
    #expect(UUID(uuidString: a.description) != nil)
    #expect(UUID(uuidString: n.description) != nil)
}
