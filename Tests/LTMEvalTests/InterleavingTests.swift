import Foundation

extension Array where Element == Character {
    /// `abcde` 的全部 120 個排列。手寫遞迴而不是引入依賴。
    func permutationsOfFive() -> [String] {
        func permute(_ rest: [Character], _ prefix: [Character]) -> [[Character]] {
            if rest.isEmpty { return [prefix] }
            return rest.indices.flatMap { i -> [[Character]] in
                var remaining = rest
                let picked = remaining.remove(at: i)
                return permute(remaining, prefix + [picked])
            }
        }
        return permute(self, []).map { String($0) }
    }
}
import Testing

@testable import LTMCore
@testable import LTMEval
@testable import LTMQuery

let evalInstant = Date(timeIntervalSince1970: 4_000_000)
let evalGeneration = GenerationID("build-eval-1")

/// 測試裡用的查詢原文。序列化測試會在輸出裡搜尋它，必須 0 次命中。
let 查詢原文 = "釘選版本然後做比較"

func evalAnchor(_ id: String) -> Anchor {
    Anchor(
        source: "fixture-a",
        turn: Turn(id: id, role: "user", timestamp: Date(), text: "合成候選 \(id)，長度足夠切 span。"),
        span: 0..<8, key: .forTesting)
}

func evalCandidates(_ ids: [String]) -> [Candidate] {
    ids.enumerated().map {
        Candidate(anchor: evalAnchor($1), baseScore: 1 - Double($0) * 0.01, band: RelevanceBand(rank: 0))
    }
}

func evalProjection(_ entries: [(Anchor, [EventKind: Int])]) -> Projection {
    var stats: [Anchor: AnchorStatistics] = [:]
    for (anchor, counts) in entries {
        let cited: Int = counts[.cited] ?? 0
        let opened: Int = counts[.opened] ?? 0
        stats[anchor] = AnchorStatistics(
            reinforcement: Double(cited) * 2 + Double(opened),
            suppression: 0, impressions: 0,
            lastDeliberateInteraction: evalInstant, deliberateCounts: counts)
    }
    return Projection(statistics: stats, instant: evalInstant)
}

@Test func interleavedListContainsEachCandidateExactlyOnce() throws {
    let input = evalCandidates(["a", "b", "c", "d"])
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: 查詢原文, candidates: input,
        projection: evalProjection([(evalAnchor("d"), [.cited: 5])]),
        a: ArchivalStrategy(), b: HumanLikeStrategy(displacementBound: 3), startingSide: .a)

    #expect(result.presented.count == input.count)
    #expect(Set(result.presented.map(\.anchor)) == Set(input.map(\.anchor)))
}

@Test func everyPresentedPositionIsCreditedToExactlyOneStrategy() throws {
    let input = evalCandidates(["a", "b", "c", "d"])
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: 查詢原文, candidates: input,
        projection: evalProjection([(evalAnchor("d"), [.cited: 5])]),
        a: ArchivalStrategy(), b: HumanLikeStrategy(displacementBound: 3), startingSide: .a)

    // **只留載重的那一條。**（#1 verify R5）先前這裡還有兩句：
    // 「每個 attribution 的 creditedTo 非 nil」與「兩邊貢獻數加起來等於呈現
    // 長度」——兩者都由**同一次 `present()` 呼叫剛剛強制過**：
    // `PresentationRecord` 的建構子對「非 null 卻帶未歸屬 anchor」直接 throw，
    // 而 attribution 本來就是由 `presented` 逐位建出來的。形狀的強制由
    // `aNullComparisonCannotCarryAnAttributedAnchor` /
    // `aRealComparisonCannotCarryAnUnattributedAnchor` 直接覆蓋。
    //
    // 真正只有這裡驗得到的，是**兩邊都確實貢獻了位置**——也就是交錯真的在
    // 交錯，而不是整份來自同一邊。
    #expect(!result.record.isNullComparison)
    let credits = Set(result.record.attribution.compactMap(\.creditedTo))
    #expect(credits == [RankingPolicyID("archival"), RankingPolicyID("human-like")])
}

