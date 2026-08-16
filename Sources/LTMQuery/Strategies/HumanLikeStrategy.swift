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
        try MemoryStrategySupport.requireFiniteBaseScores(candidates)
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

    /// 帶內的有界冒泡：**每筆候選最多往上冒 `displacementBound` 次**，且只越過
    /// 強度嚴格較低的鄰居。
    ///
    /// ## 上限是對稱的。這條走過兩次彎路，兩次都留在這裡
    ///
    /// - **R1**（2026-08-11）：verify 抓到本策略對一般輸入拋
    ///   `displacementBoundExceeded`——契約是對稱上限，而當時的貪婪冒泡只約束
    ///   提升。反例 `[a:0, b:6, c:4, d:2]`、bound 1：a 連續被 b、c、d 跳過、下移三格。
    /// - **R1 的修法**：swap 前檢查被越過那方的累計下移，超限就放棄提升。演算法
    ///   因此符合契約，但引入了**楔住**——帶首的擋路者用完預算後，它上方的位置
    ///   對所有後續候選永久封死。
    /// - **R2**（2026-08-14）：量到「帶大小 32、31 個有歷史 → 只有 1 次提升」，
    ///   判定 human-like 幾乎被關掉。
    /// - **我當時的反應是改契約**（改成只約束提升），論證是「對稱上限的算術必然
    ///   讓整帶提升總數 ≤ bound」。
    /// - **R3**（2026-08-15）：那句話**是錯的**。反例：bound 1、
    ///   `[A,B,C,D] → [B,A,D,C]`，每筆位移都 ≤1 卻有兩個提升。被量測推翻的是
    ///   R1 的**演算法**，不是契約；我卻改了契約。而且 R2 那個輸入的第 0 名以外
    ///   本來就按強度排好了——**1 次提升是最佳解，不是飢餓**。量測為真、詮釋有誤。
    ///
    /// 所以：**契約改回對稱，換掉演算法。** 現在的作法是 pass-based，每個元素
    /// 每輪最多參與一次交換，跑 `bound` 輪——兩個方向的上限由構造保證，且沒有
    /// 「放棄提升」規則，所以不會楔住（測試 `promotionsHappenWhereverTheyAreNeeded`
    /// 釘住這件事）。
    ///
    /// 留著這整段的理由：中間那一步「改掉自己 code 一直違反的規則」在當下看起來
    /// 有充分理由，而它錯了。只寫結論的話，下一個人會再走一次。
    private func promoteWithinBand(
        _ items: inout [Candidate], range: Range<Int>, projection: Projection
    ) {
        guard displacementBound > 0, range.count > 1 else { return }

        // 每一輪由左往右掃一次相鄰對，強度較高者往前換；**每個元素每輪最多參與
        // 一次交換**（`movedThisPass`）。因此單輪位移至多 1，跑 `bound` 輪之後
        // 任一元素的位移至多 `bound`——**對稱上限由構造保證，兩個方向都是**。
        //
        // 這取代了先前那個「冒泡到上限、被越過方超額就放棄提升」的貪婪版本。
        // 那一版的問題不是不安全，是會**楔住**：帶首一個沒有歷史的候選用完下移
        // 預算之後，它上方的位置對所有後續候選永久封死。這裡沒有放棄規則，
        // 每一輪都做得了的相鄰改善全部做掉，所以提升會散佈到整條帶上。
        for _ in 0..<displacementBound {
            var movedThisPass: Set<Anchor> = []
            var i = range.lowerBound + 1
            while i < range.upperBound {
                let left = items[i - 1]
                let right = items[i]
                if projection.netStrength(for: right.anchor)
                    > projection.netStrength(for: left.anchor),
                    !movedThisPass.contains(left.anchor),
                    !movedThisPass.contains(right.anchor)
                {
                    items.swapAt(i - 1, i)
                    movedThisPass.insert(left.anchor)
                    movedThisPass.insert(right.anchor)
                }
                i += 1
            }
            if movedThisPass.isEmpty { break }  // 已到不動點，剩下的輪次沒有意義
        }
    }

    private func reason(for placement: GuardedPlacement, in projection: Projection) -> RankingReason {
        // 先問 orphan。design.md 承諾 orphan「never silently treated as a normal
        // miss」，而先前的實作把它報成 `.noAdjustment`——註解自己都寫了「分不出來」。
        // 分不出來是因為 projection 沒把這件事帶出來，不是因為它不可知。
        if projection.isOrphaned(placement.candidate.anchor) {
            return .orphanedHistoryIgnored
        }
        guard let stats = projection[placement.candidate.anchor], stats.netStrength != 0 else {
            // 沒有歷史。位置沒變 → 誠實的「沒有調整」；位置變了 → 是被有歷史的
            // 鄰居超車擠下來的，必須說出來。先前這裡一律回 `.noAdjustment`，
            // 於是一筆下移三名的結果同時聲稱「移動了三名」與「沒有套用任何調整」
            // （#1 verify R3）。
            return placement.displacement == 0
                ? .noAdjustment
                : .displacedByPeers(positions: placement.displacement)
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
