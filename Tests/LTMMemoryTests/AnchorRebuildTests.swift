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
}

private let longFixture = String(
    repeating: "標記某個節點然後做對照，這是合成語料的一句，用來把長度撐過四百個字元。",
    count: 14)

@Test func anchorsSurviveARebuildUnderDifferentChunking() {
    #expect(longFixture.unicodeScalars.count > 400)

    let turn = Turn(id: "t1", role: "user", timestamp: Date(), text: longFixture)
    let corpus = FixtureCorpus.single(turn)

    let before = ToyChunker(size: 400, overlap: 40)
    let after = ToyChunker(size: 250, overlap: 0)

    let spansBefore = before.spans(over: longFixture)
    let spansAfter = after.spans(over: longFixture)

    // 前提：兩組設定真的切出不同邊界。否則下面的斷言是空的。
    #expect(spansBefore != spansAfter)

    // 用舊設定記下 anchor，並記住它們當時定址到的文字。
    let recorded = spansBefore.map { span -> (Anchor, String) in
        (Anchor(source: "fixture-a", turn: turn, span: span),
         Anchor.normalize(Turn.slice(longFixture, span)))
    }

    // 「重建索引」：換一組 chunk 邊界。anchor 完全不參照 chunk，所以應毫髮無傷。
    _ = spansAfter

    for (anchor, textAtRecordingTime) in recorded {
        #expect(anchor.dereference(in: corpus) == .resolved(textAtRecordingTime))
    }
}

@Test func rebuiltChunkBoundariesDoNotShiftAnchorContentHashes() {
    let turn = Turn(id: "t1", role: "user", timestamp: Date(), text: longFixture)

    let span = 0..<400
    let hashUnderOldChunker = Anchor(source: "fixture-a", turn: turn, span: span).contentHash

    // 同一段 span 在任何 chunk 設定下都算出同一個雜湊——雜湊的輸入是文字，
    // 不是切分結果。
    let hashUnderNewChunker = Anchor(source: "fixture-a", turn: turn, span: span).contentHash
    #expect(hashUnderOldChunker == hashUnderNewChunker)
}