@Test func identicalRankingsYieldANullComparison() throws {
    let input = evalCandidates(["a", "b", "c"])
    // 沒有任何使用歷史 → human-like 與 archival 產生相同排序。
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: 查詢原文, candidates: input, projection: .empty(at: evalInstant),
        a: ArchivalStrategy(), b: HumanLikeStrategy(), startingSide: .a)

    #expect(result.record.isNullComparison)
    #expect(result.record.attribution.allSatisfy { $0.creditedTo == nil })
}

@Test func serializedPresentationRecordsContainNoQueryText() throws {
    let input = evalCandidates(["a", "b", "c", "d"])
    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: 查詢原文, candidates: input,
        projection: evalProjection([(evalAnchor("d"), [.cited: 5])]),
        a: ArchivalStrategy(), b: HumanLikeStrategy(displacementBound: 3), startingSide: .a)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(result.record)
    let text = String(decoding: bytes, as: UTF8.self)

    #expect(!text.contains(查詢原文))
    #expect(!text.contains("釘選"))
    #expect(!text.contains("比較"))

    // 四個該留的欄位確實有留——否則上面的斷言可能只是因為輸出是空的。
    #expect(text.contains("cjk-4plus"))  // class label
    #expect(text.contains("archival") && text.contains("human-like"))  // 策略對
    #expect(text.contains("build-eval-1"))  // generation
    #expect(text.contains("creditedTo"))  // 逐位歸屬
}

@Test func startingSideIsExplicitSoResultsAreReproducible() throws {
    let input = evalCandidates(["a", "b", "c", "d"])
    let projection = evalProjection([(evalAnchor("d"), [.cited: 5])])
    let harness = InterleavingHarness(generation: evalGeneration)

    let fromA = try harness.present(
        query: 查詢原文, candidates: input, projection: projection,
        a: ArchivalStrategy(), b: HumanLikeStrategy(displacementBound: 3), startingSide: .a)
    let fromB = try harness.present(
        query: 查詢原文, candidates: input, projection: projection,
        a: ArchivalStrategy(), b: HumanLikeStrategy(displacementBound: 3), startingSide: .b)

    #expect(fromA.record.attribution.first?.creditedTo == RankingPolicyID("archival"))
    #expect(fromB.record.attribution.first?.creditedTo == RankingPolicyID("human-like"))
}

// MARK: - 起手方：平衡機制與紀錄（#1 verify R4）

@Test func theStartingSideIsRecordedSoThePositionEffectStaysCheckable() throws {
    let input = evalCandidates(["a", "b", "c"])
    let projection = Projection(
        statistics: [evalAnchor("c"): AnchorStatistics(
            reinforcement: 5, suppression: 0, impressions: 0,
            lastDeliberateInteraction: evalInstant, deliberateCounts: [.cited: 5])],
        instant: evalInstant)

    for side in [InterleavingHarness.Side.a, .b] {
        let result = try InterleavingHarness(generation: evalGeneration).present(
            query: "測試", candidates: input, projection: projection,
            a: ArchivalStrategy(), b: HumanLikeStrategy(), startingSide: side)
        #expect(result.record.startingSide == side)
    }
}

@Test func balancedStartingSideIsReproducibleAcrossProcesses() {
    // **golden 值，刻意寫死。** 這條擋的是「有人把 FNV-1a 換成 `hashValue`」：
    // Swift 的 `Hasher` 每個 process 隨機種子化，換過去之後這些斷言會在**某些**
    // 執行失敗——而分派不可重現這件事本身不會有任何其他症狀。
    //
    // 兩個 golden 值刻意取不同側：全同側的 golden 會被一個常數函式滿足。
    #expect(InterleavingHarness.Side.balanced(seed: "presentation-0") == .a)
    #expect(InterleavingHarness.Side.balanced(seed: "presentation-5") == .b)
}

