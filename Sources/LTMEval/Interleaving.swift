import Foundation
import LTMCore
import LTMQuery

/// 交錯呈現的結果。
public struct Interleaving: Sendable, Equatable {
    public let presented: [Candidate]
    public let record: PresentationRecord
}

/// 交錯器的前提被違反。全部外顯，因為它們的舊行為是**掛住**而不是回錯。
public enum InterleavingViolation: Error, Sendable, Equatable {
    /// 候選清單裡有重複的 anchor。
    case duplicateCandidate(Anchor)
    /// 兩個被比較的策略有同一個識別碼。
    ///
    /// team-draft 的歸屬是**按策略識別碼**記的，所以 A 與 B 同 id 時每個位置
    /// 記給誰都一樣——報告會產出一份看似有結論、實際上什麼都沒量到的表
    /// （#1 verify R5）。這也涵蓋「同一策略配不同 bound」的情形：那**刻意**是
    /// 同一個 id（策略由訊號與條件定義、不由幅度定義），所以要拿兩個 bound
    /// 對打，得先讓報告能表達「同 id 不同設定」——那是 #16 的事，在那之前
    /// 這種比較必須失敗而不是靜默合併。
    case strategiesShareAnIdentifier(RankingPolicyID)
    /// 某個策略違反了 seam 的契約（非排列、跨帶、謊報位移…）。
    ///
    /// 為什麼要包一層而不是讓 `StrategyViolation` 直接往上拋：一次呈現同時跑
    /// 兩個策略，seam 的錯誤不含策略身分，報告讀者無從判斷該懷疑哪一邊。
    case strategyMisbehaved(policy: RankingPolicyID, violation: StrategyViolation)
}

/// 呼叫策略、驗排列性、並把違規轉譯成帶策略歸屬的錯誤。
///
/// ## 這裡的排列檢查被刪過一次，現在裝回來了
///
/// R4 刪掉它，理由是「`rerank` 是 extension 上的非 customization point，所有
/// 經由 protocol 的呼叫都必然通過 `RankingGuard.verifyPermutation`，所以交錯器
/// 再驗一次是驗不到東西的死碼」。**那句話是假的**（#1 verify R6 實測）：
/// `rerankChecked` 是 public requirement，而它收的 `ValidatedCandidates` 是可
/// 儲存、可轉手的 token，所以模組外可以完全繞過 `rerank`。
///
/// 一般化的教訓，值得記在這裡而不是只記在被推翻的那一段旁邊：
/// **不要因為「上游保證過了」而刪掉自己的檢查**，除非那個保證是型別層的
/// 不可達——而「不可達」這種宣稱本身要能被實測。這次刪掉防線的成本是：
/// 假宣稱失效的同時，它掩護的那道檢查也一起不見了。
private func ranking(
    from strategy: some MemoryStrategy, over candidates: [Candidate], with projection: Projection
) throws -> [Candidate] {
    do {
        let ranking = try strategy.rerank(candidates, with: projection).map(\.candidate)
        _ = try RankingGuard.verifyPermutation(original: candidates, reordered: ranking)
        return ranking
    } catch let violation as StrategyViolation {
        throw InterleavingViolation.strategyMisbehaved(policy: strategy.id, violation: violation)
    }
}

/// 兩策略比較的交錯器（team-draft）。
///
/// 為什麼是交錯而不是重放歷史查詢：不留 query 原文，就不可能把舊查詢重跑一次。
/// 交錯只需要已經同意記錄的事件（shown/opened/cited），代價是它只能比較「現在
/// 這兩個策略」，不能回溯比較。這個代價是隱私最小化的直接後果，不是疏忽。
public struct InterleavingHarness: Sendable {
    public enum Side: Sendable, Equatable, Codable {
        case a, b

        /// 由種子決定的平衡起手方。
        ///
        /// 存在的理由（#1 verify R4）：R3 拿掉 `startingSide` 的預設值，理由是
        /// 預設 `.a` 讓每次呈現都系統性偏向 A。那個診斷對，但修法只是把責任
        /// 推給呼叫端而沒有給它任何工具——**沒有平衡機制的「必須自己決定」，
        /// 最可能的結果是呼叫端自己寫死 `.a`**，偏誤原封不動。
        ///
        /// 用 FNV-1a 而不是 `hashValue`：Swift 的 `Hasher` 每個 process 隨機
        /// 種子化，同一個字串在兩次執行會得到不同雜湊。實驗分派必須可重現，
        /// 否則重跑報告會換到另一組起手方，而紀錄裡看不出發生過這件事。
        ///
        /// **不能直接取 FNV 的 bit 0**（#1 verify R5，logic 與 devils-advocate
        /// 各自量到）。FNV 的乘數是奇數，乘法保留最低位，所以
        /// `hash & 1 == 1 XOR (奇數位元組的個數 mod 2)`——整個函式退化成
        /// 「種子裡奇數位元組的個數的奇偶」。三個結構性質隨之出現：
        /// (1) 全由偶數位元組組成的種子**必定**落在同一側（實測 17/17）；
        /// (2) 對種子的任意重排不變（`balanced("ab") == balanced("ba")`）；
        /// (3) 插入或刪除任何偶數位元組不改變結果。
        /// 而示範用法是拿**查詢字串**當種子，所以互為重排的查詢、加了尾隨
        /// 空白的查詢，永遠分到同一側——分派規則在使用者最可能製造的近似
        /// 輸入上完全不去相關化，等於沒有平衡。
        ///
        /// 當時的測試 `aCount == 100`（200 個種子恰好各半）看起來是最強的證據，
        /// 其實是**症狀**：真雜湊出現剛好 100 的機率約 5.6%，而 parity 對
        /// `p0…p199` 這個家族必然給出 100。
        ///
        /// 修法是把 FNV 的輸出過一次雪崩化（splitmix64 的 finalizer）再取位元，
        /// 讓每個輸入位元都影響最低位。
        public static func balanced(seed: String) -> Side {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in seed.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= hash >> 33
            hash = hash &* 0xff51_afd7_ed55_8ccd
            hash ^= hash >> 33
            hash = hash &* 0xc4ce_b9fe_1a85_ec53
            hash ^= hash >> 33
            return hash & 1 == 0 ? .a : .b
        }
    }

