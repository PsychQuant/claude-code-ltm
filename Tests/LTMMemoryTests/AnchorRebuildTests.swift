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

@Test func contentHashDependsOnTextAloneNotOnHowItWasSplit() {
    // 取代先前那個「同一個運算式算兩次」的空測試：真正該證明的是**同一段文字
    // 無論由哪一組切分產生，雜湊都相同**——所以用兩個不同 chunker 各自切出
    // 涵蓋同一 span 的結果來比。
    let turn = Turn(id: "t1", role: "user", timestamp: Date(), text: longFixture)

    let viaBigChunks = ToyChunker(size: 400, overlap: 40).spans(over: longFixture)[0]
    let viaSmallChunks = ToyChunker(size: 100, overlap: 0).spans(over: longFixture)[0]
    #expect(viaBigChunks != viaSmallChunks)  // 兩者確實不同

    // 對「同一段 span」而言，雜湊只由文字決定。用小 chunker 的邊界重造一個
    // 涵蓋相同範圍的 anchor，雜湊必須與大 chunker 那個相同。
    let sharedSpan = 0..<viaSmallChunks.upperBound
    let fromBig = Anchor(source: "fixture-a", turn: turn, span: sharedSpan)
    let fromSmall = Anchor(source: "fixture-a", turn: turn, span: viaSmallChunks)

    #expect(fromBig.contentHash == fromSmall.contentHash)
    #expect(fromBig.span == fromSmall.span)
}
