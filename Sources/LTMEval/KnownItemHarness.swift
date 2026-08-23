import Foundation
import LTMCore

/// 抽樣得到的一段語料：定址用的 anchor，加上要從中導出查詢的文字。
///
/// **這個型別只活在評估過程中**，不進任何紀錄。
public struct KnownItemSample: Sendable, Equatable {
    public let anchor: Anchor
    public let text: String

    public init(anchor: Anchor, text: String) {
        self.anchor = anchor
        self.text = text
    }
}

/// 可抽樣的語料。
///
/// ## 為什麼不是 `CorpusReader`
///
/// design 寫「taking a corpus reader」，而 `LTMCore.CorpusReader` 的唯一方法是
/// `turn(id:inSource:)`——**它只能依 id 查，不能列舉**，所以它結構上當不了抽樣
/// 的來源。這個 protocol 是同一個角色（「語料在評估這一側的介面」）的可列舉版本。
///
/// 索引本身不在 LTMEval 的依賴裡（LTMEval 只看得到 LTMCore／LTMMemory／LTMQuery），
/// 所以實作住在呼叫端——量測腳本用索引資料庫實作它。這讓 harness 可以用合成
/// 語料測試，而不必先建一份索引。
public protocol KnownItemCorpus: Sendable {
    /// 可抽樣的段數。
    var count: Int { get }
    /// 第 `index` 段。超出範圍回 `nil`。
    func sample(at index: Int) -> KnownItemSample?
}

/// 一次檢索的三軌結果，依名次排序（index 0 = 第 1 名）。
///
/// 三軌**同時**由一次檢索取得，而不是跑三次：三軌報告是一種報告形狀，不是三次
/// 獨立的評估（見 `ChannelBreakdown` 的說明）。
public struct ChannelRankings: Sendable, Equatable {
    public let lexical: [Anchor]
    public let vector: [Anchor]
    public let fused: [Anchor]

    public init(lexical: [Anchor], vector: [Anchor], fused: [Anchor]) {
        self.lexical = lexical
        self.vector = vector
        self.fused = fused
    }
}

/// 一個 (query class, channel) 格子的聚合。
///
/// **只有計數與比率，沒有任何來自語料的東西。** 這是本型別存在形狀的全部要求：
/// 產生器可以提交，它產生的 (查詢, gold) 對不可以。
public struct ChannelAggregate: Sendable, Equatable, Codable {
    /// 這一格總共評了幾對。
    public let scored: Int
    /// 其中 gold 落在 recall 視窗內的有幾對。
    public let recalled: Int
    /// 被 recall 到的那些對的 nDCG 總和。
    ///
    /// 存總和而不是平均，是為了讓跨格合併不必回頭找原始資料——平均不可加。
    public let ndcgSum: Double

    public init(scored: Int, recalled: Int, ndcgSum: Double) {
        self.scored = scored
        self.recalled = recalled
        self.ndcgSum = ndcgSum
    }

    /// recall 率。**分母為零時是 `nil` 而不是 0**——沿用 `StrategyScore.rate`
    /// 的同一條紀律：型別要能表達「這裡沒有數字」，否則消費端讀到的是一個
    /// 看起來很有信心的零。
    public var recallRate: Double? {
        scored == 0 ? nil : Double(recalled) / Double(scored)
    }

    /// **被 recall 到的那些對**的平均 nDCG。沒有被 recall 到的對不進這個平均——
    /// 兩階段指標的第二段只在第一段成立時有定義（見 `RecallNDCGOutcome`）。
    public var meanNDCGAmongRecalled: Double? {
        recalled == 0 ? nil : ndcgSum / Double(recalled)
    }

    func adding(_ outcome: RecallNDCGOutcome) -> ChannelAggregate {
        switch outcome {
        case .notRecalled:
            return ChannelAggregate(scored: scored + 1, recalled: recalled, ndcgSum: ndcgSum)
        case .recalled(let ndcg):
            return ChannelAggregate(
                scored: scored + 1, recalled: recalled + 1, ndcgSum: ndcgSum + ndcg)
        }
    }
}

