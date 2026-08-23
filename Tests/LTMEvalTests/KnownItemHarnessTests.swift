import Foundation
import Testing

@testable import LTMCore
@testable import LTMEval

// 全部走合成語料。

/// 沿用同 target 既有的 `evalAnchor`（`InterleavingTests.swift`）——anchor 的
/// 建構方式只該有一份，測試裡也一樣。
private func anchor(_ n: Int) -> Anchor {
    evalAnchor(String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", n))
}

/// 記憶體內的抽樣來源。
private struct StubCorpus: KnownItemCorpus {
    let samples: [KnownItemSample]
    var count: Int { samples.count }
    func sample(at index: Int) -> KnownItemSample? {
        samples.indices.contains(index) ? samples[index] : nil
    }
}

private func corpus(_ texts: [String]) -> StubCorpus {
    StubCorpus(
        samples: texts.enumerated().map { KnownItemSample(anchor: anchor($0.offset), text: $0.element) })
}

/// 每次都把 gold 排在指定名次的檢索——讓斷言下在**評分**上而不是檢索行為上。
private func rankingsPlacingEverythingAt(
    _ corpus: StubCorpus, lexical: Int?, vector: Int?, fused: Int?
) -> (String) throws -> ChannelRankings {
    let all = corpus.samples.map(\.anchor)
    func list(goldAt rank: Int?) -> [Anchor] {
        // 其餘位置用不會與 gold 相同的填充 anchor，讓名次可控。
        var out = (0..<25).map { anchor(1000 + $0) }
        if let rank, rank < out.count { out[rank] = all[0] }
        return out
    }
    return { _ in
        ChannelRankings(
            lexical: list(goldAt: lexical), vector: list(goldAt: vector), fused: list(goldAt: fused))
    }
}

// MARK: - 任務 4.1：抽樣可重現

@Test("同一組 (語料, 樣本數, seed) 兩次跑出同一份聚合")
func theSameSeedReproducesTheSameAggregates() throws {
    let source = corpus([
        "記憶策略可插拔而檢索基線量測", "交錯呈現的紀錄與計分", "向量通道與斷詞通道",
        "內容定址而非位置定址", "可以遺忘不可以編造", "band 是相關度分層",
    ])
    let harness = KnownItemHarness()
    let retrieve = rankingsPlacingEverythingAt(source, lexical: nil, vector: 2, fused: 0)

    let first = try harness.run(corpus: source, sampleSize: 4, seed: 42, retrieve: retrieve)
    let second = try harness.run(corpus: source, sampleSize: 4, seed: 42, retrieve: retrieve)
    #expect(first == second)

    // 不同 seed 要真的抽到不同的東西，否則上面那條等式是空的。
    let other = try harness.run(corpus: source, sampleSize: 4, seed: 43, retrieve: retrieve)
    #expect(other.scored + other.skipped == 4)
}

// MARK: - 任務 4.2：回傳型別不帶任何語料衍生的文字

@Test("聚合序列化之後不含查詢、gold 指標或語料原文")
func theReportCarriesNoCorpusDerivedText() throws {
    let corpusText = "記憶策略可插拔而檢索基線量測"
    let source = corpus([corpusText, "交錯呈現的紀錄與計分", "向量通道與斷詞通道"])
    let harness = KnownItemHarness()

    // 把實際導出的查詢記下來——斷言要能指名它不在輸出裡，而不是泛泛地說「沒有原文」。
    var observed: [String] = []
    let report = try harness.run(corpus: source, sampleSize: 3, seed: 7) { query in
        observed.append(query)
        return ChannelRankings(lexical: [], vector: [], fused: [])
    }
    #expect(!observed.isEmpty)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let text = String(decoding: try encoder.encode(report), as: UTF8.self)
    for query in observed {
        #expect(!text.contains(query), "查詢原文不得出現在聚合裡：\(query)")
    }
    #expect(!text.contains(corpusText), "語料原文不得出現在聚合裡")
    for sample in source.samples {
        #expect(!text.contains(sample.anchor.turnID), "gold 指標不得出現在聚合裡")
    }
}

// MARK: - 任務 4.3：導不出查詢的樣本被跳過並計數

@Test("導不出可用查詢的段落被跳過，而且數字出現在輸出上")
func undeliverableSamplesAreCountedNotHidden() throws {
    // 第二、三段導不出查詢：漢字段不足三字（子字串必須是內部的），也沒有
    // 四字元以上的 ASCII 詞。
    let source = corpus(["記憶策略可插拔而檢索基線量測", "。。。", "ab cd"])
    let harness = KnownItemHarness()
    let report = try harness.run(corpus: source, sampleSize: 3, seed: 1) { _ in
        ChannelRankings(lexical: [], vector: [], fused: [])
    }
    #expect(report.skipped == 2, "跳過數必須算出來——不然有效樣本數會與要求的不同而讀者不知道")
    #expect(report.scored == 1)
    #expect(report.scored + report.skipped == 3)
}

// MARK: - 任務 4.4：三軌各自計分，且會分岔

@Test("同一對在三軌上得到各自的兩階段結果，方向與 spec 的例子相同")
func allThreeChannelsAreScoredAndCanDiverge() throws {
    // spec 的例子：lexical 沒 recall 到、vector 排第 3、fused 排第 1。
    let source = corpus(["記憶策略可插拔而檢索基線量測"])
    let harness = KnownItemHarness()
    let report = try harness.run(
        corpus: source, sampleSize: 1, seed: 5,
        retrieve: rankingsPlacingEverythingAt(source, lexical: nil, vector: 2, fused: 0))

    #expect(report.scored == 1)
    guard let aggregates = report.byQueryClass.values.first else {
        Issue.record("應該有一個 query class 的聚合")
        return
    }

    // lexical：gold 不在前 20 名 → notRecalled，**沒有**排序品質數字。
    #expect(aggregates.lexical.recalled == 0)
    #expect(aggregates.lexical.meanNDCGAmongRecalled == nil, "沒 recall 到就沒有 nDCG")
    #expect(aggregates.lexical.recallRate == 0)

    // vector：第 3 名（0-indexed 的 2）→ nDCG = 1/log2(4) = 0.5。
    #expect(aggregates.vector.recalled == 1)
    #expect(aggregates.vector.meanNDCGAmongRecalled == 0.5)

    // fused：第 1 名 → nDCG = 1。
    #expect(aggregates.fused.recalled == 1)
    #expect(aggregates.fused.meanNDCGAmongRecalled == 1.0)
}

@Test("分母為零的格子回 nil 而不是 0——「這裡沒有數字」要表達得出來")
func emptyCellsHaveNoRateRatherThanZero() {
    let empty = ChannelAggregate(scored: 0, recalled: 0, ndcgSum: 0)
    #expect(empty.recallRate == nil)
    #expect(empty.meanNDCGAmongRecalled == nil)
    // 有評到但一次都沒 recall 到：recall 率是真的 0，不是「沒有數字」。
    let missed = ChannelAggregate(scored: 5, recalled: 0, ndcgSum: 0)
    #expect(missed.recallRate == 0)
    #expect(missed.meanNDCGAmongRecalled == nil)
}

/// 導出的查詢必須是**內部**子字串，兩條路徑都要驗。
///
/// #33 verify（logic lens）：先前這條只餵一段中文，而中文永遠走漢字那條路徑
/// ——ASCII 那條完全沒被執行過，於是 `deriveQuery("tokenizer")` 回傳
/// `"tokenizer"`（整段）這件事，被一條名字宣稱在驗它的測試放過去了。
@Test(
    "導出的查詢是內部子字串，不是整段語料",
    arguments: ["記憶策略可插拔而檢索基線量測", "the tokenizer floor is three characters"])
func derivedQueriesAreProperSubstrings(text: String) {
    var rng = SplitMix64(seed: 99)
    for _ in 0..<50 {
        guard let query = KnownItemHarness.deriveQuery(from: text, using: &rng) else {
            Issue.record("這段文字必然導得出查詢")
            continue
        }
        #expect(query.count >= 2)
        #expect(query != text, "拿整段當查詢會讓 gold 幾乎必然排第一，量到的不是檢索品質")
        #expect(text.contains(query))
    }
}

@Test("整段就是單一個詞時導不出查詢——不硬造一個等於整段的查詢")
func aSingleWordChunkYieldsNoQuery() {
    var rng = SplitMix64(seed: 11)
    for text in ["tokenizer", "  embeddings  "] {
        #expect(
            KnownItemHarness.deriveQuery(from: text, using: &rng) == nil,
            "退化樣本應該回 nil 交給呼叫端計進 skipped：\(text)")
    }
}