@Test func reorderingTheSeedChangesTheAssignmentForSomeInputs() {
    // **這條是 R5 那個缺陷的判別器。**
    //
    // 舊版取 FNV 的 bit 0，而 FNV 的乘數是奇數、乘法保留最低位，於是結果只
    // 取決於「奇數位元組的個數的奇偶」——那對種子的**任意重排不變**。
    // `abcde` 的 120 個排列在舊版下必然全部落在同一側；新版實測 67/120。
    //
    // 用排列而不是隨手挑兩個字串：單一 anagram 對在真雜湊下也有一半機率碰撞，
    // 那樣的測試會偶然通過。「120 個排列不得全部同側」則直接否證那個結構性質。
    let permutations = Array("abcde").permutationsOfFive()
    let sides = permutations.map { InterleavingHarness.Side.balanced(seed: $0) }
    #expect(sides.contains(.a) && sides.contains(.b), "重排種子不得完全不改變分派")
    let aCount = sides.count { $0 == .a }
    #expect((30...90).contains(aCount), "120 個排列的分派嚴重偏向一側：a=\(aCount)")
}

@Test func balancedStartingSideSplitsEvenlyAcrossStructurallyDifferentSeedFamilies() {
    // 平衡是這個機制存在的理由，所以要量而不是相信——**但要量多個結構不同的
    // 家族**。上一版只量 `p0…p199` 並斷言恰好 100/200，而那個「恰好」正是
    // parity 缺陷的症狀：換成同樣自然的 `p0, p2, p4…` 就是 200/0（R5 實測）。
    let families: [(String, [String])] = [
        ("連續序號", (0..<200).map { "p\($0)" }),
        ("偶數序號", (0..<200).map { "p\($0 * 2)" }),
        ("全偶位元組", ["b", "d", "f", "p", "t", "v", "x", "z", "0", "2", "4", "6", "8",
                        "bb", "dd", "x2", "p0"]),
        ("CJK", (0..<200).map { "查詢\($0)" }),
    ]
    for (name, seeds) in families {
        let aCount = seeds.count { InterleavingHarness.Side.balanced(seed: $0) == .a }
        let low = seeds.count / 4
        let high = seeds.count - low
        #expect(
            (low...high).contains(aCount),
            "家族「\(name)」分派偏向一側：a=\(aCount)/\(seeds.count)")
    }
}

// MARK: - 歸屬的形狀只有兩種（#1 verify R4）

@Test func aNullComparisonCannotCarryAnAttributedAnchor() {
    #expect(throws: PresentationRecord.ShapeViolation.nullComparisonWithAttributedAnchor(
        evalAnchor("a"))
    ) {
        _ = try PresentationRecord(
            id: .random(), queryClass: .cjk2char,
            strategyA: RankingPolicyID("archival"), strategyB: RankingPolicyID("human-like"),
            generation: evalGeneration,
            attribution: [AnchorAttribution(
                anchor: evalAnchor("a"), creditedTo: RankingPolicyID("archival"))],
            startingSide: .a, isNullComparison: true)
    }
}

@Test func aRealComparisonCannotCarryAnUnattributedAnchor() {
    // 混合形狀會讓 per-presentation rate 的分母沒有定義——spec 的全稱句與
    // null comparison 情境先前在字面上互斥，這條把封閉列舉釘成可執行的事實。
    #expect(throws: PresentationRecord.ShapeViolation.realComparisonWithUnattributedAnchor(
        evalAnchor("b"))
    ) {
        _ = try PresentationRecord(
            id: .random(), queryClass: .cjk2char,
            strategyA: RankingPolicyID("archival"), strategyB: RankingPolicyID("human-like"),
            generation: evalGeneration,
            attribution: [
                AnchorAttribution(anchor: evalAnchor("a"), creditedTo: RankingPolicyID("archival")),
                AnchorAttribution(anchor: evalAnchor("b"), creditedTo: nil),
            ],
            startingSide: .a, isNullComparison: false)
    }
}

// MARK: - query 真的沒有落地（#1 verify R4）

