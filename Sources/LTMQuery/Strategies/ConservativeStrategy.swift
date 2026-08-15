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
/// ## 這一檔的存廢完全取決於「平手到底常不常見」
///
/// base score 兩兩相異時，`conservative` **可證明等同於 `archival`**（回傳原順序、
/// 位移全 0，測試 `conservativeNeverReordersCandidatesWithDifferentBaseScores`
/// 就是在證這件事）。所以平手發生率就是這一檔的全部。
///
/// **結構性理由（可推導，不是感覺）**：RRF 的分數是 `Σ 1/(k + rank_i)`，而
/// 每一路的 rank 在該路內互不相同。因此只出現在**單一**路徑的兩筆候選，
/// 只要在各自那一路的 rank 相同，分數就**完全相等**——例如 X 只出現在 trigram
/// 的第 5 名、Y 只出現在向量路的第 5 名，兩者都是 `1/(k+5)`。本專案的融合是
/// 三路（trigram／斷詞／向量，見 #2），而單路命中在長尾很常見，所以平手不是
/// 巧合而是 RRF 的結構性質。
///
/// **誠實邊界：上面推的是「平手會發生」，不是「發生率是多少」。** 發生率沒有
/// 量過，而它決定這一檔在實務上是有作用還是幾乎等於 `archival`。這正是 R2 教
/// 的那一課——本專案對效果量的直覺曾經差一個數量級。量測列為 follow-up，
/// **在量到之前不得宣稱這一檔「在實務上會命中」**。
///
/// ## 一個誠實的脆弱處
///
/// 「打平」用的是 `Double` 的精確相等。它對浮點誤差沒有容忍度：上游若改成會
/// 累積誤差的分數計算方式（例如先正規化再相加），這一檔會**安靜地**退化成
/// `archival`——不報錯、不留痕跡。真的發生時應該把「平手」改成上游明示的
/// 等價類，而不是在這裡加 epsilon——epsilon 會把「多接近算平手」變成另一個
/// 沒有依據的參數。
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
