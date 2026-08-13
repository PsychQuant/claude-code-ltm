import Foundation
import LTMCore

/// 有記憶的那一檔：被實際用過的東西在同一相關性帶內往上走。
///
/// 三個約束同時成立：
/// 1. 只在同一帶內動（帶是圍籬）。
/// 2. 每一筆的位移不超過 `displacementBound`。
/// 3. 只吃 deliberate 訊號——`shown` 不增強，否則會形成「出現過就更容易再出現」
///    的迴圈。
public struct HumanLikeStrategy: MemoryStrategy {
    public let id = RankingPolicyID("human-like")
    public let consumedSignals: Set<EventKind> = [.opened, .cited, .pinned, .dismissed]

    /// 一筆結果最多能移動幾個名次。
    ///
    /// **預設 1 是 provisional 的。** 在評估集就緒之前定不出正確值：帶內有 20 個
    /// 候選時，被引用十次的 anchor 也只能上移一名，這很可能過度保守；但反方向
    /// 沒有證據支持任何特定數字。這是參數不是架構，量得出來再改，不要憑感覺調。
    /// 追蹤於 claude-LTM #1。
    public let displacementBound: Int

    public init(displacementBound: Int = 1) {
        precondition(displacementBound >= 0, "位移上限不得為負")
        self.displacementBound = displacementBound
    }

    public func rerank(_ candidates: [Candidate], with projection: Projection) throws -> [RankedResult] {
        var reordered = candidates

        // 依帶切段後各自處理。段與段之間永遠不交換，所以帶的圍籬在演算法層
        // 就成立，守衛只是後置確認。
        var start = 0
        while start < reordered.count {
            var end = start
            while end < reordered.count, reordered[end].band == reordered[start].band { end += 1 }
            promoteWithinBand(&reordered, range: start..<end, projection: projection)
            start = end
        }

        let placements = try RankingGuard.check(
            original: candidates, reordered: reordered, bound: displacementBound)

        return placements.map { placement in
            RankedResult(
                candidate: placement.candidate,
                displacement: placement.displacement,
                reason: reason(for: placement, in: projection))
        }
    }