/// 同一個 query class 底下三軌各自的聚合。
public struct ChannelAggregates: Sendable, Equatable, Codable {
    public let lexical: ChannelAggregate
    public let vector: ChannelAggregate
    public let fused: ChannelAggregate

    public init(lexical: ChannelAggregate, vector: ChannelAggregate, fused: ChannelAggregate) {
        self.lexical = lexical
        self.vector = vector
        self.fused = fused
    }

    static let empty = ChannelAggregates(
        lexical: ChannelAggregate(scored: 0, recalled: 0, ndcgSum: 0),
        vector: ChannelAggregate(scored: 0, recalled: 0, ndcgSum: 0),
        fused: ChannelAggregate(scored: 0, recalled: 0, ndcgSum: 0))

    func adding(_ breakdown: ChannelBreakdown) -> ChannelAggregates {
        ChannelAggregates(
            lexical: lexical.adding(breakdown.lexical),
            vector: vector.adding(breakdown.vector),
            fused: fused.adding(breakdown.fused))
    }
}

/// 一次 known-item 評估的完整產出。
///
/// ## 這裡沒有查詢，也沒有 gold 指標
///
/// 它們在評估過程中被用掉就丟了。committed 的是**產生器**與這份聚合，不是那些
/// 對——這正是「可重跑而不必存資料集」的做法，也是「不留 query 原文」這條政策
/// 的直接後果。
public struct KnownItemReport: Sendable, Equatable, Codable {
    /// 逐 query class 的三軌聚合。
    public let byQueryClass: [QueryClass: ChannelAggregates]
    /// 實際評到的對數。
    public let scored: Int
    /// 抽到但導不出可用查詢、因而跳過的段數。
    ///
    /// **必須出現在輸出上**：靜默跳過會讓有效樣本數與要求的樣本數不同，而讀者
    /// 不會知道。
    public let skipped: Int

    public init(byQueryClass: [QueryClass: ChannelAggregates], scored: Int, skipped: Int) {
        self.byQueryClass = byQueryClass
        self.scored = scored
        self.skipped = skipped
    }
}

/// 從語料抽樣、導出查詢、對三軌計分。
///
/// ## 為什麼查詢是「抽出來的」而不是真的查詢
///
/// 因為政策不留 query 原文，所以沒有真實查詢可以重放。known-item 的做法是：
/// 抽一段語料、從它的文字裡取一個子字串當查詢、把那一段當 gold。這讓 gold
/// 沒有歧義（就是那一段），代價是**這些查詢不代表真實查詢**——使用者不會把
/// 一段內文原封不動貼進搜尋框。這個限制必須寫進任何由它產生的紀錄。
public struct KnownItemHarness: Sendable {
    /// recall 判定的視窗（Recall@20）。
    public let recallK: Int
    /// nDCG 判定的視窗（nDCG@10）。
    public let ndcgK: Int

    public init(recallK: Int = 20, ndcgK: Int = 10) {
        self.recallK = recallK
        self.ndcgK = ndcgK
    }

