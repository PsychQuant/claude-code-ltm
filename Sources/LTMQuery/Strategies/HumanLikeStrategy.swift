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

    /// 帶內的有界冒泡。
    ///
    /// 每筆候選最多往上冒 `displacementBound` 次，且只越過強度嚴格較低的鄰居。
    /// 這個上限是**策略自己的預算**，不是把越界結果夾回合法範圍——後者會讓
    /// 違規變得不可觀察。
    ///
    /// 順帶保證了向下位移也不超過上限：位於索引 j 的候選只可能被起點落在
    /// (j, j+bound] 的候選越過，那至多 `bound` 個。
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
            while moves < displacementBound, index > range.lowerBound,
                projection.netStrength(for: items[index - 1].anchor)
                    < projection.netStrength(for: anchor)
            {
                items.swapAt(index - 1, index)
                index -= 1
                moves += 1
            }
        }
    }

    private func reason(for placement: GuardedPlacement, in projection: Projection) -> RankingReason {
        guard let stats = projection[placement.candidate.anchor] else {
            // 沒有統計有兩種可能：真的沒歷史，或 anchor 已 orphan 被 projection
            // 濾掉。兩者在排序上都是「不計入」，但只有後者值得說出來——這裡
            // 分不出來，所以誠實地報「沒有調整」。
            return .noAdjustment
        }
        guard placement.displacement != 0 || stats.netStrength != 0 else {
            return .noAdjustment
        }
        return .adjusted(signals: stats.deliberateCounts, netStrength: stats.netStrength)
    }
}
