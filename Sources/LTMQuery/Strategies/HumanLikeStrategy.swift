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
    /// **預設 1 是 provisional 的，而且方向未知。**
    ///
    /// 在評估集就緒之前定不出正確值。先前這裡寫「帶內 20 個候選時只能上移一名，
    /// 這很可能過度保守」——那是一句**未經量測的效果量判斷**，與 README 的誠實
    /// 邊界牴觸（#1 verify R5）。可以說的只有：這個值直接決定記憶能覆寫檢索多少，
    /// 而多少是對的沒有任何證據，兩個方向都沒有。
    ///
    /// **不要為了讓效果看起來明顯而調高它**：那會讓比較實驗量到的是參數，不是策略。
    /// 追蹤於 claude-LTM #1。
    public let displacementBound: Int

    public init(displacementBound: Int = 1) {
        precondition(displacementBound >= 0, "位移上限不得為負")
        self.displacementBound = displacementBound
    }

    public func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        let candidates = input.candidates
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

        // 只取 placements（位移計算）——**上限由 seam 執行**，不在這裡自願呼叫。
        // R5：上一版每個策略各自呼叫 `check`，所以不呼叫的策略就不受約束。
        let placements = try RankingGuard.verifyPermutation(
            original: candidates, reordered: reordered)

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
        MemoryStrategySupport.boundedReorderByStrength(
            &items, range: range, projection: projection, bound: displacementBound)
    }

    /// **三檔共用 `RankingReason.describing`**，不再各寫一份 switch。
    ///
    /// 各寫一份正是 R3／R4／R5 三輪變體長出來的地方：修好其中一份，另一份原封
    /// 不動。現在方向與歷史狀態由同一個函式從 (anchor, displacement, projection)
    /// 導出，三檔不可能不一致。
    private func reason(for placement: GuardedPlacement, in projection: Projection) -> RankingReason {
        RankingReason.describing(
            placement.candidate.anchor, displacement: placement.displacement, in: projection)
    }

}