    public let generation: GenerationID

    public init(generation: GenerationID) {
        self.generation = generation
    }

    /// 產生交錯清單與其紀錄。
    ///
    /// `query` 只用來算 class label，**不被保存**：出了這個函式，字串就沒有
    /// 任何持有者。
    ///
    /// `startingSide` **沒有預設值**，這是刻意的。team-draft 的起手方決定誰拿到
    /// 第 1 個位置，而第 1 個位置的點擊率遠高於其後——先前它預設 `.a`，於是
    /// 每一次呈現都系統性地偏向 A，比較實驗量到的一部分是位置效應而不是策略差異
    /// （#1 verify R3）。
    ///
    /// 但「拿掉預設值」只完成了一半（#1 verify R4）：它把責任推給呼叫端，卻
    /// 既沒給平衡機制、也沒把實際用了哪一邊記下來。前者見 `Side.balanced(seed:)`；
    /// 後者現在寫進 `PresentationRecord.startingSide`——**沒記下來的話，位置效應
    /// 連事後檢查都做不到**，而分派是否平衡正是最需要被檢查的東西。
    public func present(
        query: String,
        candidates: [Candidate],
        projection: Projection,
        a: some MemoryStrategy,
        b: some MemoryStrategy,
        startingSide: Side
    ) throws -> Interleaving {
        guard a.id != b.id else {
            throw InterleavingViolation.strategiesShareAnIdentifier(a.id)
        }
        let queryClass = QueryClassifier.classify(query)
        let presentationID = PresentationID.random()

        // 候選內的 anchor 必須唯一。不唯一時（例如 lexical 與 vector 兩路送了同一段
        // 而沒去重），下面的 `taken` 去重會讓可取出的相異 anchor 少於 count——
        // 舊版迴圈會因此在兩個 guard 之間無限翻面空轉、CPU 燒滿而不是回錯。
        // （#1 verify 2026-08-11，logic lens 實測 test bundle 掛住需 kill -9。）
        var seen: Set<Anchor> = []
        for candidate in candidates where !seen.insert(candidate.anchor).inserted {
            throw InterleavingViolation.duplicateCandidate(candidate.anchor)
        }

        let rankingA = try ranking(from: a, over: candidates, with: projection)
        let rankingB = try ranking(from: b, over: candidates, with: projection)

        // 兩邊排序一樣 → 這次呈現無法分辨任何差異。硬記給某一邊會憑空製造
        // 偏好，所以標成 null comparison 讓計分整批略過。
        if rankingA.map(\.anchor) == rankingB.map(\.anchor) {
            return Interleaving(
                presented: rankingA,
                record: try PresentationRecord(
                    id: presentationID,
                    queryClass: queryClass,
                    strategyA: a.id, strategyB: b.id,
                    generation: generation,
                    attribution: rankingA.map { AnchorAttribution(anchor: $0.anchor, creditedTo: nil) },
                    startingSide: startingSide,
                    isNullComparison: true))
        }

        var presented: [Candidate] = []
        var attribution: [AnchorAttribution] = []
        var taken: Set<Anchor> = []
        var indexA = 0
        var indexB = 0
        var turn = startingSide

        // 連續多少次翻面都沒取到東西。兩邊都取盡時它會到 2，迴圈結束——
        // 沒有這個計數器就沒有跳出路徑（見上方 duplicateCandidate 的說明）。
        var consecutiveEmptyTurns = 0

        while presented.count < candidates.count, consecutiveEmptyTurns < 2 {
            let (list, policy) = turn == .a ? (rankingA, a.id) : (rankingB, b.id)
            var cursor = turn == .a ? indexA : indexB
            while cursor < list.count, taken.contains(list[cursor].anchor) { cursor += 1 }
            if turn == .a { indexA = cursor } else { indexB = cursor }

            guard cursor < list.count else {
                // 這一邊已無未選項目，換另一邊繼續。
                consecutiveEmptyTurns += 1
                turn = turn == .a ? .b : .a
                continue
            }
            consecutiveEmptyTurns = 0

            let pick = list[cursor]
            taken.insert(pick.anchor)
            presented.append(pick)
            attribution.append(AnchorAttribution(anchor: pick.anchor, creditedTo: policy))
            turn = turn == .a ? .b : .a
        }

        return Interleaving(
            presented: presented,
            record: try PresentationRecord(
                id: presentationID,
                queryClass: queryClass,
                strategyA: a.id, strategyB: b.id,
                generation: generation,
                attribution: attribution,
                startingSide: startingSide,
                isNullComparison: false))
    }
}