    /// 帶內的有界冒泡，**上下位移都受同一個上限約束**。
    ///
    /// 每筆候選最多往上冒 `displacementBound` 次，且只越過強度嚴格較低的鄰居。
    /// 這個上限是**策略自己的預算**，不是把越界結果夾回合法範圍——後者會讓
    /// 違規變得不可觀察。
    ///
    /// 關鍵是：向上的預算不足以保證向下也在界內。被越過的候選每被跳過一次
    /// 就下移一格，而**它自己並沒有次數上限**——先前版本的註解宣稱「位於索引 j
    /// 的候選只可能被起點落在 (j, j+bound] 的候選越過」，那個推理假設索引不會
    /// 漂移，但漂移正是這個演算法在做的事。實際反例（bound = 1、同帶
    /// `[a:0, b:6, c:4, d:2]`，冒號後為 netStrength）會讓 `a` 連續被 b、c、d 跳過而
    /// 下移三格，於是 `RankingGuard` 對**內建策略自己**拋 `displacementBoundExceeded`。
    /// 見 claude-LTM #1 的 verify（2026-08-11，codex 與 logic 兩個 lens 各自重現）。
    ///
    /// 修法是在每次 swap **之前**檢查被越過那一方的累計下移：它移到 `index` 之後，
    /// 相對原始位置的下移量必須仍 ≤ bound，否則放棄這次交換。因此兩個方向都由
    /// 演算法保證，守衛回到它該有的角色——抓別人的錯，而不是抓自己的。
    ///
    /// ## 代價（#1 verify R2 量化，2026-08-14）
    ///
    /// **對稱上限的必然後果是：一條帶的提升總數上限就是 `bound`，與帶大小無關。**
    /// 位於索引 j 的候選最多下移 `bound` 名，所以最多只有 `bound` 個候選能越過它；
    /// 帶首若是一個沒有歷史的候選，整條帶就被它擋住。實測（帶大小 32、其中 31 個
    /// 有遞減強度）：
    ///
    /// | bound | 實際上移總數 |
    /// |---|---|
    /// | 1 | 1 |
    /// | 2 | 2 |
    /// | 3 | 3 |
    ///
    /// 具體例：`[a:0, b:6, c:4, d:2]`、bound 1 → `[b, a, c, d]`。強度 4 的 c 與
    /// 強度 2 的 d **完全不升**，停在強度 0 的 a 之後。所以下面那句「寧可少升
    /// 一名」在多數情形下應讀作「寧可完全不升」。
    ///
    /// 這不是演算法的缺陷，是**對稱上限這條裁決本身的算術**。要讓 human-like
    /// 在帶內真的有作用，就必須放寬對稱性（上限只約束提升、下移是後果）或
    /// 提高 bound——兩者都改變 Clarity Surface 「最多位移一名」的語意，所以
    /// 交由使用者裁決，追蹤於 #17。**在那之前不要為了讓效果變明顯而偷偷調高
    /// 預設值**：那會讓比較實驗量到的是參數，不是策略。
    private func promoteWithinBand(
        _ items: inout [Candidate], range: Range<Int>, projection: Projection
    ) {
        guard displacementBound > 0, range.count > 1 else { return }

        // 原始索引要在任何交換之前定下來——位移是相對於「檢索送進來的順序」，
        // 不是相對於中途某個狀態。
        var originIndex: [Anchor: Int] = [:]
        for i in range { originIndex[items[i].anchor] = i }

        // 先處理強度高的，同強度維持原順序，結果才是決定性的。
        let order = range.sorted { lhs, rhs in
            let a = projection.netStrength(for: items[lhs].anchor)
            let b = projection.netStrength(for: items[rhs].anchor)
            return a == b ? lhs < rhs : a > b
        }
        let queue = order.map { items[$0].anchor }

        for anchor in queue {
            guard projection.netStrength(for: anchor) > 0 else { continue }
            guard var index = items.firstIndex(where: { $0.anchor == anchor }) else { continue }
            var moves = 0
            while moves < displacementBound, index > range.lowerBound {
                let neighbour = items[index - 1]
                guard projection.netStrength(for: neighbour.anchor)
                    < projection.netStrength(for: anchor)
                else { break }
                // 被越過的一方會落到 `index`。它相對原始位置的下移量若超過上限，
                // 這次提升就得放棄——寧可少升一名，也不產出違反自身契約的排序。
                guard let neighbourOrigin = originIndex[neighbour.anchor],
                    index - neighbourOrigin <= displacementBound
                else { break }

                items.swapAt(index - 1, index)
                index -= 1
                moves += 1
            }
        }
    }

    private func reason(for placement: GuardedPlacement, in projection: Projection) -> RankingReason {
        // 先問 orphan。design.md 承諾 orphan「never silently treated as a normal
        // miss」，而先前的實作把它報成 `.noAdjustment`——註解自己都寫了「分不出來」。
        // 分不出來是因為 projection 沒把這件事帶出來，不是因為它不可知。
        if projection.isOrphaned(placement.candidate.anchor) {
            return .orphanedHistoryIgnored
        }
        guard let stats = projection[placement.candidate.anchor] else {
            // 真的沒有歷史。這是誠實的「沒有調整」。
            return .noAdjustment
        }
        // spec：「A result whose displacement is zero SHALL carry a reason
        // indicating that no adjustment was applied.」先前寫成「位移為 0 **且**
        // 強度為 0 才報 noAdjustment」，於是「有強度但沒動」會報 `.adjusted`
        // ——而那個組合正因為 R1 的「放棄提升」修法而變得常見（#1 verify R2）。
        //
        // 判準只看位移：沒動就是沒調整，不管背後有多少歷史。
        guard placement.displacement != 0 else { return .noAdjustment }
        return .adjusted(signals: stats.deliberateCounts, netStrength: stats.netStrength)
    }
}
