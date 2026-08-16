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
            // 上限是**對稱**的：提升與下移都不得超過 bound。
            //
            // 這條改過兩次，紀錄留著因為第二次是錯的（#1 verify R3）：R2 量到
            // 「32 個候選只有 1 次提升」之後，我把契約改成單向，論證是「對稱上限
            // 的算術必然讓整帶提升總數 ≤ bound」。**那句話是錯的**——反例
            // bound=1、`[A,B,C,D] → [B,A,D,C]`，每筆位移都 ≤1 卻有兩個提升。
            // R2 量到的是 R1 那個「放棄提升」演算法的性質，不是對稱契約的性質。
            // 被量測推翻的是實作，我卻改了契約。正確做法是換演算法，見
            // `HumanLikeStrategy.promoteWithinBand`。
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

    /// 給 tie-only 策略用的檢查：**不設位移上限，改為要求「只在等分區段內移動」**。
    ///
    /// 為什麼需要一條不同的檢查而不是把 bound 放寬（#1 verify R3 的 CRITICAL）：
    /// 先前 `ConservativeStrategy` 把 `widestTiedRun` 算出來當成自己的 bound 傳給
    /// 守衛——**策略自己授權自己的上限**，於是守衛對它恆真、8 個平手候選可以整個
    /// 反轉而不拋錯。那正是 design.md 說要防的「行為不合規的策略偽裝成合規」。
    ///
    /// tie-run 約束是**額外**條件，不是位移上限的替代。
    ///
    /// R4 指出我上一版寫錯了兩次：註解說「這條約束比位移上限強，不是它的豁免」
    /// ——**不成立**。它只在「能否跨越語意區段」這個維度更嚴格，在位移幅度這個
    /// 維度完全不設限，兩者不可比較，所以那就是豁免。而實作傳
    /// `bound: max(original.count, 1)`，一個**保證不會觸發**的門檻——正是 R3 判
    /// CRITICAL 的「策略自己授權自己的上限」，只是從 `widestTiedRun` 換成
    /// `original.count`，換個地方寫。
    ///
    /// 所以現在收一個真的上限。位移上限不只是「別推翻檢索的判斷」，也是穩定性
    /// 與可稽核性——同一筆結果不該在兩次 session 之間跳七名，**那對平手區段
    /// 一樣適用**。
    public static func checkTieRunsOnly(
        original: [Candidate], reordered: [Candidate], bound: Int
    ) throws -> [GuardedPlacement] {
        let placements = try check(original: original, reordered: reordered, bound: bound)

        // 每一筆的原位置與新位置必須落在**同一個等分區段**內。
        let runID = tieRunIdentifiers(original)
        var originalIndex: [Anchor: Int] = [:]
        for (i, candidate) in original.enumerated() { originalIndex[candidate.anchor] = i }

        for (newIndex, placement) in placements.enumerated() {
            guard let from = originalIndex[placement.candidate.anchor],
                runID[from] == runID[newIndex]
            else {
                throw StrategyViolation.movedAcrossTieRuns
            }
        }
        return placements
    }

    /// 把候選切成「同帶且 base score 完全相等」的連續區段，回傳每個位置的區段編號。
    ///
    /// 非有限的 base score 在進到這裡之前就該被 seam 擋掉（見
    /// `StrategyViolation.nonFiniteBaseScore`）；這裡仍以 `isFinite` 為前提寫成
    /// 不會卡住的形式，因為 `NaN != NaN` 曾讓同型迴圈無限空轉。
    private static func tieRunIdentifiers(_ candidates: [Candidate]) -> [Int] {
        var ids = [Int](repeating: 0, count: candidates.count)
        var current = 0
        for i in candidates.indices {
            if i > 0 {
                let sameRun =
                    candidates[i].band == candidates[i - 1].band
                    && candidates[i].baseScore == candidates[i - 1].baseScore
                if !sameRun { current += 1 }
            }
            ids[i] = current
        }
        return ids
    }
}
