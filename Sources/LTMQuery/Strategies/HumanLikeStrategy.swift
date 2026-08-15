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

    /// 帶內的有界冒泡：**每筆候選最多往上冒 `displacementBound` 次**，且只越過
    /// 強度嚴格較低的鄰居。
    ///
    /// ## 為什麼上限是單向的（#17 裁決，2026-08-15）
    ///
    /// 上限只約束**提升**。被越過的候選會下移，下移量等於「越過它的人數」，
    /// 不另設限。這條走過一段彎路，紀錄如下，因為它看起來像退步：
    ///
    /// - **R1**（2026-08-11）：verify 抓到本策略對一般輸入拋
    ///   `displacementBoundExceeded`——當時的契約是**對稱**上限，而演算法只約束
    ///   提升。反例 `[a:0, b:6, c:4, d:2]`、bound 1：a 連續被 b、c、d 跳過而下移三格。
    /// - **R1 的修法**：在每次 swap 前檢查被越過那方的累計下移，超限就放棄提升。
    ///   這讓演算法符合契約了。
    /// - **R2**（2026-08-14）：量化證明那個修法選錯邊。對稱上限的算術是
    ///   「位於索引 j 的候選最多下移 bound 名 → 最多只有 bound 個人能越過它」，
    ///   所以**一條帶的提升總數上限就是 bound，與帶大小無關**。實測帶大小 32、
    ///   其中 31 個有遞減強度：bound 1 → 實際上移總數 **1**。500 次交錯呈現有
    ///   13.2% 落成 null comparison 被丟棄。策略差異的訊號比 design.md 假設的
    ///   低一個數量級，比較實驗量不到東西。
    /// - **裁決**：改契約，不改演算法。真正圍住傷害的是**相關性帶**——帶內候選
    ///   按定義同等相關，帶已經把重排的影響限制在「不影響相關性判斷」的範圍內。
    ///   上限該擋的是「單一項目暴衝」，不是「很多項目各前進一名」。而且
    ///   「沒被回憶的東西相對往後沉」正是人類記憶的行為，不是缺陷。
    ///
    /// 位移仍然**逐筆據實回報**（`RankedResult.displacement`），所以可稽核性沒有
    /// 損失——改變的是「什麼算違規」，不是「看不看得見」。
    private func promoteWithinBand(
        _ items: inout [Candidate], range: Range<Int>, projection: Projection
    ) {
        guard displacementBound > 0, range.count > 1 else { return }

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
