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
            // 輸入本身就有重複 anchor。這是上游的錯（例如 lexical 與 vector 兩路
            // 送了同一段而沒去重），但必須在這裡外顯——否則交錯器會因為可取出的
            // 相異 anchor 少於 count 而空轉。
            throw StrategyViolation.candidateSetChanged
        }

        // count 相同 + 每筆都查得到原索引，**證明不了**是排列：`[A,B,C] → [A,A,C]`
        // 三個條件全過而 B 被靜默吞掉。要驗 multiset 就得逐筆消耗，而且比對的是
        // 完整的 Candidate 而非只有 anchor——只比 anchor 的話，把 baseScore 或 band
        // 換掉的偽造候選也會通過。（#1 verify 2026-08-11，codex 與 logic 各自實測。）
        var unconsumed: [Anchor: Candidate] = [:]
        for candidate in original { unconsumed[candidate.anchor] = candidate }

        var placements: [GuardedPlacement] = []
        placements.reserveCapacity(reordered.count)
        for (newIndex, candidate) in reordered.enumerated() {
            guard let expected = unconsumed.removeValue(forKey: candidate.anchor),
                expected == candidate
            else {
                // 重複出現（第二次就取不到）、憑空出現、或欄位被竄改，都在這裡。
                throw StrategyViolation.candidateSetChanged
            }
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

        // 走到這裡 count 已相同且每筆都消耗掉一個相異的原候選，所以 unconsumed
        // 必為空。留著這條斷言是為了讓「排列」這件事在 code 裡有一個明確的終點，
        // 而不是散在三個 guard 的交集裡靠讀者自己推。
        guard unconsumed.isEmpty else { throw StrategyViolation.candidateSetChanged }
        return placements
    }
}