    /// 跑一次評估。
    ///
    /// - Parameters:
    ///   - corpus: 抽樣來源。
    ///   - sampleSize: 要抽幾段。大於語料段數時抽滿為止。
    ///   - seed: 抽樣種子。**同一組 (語料, sampleSize, seed) 必須給出同一份聚合**
    ///     ——用 SplitMix64 而不是系統亂數，理由與 `InterleavingHarness.Side.balanced`
    ///     相同：實驗分派必須可重現，而 Swift 的 `Hashable`／系統 RNG 每次執行都
    ///     不一樣，於是重跑會換到另一組樣本而紀錄裡看不出發生過這件事。
    ///   - retrieve: 檢索入口。收查詢字串，回三軌名次。
    public func run(
        corpus: some KnownItemCorpus,
        sampleSize: Int,
        seed: UInt64,
        retrieve: (String) throws -> ChannelRankings
    ) throws -> KnownItemReport {
        var rng = SplitMix64(seed: seed)
        // 先取全部索引再 seeded shuffle：可重現，而且不會抽到重複的段。
        var order = Array(0..<corpus.count)
        order.shuffle(using: &rng)

        var byClass: [QueryClass: ChannelAggregates] = [:]
        var scored = 0
        var skipped = 0

        for index in order.prefix(sampleSize) {
            guard let sample = corpus.sample(at: index) else {
                skipped += 1
                continue
            }
            guard let query = Self.deriveQuery(from: sample.text, using: &rng) else {
                // 導不出可用查詢（太短、沒有可用的字元類別）。**數出來**。
                skipped += 1
                continue
            }
            let rankings = try retrieve(query)
            let breakdown = ChannelBreakdown(
                lexical: scoreRecallAndRanking(
                    retrieved: rankings.lexical, expected: sample.anchor,
                    recallK: recallK, ndcgK: ndcgK),
                vector: scoreRecallAndRanking(
                    retrieved: rankings.vector, expected: sample.anchor,
                    recallK: recallK, ndcgK: ndcgK),
                fused: scoreRecallAndRanking(
                    retrieved: rankings.fused, expected: sample.anchor,
                    recallK: recallK, ndcgK: ndcgK))
            let label = QueryClassifier.classify(query)
            byClass[label] = (byClass[label] ?? .empty).adding(breakdown)
            scored += 1
            // query 到此為止：它算完 label、送過檢索，沒有任何持有者。
        }

        return KnownItemReport(byQueryClass: byClass, scored: scored, skipped: skipped)
    }

    /// 從一段文字導出一個查詢。導不出來時回 `nil`（呼叫端負責計數）。
    ///
    /// 規則刻意簡單：先試連續漢字段的內部子字串，再試 ASCII 英數詞。兩者都取
    /// 不到就放棄——**不退化成「拿整段當查詢」**，那會讓 gold 幾乎必然排第一，
    /// 量到的是「完全比對能不能命中」而不是檢索品質。
    static func deriveQuery(from text: String, using rng: inout SplitMix64) -> String? {
        let characters = Array(text)

        // 連續漢字段。取長度 2–4 的內部子字串：與 #2 的量測用同一種取法，
        // 也剛好覆蓋 `QueryClass` 的三個中文桶。
        var runs: [[Character]] = []
        var current: [Character] = []
        for character in characters {
            if character.unicodeScalars.allSatisfy(isHan) {
                current.append(character)
            } else {
                if current.count > 2 { runs.append(current) }
                current = []
            }
        }
        if current.count > 2 { runs.append(current) }

        if !runs.isEmpty {
            let run = runs[Int(rng.next() % UInt64(runs.count))]
            // 子字串必須是**內部**的（長度小於整段），否則查詢等於 gold 的一整段。
            let maxLength = min(4, run.count - 1)
            let length = maxLength >= 2 ? 2 + Int(rng.next() % UInt64(maxLength - 1)) : 0
            if length >= 2 {
                let start = Int(rng.next() % UInt64(run.count - length + 1))
                return String(run[start..<(start + length)])
            }
        }

        // ASCII 英數詞，至少四個字元。
        let words = text.split(whereSeparator: { character in
            !character.unicodeScalars.allSatisfy(isASCIIAlphanumeric)
        }).map(String.init).filter { $0.count >= 4 }
        if !words.isEmpty {
            return words[Int(rng.next() % UInt64(words.count))]
        }
        return nil
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF: return true
        default: return false
        }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }
}

/// 可重現的 PRNG（SplitMix64）。
///
/// **不是系統亂數，也不是 `String.hashValue`。** 後者每個 process 隨機種子化，
/// 於是任何依賴它的抽樣在兩次執行之間會變動——而症狀不是「偶爾失敗」，是
/// 「偶爾成功」。這條教訓在 `Sources/LTMEval/Interleaving.swift` 與
/// `Tests/LTMServiceTests/LTMServiceTests.swift` 都記過，這裡是第三個要它的地方。
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
