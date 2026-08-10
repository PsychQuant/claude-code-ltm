import Foundation
import LTMCore

/// 通過守衛的一筆放置。
public struct GuardedPlacement: Sendable, Equatable {
    public let candidate: Candidate
    /// 正數代表上移。
    public let displacement: Int
}

/// 重排的後置條件檢查。
///
/// 這是**後置條件**不是修正器：發現違規就拋，不夾成合法值。夾了之後，一個
/// 行為不合規的策略會偽裝成合規的策略，而比較實驗最不能容忍的就是這種失真。
public enum RankingGuard {
    public static func check(
        original: [Candidate],
        reordered: [Candidate],
        bound: Int
    ) throws -> [GuardedPlacement] {
        precondition(bound >= 0, "位移上限不得為負")

        // 先驗帶：重排後每個位置的帶必須與原順序逐位相同。帶是圍籬，
        // 位移上限只在圍籬內才有意義。
        guard original.count == reordered.count else {
            throw StrategyViolation.candidateSetChanged
        }
        for i in 0..<original.count where reordered[i].band != original[i].band {
            throw StrategyViolation.crossedRelevanceBand(
                from: reordered[i].band, to: original[i].band)
        }

        var originalIndex: [Anchor: Int] = [:]
        for (i, candidate) in original.enumerated() { originalIndex[candidate.anchor] = i }
        guard originalIndex.count == original.count else {
            throw StrategyViolation.candidateSetChanged
        }

        var placements: [GuardedPlacement] = []
        placements.reserveCapacity(reordered.count)
        for (newIndex, candidate) in reordered.enumerated() {
            guard let from = originalIndex[candidate.anchor] else {
                throw StrategyViolation.candidateSetChanged
            }
            let displacement = from - newIndex
            guard abs(displacement) <= bound else {
                throw StrategyViolation.displacementBoundExceeded(
                    bound: bound, attempted: abs(displacement))
            }
            placements.append(GuardedPlacement(candidate: candidate, displacement: displacement))
        }
        return placements
    }
}
