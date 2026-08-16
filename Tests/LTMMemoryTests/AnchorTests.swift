import Foundation
import Testing

@testable import LTMCore

/// 合成語料。測試一律不讀真實的 `~/.claude/projects/`——那是唯讀的第三方
/// 逐字內容，連讀進測試程序都不做。
struct FixtureCorpus: CorpusReader {
    var turns: [String: [String: Turn]] = [:]  // source → turnID → Turn

    func turn(id: String, inSource source: String) -> Turn? {
        turns[source]?[id]
    }

    static func single(_ turn: Turn, source: String = "fixture-a") -> FixtureCorpus {
        FixtureCorpus(turns: [source: [turn.id: turn]])
    }
}

let fixtureText = "標記某個節點然後做對照，這是範例的基準文字。再加一句讓 span 有東西可切。"

@Test func contentHashExcludesRoleAndTimestamp() {
    // 角色與時間戳不進雜湊：上游若編輯訊息 metadata，不該讓既有紀錄全部 orphan。
    let a = Turn(id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 0), text: fixtureText)
    let b = Turn(id: "t1", role: "assistant", timestamp: Date(timeIntervalSince1970: 999_999), text: fixtureText)

    let span = 0..<10
    #expect(Anchor(source: "fixture-a", turn: a, span: span).contentHash
        == Anchor(source: "fixture-a", turn: b, span: span).contentHash)
}

@Test func contentHashChangesOnSingleCharacterEdit() {
    let base = Turn(id: "t1", role: "user", timestamp: Date(), text: fixtureText)
    let edited = Turn(
        id: "t1", role: "user", timestamp: Date(),
        text: fixtureText.replacingOccurrences(of: "節點", with: "節奏"))

    let span = 0..<10
    #expect(Anchor(source: "s", turn: base, span: span).contentHash
        != Anchor(source: "s", turn: edited, span: span).contentHash)
}

@Test func dereferenceReturnsAddressedText() {
    let turn = Turn(id: "t1", role: "user", timestamp: Date(), text: fixtureText)
    let anchor = Anchor(source: "fixture-a", turn: turn, span: 3..<12)

    #expect(anchor.dereference(in: FixtureCorpus.single(turn))
        == .resolved(Anchor.normalize(Turn.slice(fixtureText, 3..<12))))
}

@Test func alteredSourceDereferencesAsOrphaned() {
    let turn = Turn(id: "t1", role: "user", timestamp: Date(), text: fixtureText)
    let anchor = Anchor(source: "fixture-a", turn: turn, span: 0..<10)

    let altered = Turn(
        id: "t1", role: "user", timestamp: Date(),
        text: "完全不同的一段文字，長度足夠讓 span 仍然合法而不會越界。")
    let result = anchor.dereference(in: FixtureCorpus.single(altered))

    // 必須指名是雜湊不符，而且不得回傳該位置上找到的文字。
    guard case .orphaned(let reason) = result else {
        Issue.record("預期 orphaned，實得 \(result)")
        return
    }
    guard case .contentHashMismatch(let expected, let found) = reason else {
        Issue.record("預期 contentHashMismatch，實得 \(reason)")
        return
    }
    #expect(expected == anchor.contentHash)
    #expect(found != anchor.contentHash)
    #expect(result.resolvedText == nil)
}

@Test func missingTurnIsOrphaned() {
    let turn = Turn(id: "t1", role: "user", timestamp: Date(), text: fixtureText)
    let anchor = Anchor(source: "fixture-a", turn: turn, span: 0..<10)

    #expect(anchor.dereference(in: FixtureCorpus()) == .orphaned(.turnMissing))
}

@Test func outOfBoundsSpanIsOrphanedNotACrash() {
    let turn = Turn(id: "t1", role: "user", timestamp: Date(), text: fixtureText)
    let anchor = Anchor(source: "fixture-a", turn: turn, span: 0..<10)

    let shortened = Turn(id: "t1", role: "user", timestamp: Date(), text: "短")
    #expect(anchor.dereference(in: FixtureCorpus.single(shortened)) == .orphaned(.spanOutOfBounds))
}


@Test func corpusTextEditedToWhitespaceOrphansRatherThanCrashing() {
    // #1 verify R7 的 CRITICAL（四個 lens 各自報，DA 以 A/B 量到 pre-R6 回
    // `.orphaned`）：R6 把「空內容摘要不得存在」做成 `ContentHash(hex:)` 的 trap，
    // 而 `dereference` 對**當下的語料文字**算雜湊——語料被編輯成純空白時，
    // 讀取路徑中止整個行程。語料不是我們能控制的輸入，而 spec 寫的是
    // 「Altered source text dereferences as orphaned」。
    let original = Turn(
        id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 1), text: "abcXYZdef")
    let anchor = Anchor(source: "fixture-a", turn: original, span: 3..<6)

    let edited = Turn(
        id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 1), text: "abc   def")
    let corpus = FixtureCorpus(turns: ["fixture-a": ["t1": edited]])

    #expect(anchor.dereference(in: corpus) == .orphaned(.contentNormalizesToNothing))
    // 對照：未編輯時照常 resolve，否則上面可能只是「永遠 orphan」。
    let intact = FixtureCorpus(turns: ["fixture-a": ["t1": original]])
    #expect(anchor.dereference(in: intact).resolvedText == "XYZ")
}
