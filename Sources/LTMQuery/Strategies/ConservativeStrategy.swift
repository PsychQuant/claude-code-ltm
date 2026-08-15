import Foundation
import LTMCore

/// 只在打平時看記憶的那一檔。
///
/// 帶內兩筆候選的 `baseScore` **完全相等**時，以 netStrength 決勝；base score
/// 不同時完全不動。因此它從不改變任何「檢索認為誰比較相關」的判斷——它只填補
/// 檢索沒有意見的地方。
///
/// ## 為什麼它回來了（#17 裁決，2026-08-15）
///
/// issue #1 原本要三檔並存，而這一檔在初版實作時被移除，理由是它的定義
/// 「strength 只當 tie-breaker，影響封頂 ±5%」無法表達。#1 的 verify 指出那個
/// 論證**只對了一半**：±5% 確實無法表達（RRF 分數是 rank 導出的、跨查詢沒有
/// 穩定語義，百分比上限沒有可指涉的對象），但「**僅作 tie-breaker**」在這套
/// 詞彙裡完全可以表達——就是下面這十幾行。
///
/// 部分為真的論證被用來支撐全稱結論，是本專案要防的那種錯誤，所以它被改回來。
///
/// ## 它與 human-like 的差別是「何時作用」，不是「作用多強」
///
/// 這一點值得說清楚，因為 spec 寫的是「策略由消費的訊號集合定義，不由調整幅度
/// 定義」。`conservative` 消費的訊號與 `human-like` 相同，差別在**條件**：
/// tie-breaker 永遠不改變 base score 不同的兩筆之間的順序，human-like 會。
/// 那是機制差異，不是強度差異——把 bound 調到 0 也得不到 tie-breaking，
/// 只會得到「什麼都不做」。
///
/// ## 一個誠實的脆弱處
///
/// 「打平」用的是 `Double` 的精確相等。RRF 分數是有理數的和，真正的平手很常見
/// （相同 rank 組合），所以這個判準在實務上會命中；但它對浮點誤差沒有容忍度，
/// 上游若改成會累積誤差的分數計算方式，這一檔會安靜地退化成 `archival`。
/// 真的發生時應該把「平手」改成上游明示的等價類，而不是在這裡加 epsilon
/// ——epsilon 會把「多接近算平手」變成另一個沒有依據的參數。
public struct ConservativeStrategy: MemoryStrategy {
    public let id = RankingPolicyID("conservative")
    public let consumedSignals: Set<EventKind> = [.opened, .cited, .pinned, .dismissed]

    public init() {}

    public func rerank(_ candidates: [Candidate], with projection: Projection) throws -> [RankedResult] {
        try MemoryStrategySupport.requireFiniteBaseScores(candidates)
        var reordered = candidates

        // 只在「同帶 + base score 完全相等」的連續區段內重排。區段之外一律不動。
        var start = 0
        while start < reordered.count {
            // `end` 從 start + 1 起算：區段至少含自己。先前寫成 `end = start`，
            // 於是第一個條件是 `x.baseScore == x.baseScore`——對 NaN 為 false，
            // `end` 停在 `start`、`start = end` 不前進，**整個 rerank 無限迴圈**
            // （#1 verify R3 實測掛住，不拋錯）。非有限值現在已在入口擋掉，
            // 這裡的寫法仍然改成「不可能不前進」，因為兩道防線的成本是一行。
            var end = start + 1
            while end < reordered.count,
                reordered[end].band == reordered[start].band,
                reordered[end].baseScore == reordered[start].baseScore
            { end += 1 }

            if end - start > 1 {
                let tied = Array(reordered[start..<end])
                // 穩定排序：強度高者在前，同強度維持原順序。
                let sorted = tied.enumerated().sorted { lhs, rhs in
                    let a = projection.netStrength(for: lhs.element.anchor)
                    let b = projection.netStrength(for: rhs.element.anchor)
                    return a == b ? lhs.offset < rhs.offset : a > b
                }.map(\.element)
                reordered.replaceSubrange(start..<end, with: sorted)
            }
            start = end
        }

        // **不設位移上限，改用更嚴格的檢查**：每一筆只能在自己原本的等分區段內
        // 移動。
        //
        // 先前這裡把 `widestTiedRun` 算出來當成自己的 bound 傳給守衛——**策略
        // 自己授權自己的上限**，於是守衛對它恆真：#1 verify R3 實測 8 個平手候選
        // 可以整個反轉、提升 7 名而不拋錯，正是 design.md 說要防的「行為不合規的
        // 策略偽裝成合規」。而且那個上限取自**整份候選清單**的最寬區段，所以
        // 一個 2 長區段裡的候選會被拿另一條帶的 8 長區段去檢查。
        //
        // 正解不是放寬而是換一條更強的約束：base score 完全相等時檢索對先後
        // **沒有表達任何偏好**，區段內任意重排都不牴觸相關性判斷；但跨區段
        // 移動一格都不行。
        let placements = try RankingGuard.checkTieRunsOnly(
            original: candidates, reordered: reordered)

        return placements.map { placement in
            reasoned(placement, in: projection)
        }
    }

    private func reasoned(_ placement: GuardedPlacement, in projection: Projection) -> RankedResult {
        if projection.isOrphaned(placement.candidate.anchor) {
            return RankedResult(
                candidate: placement.candidate, displacement: placement.displacement,
                reason: .orphanedHistoryIgnored)
        }
        guard placement.displacement != 0 else {
            return RankedResult(
                candidate: placement.candidate, displacement: 0, reason: .noAdjustment)
        }
        guard let stats = projection[placement.candidate.anchor], stats.netStrength != 0 else {
            // 位移非零但自己沒有歷史 → 是被同區段裡有歷史的鄰居擠動的。
            return RankedResult(
                candidate: placement.candidate, displacement: placement.displacement,
                reason: .displacedByPeers(positions: -placement.displacement))
        }
        return RankedResult(
            candidate: placement.candidate, displacement: placement.displacement,
            reason: .adjusted(signals: stats.deliberateCounts, netStrength: stats.netStrength))
    }
}
