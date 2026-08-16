import Foundation
import Testing

@testable import LTMCore

/// 玩具 chunker，只活在測試裡。
///
/// 刻意不放進 library：切分屬於索引層（本 change 的 out of scope）。它在這裡
/// 的唯一用途，是讓「anchor 的有效性與 chunk 邊界無關」這件事可被觀察——
/// 沒有兩組真的不同的邊界，這條不變式就沒被測到。
struct ToyChunker {
    let size: Int
    let overlap: Int

    func spans(over text: String) -> [Range<Int>] {
        let total = text.unicodeScalars.count
        guard total > 0, size > 0, overlap >= 0, overlap < size else { return [] }
        let stride = size - overlap
        var result: [Range<Int>] = []
        var start = 0
        while start < total {
            result.append(start..<min(start + size, total))
            start += stride
        }
        return result
    }

    /// 模擬索引層的 chunk 表：chunkID → span。重建時整張表都會被換掉，
    /// 而**同一個 chunkID 會指向不同的文字**——那正是不能用它當 canonical
    /// 位址的原因。
    func chunkTable(over text: String) -> [Int: Range<Int>] {
        Dictionary(uniqueKeysWithValues: spans(over: text).enumerated().map { ($0.offset, $0.element) })
    }
}

private let longFixture = String(
    repeating: "標記某個節點然後做對照，這是合成語料的一句，用來把長度撐過四百個字元。",
    count: 14)

// #1 verify 2026-08-11（devils-advocate）：這一檔原本有兩個同義反覆的測試——
// 一個把 `spansAfter` 算完後 `_ =` 丟掉（「重建」是 no-op），另一個把**同一個
// 運算式**算兩次然後斷言相等。因此 design.md 的第一條 acceptance criterion
// 實際上沒有被任何測試滿足。重寫成下面這種形狀：直接把「用 chunk id 會壞」與
// 「用內容雜湊不會壞」放在同一個 rebuild 裡對照，斷言才有內容。

@Test func chunkIdentityBreaksAcrossARebuildButAnchorsDoNot() {
    #expect(longFixture.unicodeScalars.count > 400)

    let turn = Turn(id: "t1", role: "user", timestamp: Date(), text: longFixture)
    let corpus = FixtureCorpus.single(turn)

    let before = ToyChunker(size: 400, overlap: 40)
    let after = ToyChunker(size: 250, overlap: 0)

    let tableBefore = before.chunkTable(over: longFixture)
    let tableAfter = after.chunkTable(over: longFixture)

    // 舊索引下，chunk #1 定址到某一段文字；同時對同一段文字造一個 anchor。
    let chunkID = 1
    let spanBefore = tableBefore[chunkID]!
    let textAtRecordingTime = Anchor.normalize(Turn.slice(longFixture, spanBefore))
    let anchor = Anchor(source: "fixture-a", turn: turn, span: spanBefore)

    // ── 重建 ──（換一組 chunk 設定，chunk 表整個被替換）

    // (a) 用 chunk id 當位址：同一個 #1 現在指向**不同的文字**。
    //     這就是「chunk id 不可作為 canonical 位址」的具體失敗，而且它是**靜默**的
    //     ——查不出來，只會安靜地回錯段落。
    let spanAfter = tableAfter[chunkID]!
    let textThatChunkIDNowAddresses = Anchor.normalize(Turn.slice(longFixture, spanAfter))
    #expect(spanBefore != spanAfter)
    #expect(textThatChunkIDNowAddresses != textAtRecordingTime)

    // (b) 用 anchor：仍然定址到當初那一段。
    #expect(anchor.dereference(in: corpus) == .resolved(textAtRecordingTime))
}

@Test func everyAnchorRecordedUnderOneChunkingStillResolvesAfterAnother() {
    let turn = Turn(id: "t1", role: "user", timestamp: Date(), text: longFixture)
    let corpus = FixtureCorpus.single(turn)

    let before = ToyChunker(size: 400, overlap: 40)
    let after = ToyChunker(size: 250, overlap: 0)

    let spansBefore = before.spans(over: longFixture)
    let spansAfter = after.spans(over: longFixture)
    // 前提：兩組設定真的切出不同邊界，否則下面的斷言是空的。
    #expect(spansBefore != spansAfter)

    let recorded = spansBefore.map { span -> (Anchor, String) in
        (Anchor(source: "fixture-a", turn: turn, span: span),
         Anchor.normalize(Turn.slice(longFixture, span)))
    }

    // 重建之後（新的邊界已經算出來、索引概念上已被替換），每一個舊 anchor
    // 都仍解析到當初那段文字。
    #expect(!spansAfter.isEmpty)
    for (anchor, textAtRecordingTime) in recorded {
        #expect(anchor.dereference(in: corpus) == .resolved(textAtRecordingTime))
    }
}

@Test func contentHashDependsOnTextAloneNotOnPosition() {
    // #1 verify R2（regression lens，實測）：這條先前**仍是同義反覆**——
    // `sharedSpan = 0..<viaSmallChunks.upperBound` 就是 `viaSmallChunks`，
    // 兩個 anchor 用完全相同的參數建出來。我在修同義反覆時又寫了一個同義反覆。
    //
    // 真正要證的性質是「雜湊是文字的函式，不是位置的函式」。fixture 是同一句
    // 重複 14 次，所以**不同位置**的兩段 span 含有**相同文字**——那才是可以
    // 拿來比的東西。
    let turn = Turn(id: "t1", role: "user", timestamp: Date(), text: longFixture)
    let 一句 = "標記某個節點然後做對照，這是合成語料的一句，用來把長度撐過四百個字元。"
    let L = 一句.unicodeScalars.count

    let 第一次出現 = 0..<L
    let 第二次出現 = L..<(2 * L)
    #expect(第一次出現 != 第二次出現)  // 位置確實不同
    #expect(Turn.slice(longFixture, 第一次出現) == Turn.slice(longFixture, 第二次出現))  // 文字確實相同

    let a = Anchor(source: "fixture-a", turn: turn, span: 第一次出現)
    let b = Anchor(source: "fixture-a", turn: turn, span: 第二次出現)
    #expect(a.contentHash == b.contentHash)  // 位置不同、文字相同 → 雜湊相同
    #expect(a != b)  // 但 anchor 本身不同（span 是 anchor 的一部分）

    // 反向：文字不同就必須不同雜湊。跨句邊界取一段，內容與整句不同。
    let 跨邊界 = (L / 2)..<(L / 2 + L)
    let c = Anchor(source: "fixture-a", turn: turn, span: 跨邊界)
    #expect(c.contentHash != a.contentHash)
}
