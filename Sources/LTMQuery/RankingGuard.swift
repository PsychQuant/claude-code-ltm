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
    /// 位移上限之外的**普遍**後置條件：排列性、帶保持、位移計算。
    ///
    /// 拆出來是因為這些性質對**每一個**策略都成立（spec 的「策略不得引入候選」
    /// 與「只在帶內移動」沒有例外），而位移上限是 per-strategy 的設定
    /// （`archival` 根本沒有上限可言）。拆開之後 seam 就能無條件強制前者，
    /// 不必等策略自己想起來要呼叫（#1 verify R4：先前兩者都是自願的）。
    public static func verifyPermutation(
        original: [Candidate],
        reordered: [Candidate]
    ) throws -> [GuardedPlacement] {
        // 先驗帶：重排後每個位置的帶必須與原順序逐位相同。帶是圍籬，
        // 位移上限只在圍籬內才有意義。
        guard original.count == reordered.count else {
            throw StrategyViolation.candidateSetChanged
        }
        for i in 0..<original.count where reordered[i].band != original[i].band {
            throw StrategyViolation.crossedRelevanceBand(
                expected: original[i].band, found: reordered[i].band)
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
            placements.append(GuardedPlacement(candidate: candidate, displacement: displacement))
        }

        guard unconsumed.isEmpty else { throw StrategyViolation.candidateSetChanged }
        return placements
    }

    public static func check(
        original: [Candidate],
        reordered: [Candidate],
        bound: Int
    ) throws -> [GuardedPlacement] {
        precondition(bound >= 0, "位移上限不得為負")
        let placements = try verifyPermutation(original: original, reordered: reordered)

        for placement in placements {
            let displacement = placement.displacement
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
        }
        return placements
    }

    /// tie-only 策略的**額外**條件：每一筆只能在自己原本的等分區段內移動。
    ///
    /// **呼叫端是 seam**（`MemoryStrategy.rerank` 的後置條件），依策略宣告的
    /// `placementConstraints` 決定要不要跑——**不是**由策略自己呼叫。先前是後者，
    /// 而那讓執行點落在被約束者手上：實測把 `ConservativeStrategy` 那一行換成只驗
    /// 排列的版本，`LTMQuery` 67 條測試全綠，因為唯一覆蓋該約束的測試從不建構
    /// 策略、只把手工排列直接餵進本函式（#32）。本函式的邏輯一直有測試覆蓋；
    /// 沒被覆蓋的是它**在生產路徑上被呼叫**這件事。
    ///
    /// **它不收 bound，也不檢查幅度**——位移上限是 seam 對所有策略無條件執行的
    /// （`MemoryStrategy.displacementBound`）。這一條只加它自己那個維度。
    ///
    /// 這個簽章改過三次，三次都錯在同一件事——**讓被約束者提供約束值**：
    /// R3 抓到 `ConservativeStrategy` 傳 `widestTiedRun`（守衛對它恆真）；
    /// R4 換成 `max(original.count, 1)`（一個保證不會觸發的門檻，同一件事）；
    /// R4 的第二次修法讓策略帶自己的 `displacementBound` 傳進來，而 R5 實測
    /// 那個參數**沒有任何測試釘得住**——改回 `max(count,1)` 測試全綠，因為
    /// 所有經由策略的測試都先被策略內部的有界重排壓住了幅度，守衛拿到什麼
    /// 都不影響輸出。守衛存在的全部理由就是攔截不守規矩的實作，而那條路徑
    /// 從來沒被驗證過。
    ///
    /// 幅度不再經過這個簽章——但**那不等於洞關掉了**。上限的值仍然由策略自己
    /// 宣告，seam 只是改成從 protocol 讀而不是收策略傳來的引數；來源相同。
    /// 完整論證與它為什麼是尚未做出的設計決定，見 `MemoryStrategy` 的
    /// `displacementBound` 註解（那裡是 source of truth，此處不重述）。
    /// 這一行先前寫著「那個洞在結構上關掉了」，與 SoT 相反（#17 verify）。
    public static func checkTieRunsOnly(
        original: [Candidate], reordered: [Candidate]
    ) throws -> [GuardedPlacement] {
        let placements = try verifyPermutation(original: original, reordered: reordered)

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