@Test func thePresentationRecordCarriesNoByteOfTheQuery() throws {
    // 取代 `classifierDoesNotRetainTheQuery` 的同義反覆版本：那條只證明分類器
    // 是確定性的，對「字串有沒有被留在別處」一無所知。這條把 query 真的送進
    // harness，再檢查**落地的 bytes**。
    let query = "釘選版本的比較實驗"
    let input = evalCandidates(["a", "b", "c"])
    let projection = Projection(
        statistics: [evalAnchor("c"): AnchorStatistics(
            reinforcement: 5, suppression: 0, impressions: 0,
            lastDeliberateInteraction: evalInstant, deliberateCounts: [.cited: 5])],
        instant: evalInstant)

    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: query, candidates: input, projection: projection,
        a: ArchivalStrategy(), b: HumanLikeStrategy(),
        startingSide: .balanced(seed: query))

    let bytes = try JSONEncoder().encode(result.record)
    let text = String(decoding: bytes, as: UTF8.self)

    #expect(!text.contains(query))
    #expect(!text.contains("釘選"))
    // 比子字串搜尋強的結構性質：紀錄的每一個 byte 都是 ASCII。本專案語料裡的
    // 第三方逐字內容幾乎必然含 CJK，所以這條把「原文外洩」從「我有沒有想到
    // 要搜這個字串」換成一個不依賴我想像力的性質。
    //
    // 誠實邊界：它擋不掉純 ASCII 的英文 query。那一側靠的是型別——紀錄的每個
    // 字串欄位不是識別碼字元集就是 UUID 或封閉集合標籤。
    #expect(bytes.allSatisfy { $0 <= 0x7F }, "紀錄含非 ASCII byte")
}


@Test func twoStrategiesWithTheSameIdentifierCannotBeCompared() {
    // R5：歸屬是按策略識別碼記的，同 id 時每個位置記給誰都一樣，報告會產出
    // 一份看似有結論、實際什麼都沒量到的表。這也涵蓋「同一策略配不同 bound」
    // ——那刻意是同一個 id，所以那種比較目前必須失敗而不是靜默合併（#16）。
    let input = evalCandidates(["a", "b"])
    #expect(throws: InterleavingViolation.strategiesShareAnIdentifier(
        RankingPolicyID("human-like"))
    ) {
        _ = try InterleavingHarness(generation: evalGeneration).present(
            query: "測試", candidates: input, projection: .empty(at: evalInstant),
            a: HumanLikeStrategy(displacementBound: 1),
            b: HumanLikeStrategy(displacementBound: 5), startingSide: .a)
    }
}


// MARK: - conservative 走完整條比較路徑（#1 verify R6）

@Test func conservativeWorksEndToEndThroughInterleavingAndScoring() throws {
    // R6：`conservative` 在整個測試套件裡**只當過反例**——沒有任何一條測試讓它
    // 走過交錯、呈現紀錄、計分。issue #1 要的是三檔並存且**可比較**，而
    // 「可比較」到目前為止只對另外兩檔驗過。
    //
    // 用全平手輸入，因為那是這一檔唯一會作用的情形；否則它與 archival 同序，
    // 交錯會退化成 null comparison 而什麼都測不到。
    let tied = (0..<4).map {
        Candidate(
            anchor: evalAnchor("t\($0)"), baseScore: 0.5, band: RelevanceBand(rank: 0))
    }
    let projection = evalProjection([(evalAnchor("t3"), [.cited: 9])])

    let result = try InterleavingHarness(generation: evalGeneration).present(
        query: "釘選版本", candidates: tied, projection: projection,
        a: ArchivalStrategy(), b: ConservativeStrategy(displacementBound: 3),
        startingSide: .balanced(seed: "conservative-e2e"))

    #expect(!result.record.isNullComparison, "全平手 + 有歷史時兩邊必須分歧")
    #expect(result.presented.count == tied.count)
    let credits = Set(result.record.attribution.compactMap(\.creditedTo))
    #expect(credits.contains(RankingPolicyID("conservative")))

    // 一路走到計分：conservative 貢獻的位置被點開時，分數要記到它頭上。
    let itsAnchor = result.record.attribution
        .first { $0.creditedTo == RankingPolicyID("conservative") }!.anchor
    let opened = Event.interaction(
        .opened, anchor: itsAnchor, at: evalInstant, generation: evalGeneration,
        policy: RankingPolicyID("conservative"), presentation: result.record.id)

    let report = try ComparisonScorer.report(records: [result.record], events: [opened])
    #expect(report.classRows.first?.scores[RankingPolicyID("conservative")]?.credits == 1)
}
