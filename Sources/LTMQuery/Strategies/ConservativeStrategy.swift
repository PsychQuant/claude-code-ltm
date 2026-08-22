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
/// `conservative` 消費的訊號與 `human-like` 相同（兩檔用的甚至是**同一個**
/// 有界重排核心 `MemoryStrategySupport.boundedReorderByStrength`），差別在
/// **餵給它哪些區間**：human-like 給整條相關性帶，這一檔只給 base score
/// 完全相等的區段。
///
/// **證據在非平手側，不在 bound=0。**（#1 verify R4 指正）我原本的論證是
/// 「把 human-like 的 bound 調到 0 得不到 tie-breaking」——那個點的性質由
/// 一句 early return 直接保證，證不了整個值域。DA 實測掃過 bound 0…6 後指出：
/// **在全平手輸入上，bound 夠大時 human-like 與 conservative 逐字相同**。
/// 所以在這一檔唯一會作用的那類輸入上，兩者的差別確實只是幅度。
///
/// 真正的證據一直在旁邊：**base score 相異時，沒有任何 bound 能讓 human-like
/// 變成 conservative**——這一檔在那裡完全不動，而 human-like 只要 bound > 0
/// 就會動。那是條件差異。兩條事實都寫成了測試
/// （`noBoundMakesHumanLikeBehaveLikeConservativeOnNonTiedInput` 與
/// `onAllTiedInputASufficientBoundDoesReproduceConservative`），後者刻意把
/// 「幅度確實能重現」也釘住，免得下一個人拿前者去推導它推不出來的東西。
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
/// 三路（trigram／斷詞／向量，見 #2），所以平手不是巧合而是 RRF 的結構性質。
/// （這一段證明的是「平手**會**發生」。發生率是另一件事，見下方。單通道候選之間
/// 的名次對撞也只是平手的**一種**來源，不是全部——雙通道候選的分數和同樣會碰撞。）
///
/// **發生率已在語料子集上量到**（#18，`docs/measurements/2026-08-22-rrf-tie-rate.md`
/// ——引用時請一起讀那份紀錄自己寫明的涵蓋範圍）。摘要：不低，而且高度集中在
/// `cjk-2char`；`cjk-4plus` 與 `mixed` 在該查詢集上**一次都沒有觀測到**平手。
///
/// 觀測到的機制是：中文雙字查詢的 `trigram` 通道整條空掉（3 字元硬底線，見
/// `docs/measurements/2026-08-10-fts5-tokenizer.md`），於是 `segment` 與 `vector`
/// 各自貢獻一組互斥的單通道候選，名次一對一對撞。
///
/// **以下三件事刻意不寫進來，因為它們是這一輪 verify 抓到的過度宣稱**（R1）：
///
/// 1. **不寫「該桶的結構上限」。** 觀測到的平手段長度都是 2，但那是**觀測，不是
///    上界**。平手不限於單通道候選：`rrfK = 60`、通道深度 100 時，
///    `1/(60+36)+1/(60+100)`、`1/(60+40)+1/(60+90)`、`1/(60+60)+1/(60+60)` 是
///    **同一個有理數**，所以多個雙通道候選可以逐位元同分而完全不需要 `trigram`。
///    從觀測到的段長推一個上限，是把經驗 regime 當成結構保證。
/// 2. **不寫「在那兩桶裡逐字等同 `archival`」。** 各 20 條人工查詢的零觀測支撐不了
///    一個無條件斷言。能說的是「在該查詢集上未觀測到」。
/// 3. **不寫「這一檔比較好」。** 量到的是「有沒有可動的空間」，不是「動得對不對」；
///    後者需要 `(查詢, 應命中的 turn)` 的評估集（#16），而那個東西還不存在。
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

    /// 與 `human-like` 同一個上限，預設同樣是 1 且同樣是 provisional。
    ///
    /// R4：先前這一檔**沒有**上限參數，而守衛收到的是 `max(count, 1)`——一個
    /// 保證不會觸發的門檻。位移上限不只是「別推翻檢索」，也是穩定性與可稽核性，
    /// 那對平手區段一樣適用，所以沒有理由豁免。
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

            // 與 human-like **共用**同一個有界重排核心，只是餵給它的區間不同：
            // human-like 給整條帶，這裡只給 base score 完全相等的區段。
            MemoryStrategySupport.boundedReorderByStrength(
                &reordered, range: start..<end, projection: projection,
                bound: displacementBound)
            start = end
        }

        // tie-run 是**額外**條件：每一筆只能在自己原本的等分區段內移動。
        // 位移上限**不在這裡**——它是 seam 對所有策略無條件執行的（R5）。
        //
        // 這段歷史留著，因為它被寫錯過兩次：R3 抓到這一檔把 `widestTiedRun`
        // 當成自己的 bound 傳給守衛（**策略自己授權自己的上限**，守衛對它恆真、
        // 8 個平手候選整個反轉不拋錯）；R4 的修法把它換成 `max(count, 1)`
        // ——同一件事換個地方寫；R4 的第二次修法讓策略自己帶 bound 傳給守衛，
        // 而 R5 實測那個參數**沒有任何測試釘住**（改回 `max(count,1)` 全綠），
        // 因為所有經由策略的測試都已經被策略內部的有界重排壓住幅度了。
        //
        // 三次都錯在同一個地方：**讓被約束者提供約束值**。現在上限由 seam 從
        // protocol 讀，策略只提供它自己的額外條件。
        let placements = try RankingGuard.checkTieRunsOnly(
            original: candidates, reordered: reordered)

        return placements.map { placement in
            reasoned(placement, in: projection)
        }
    }

    /// 與 human-like 共用 `RankingReason.describing`——見那一檔的說明。
    private func reasoned(_ placement: GuardedPlacement, in projection: Projection) -> RankedResult {
        RankedResult(
            candidate: placement.candidate,
            displacement: placement.displacement,
            reason: RankingReason.describing(
                placement.candidate.anchor, displacement: placement.displacement,
                in: projection))
    }

}
