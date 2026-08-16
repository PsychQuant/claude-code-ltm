import Foundation
import LTMCore

/// 相關性帶。`rank` 越小越相關。
///
/// 帶是重排的圍籬：策略只能在同一帶內動順序。用「帶」而不是「分數百分比」的
/// 理由見 design——RRF 分數是 rank 導出的、跨查詢沒有穩定語義，百分比上限
/// 沒有可指涉的對象。
public struct RelevanceBand: Sendable, Hashable, Comparable, Codable {
    public let rank: Int
    public init(rank: Int) { self.rank = rank }
    public static func < (a: RelevanceBand, b: RelevanceBand) -> Bool { a.rank < b.rank }
}

/// 檢索送進 seam 的候選。
public struct Candidate: Sendable, Equatable {
    public let anchor: Anchor
    public let baseScore: Double
    public let band: RelevanceBand

    public init(anchor: Anchor, baseScore: Double, band: RelevanceBand) {
        self.anchor = anchor
        self.baseScore = baseScore
        self.band = band
    }
}

/// 某筆結果為何在它現在的位置。
public enum RankingReason: Sendable, Equatable {
    /// 沒有套用任何調整，且位置也沒變。
    case noAdjustment
    /// 被使用歷史上推。`signals` 指名是哪些事件促成的。
    case adjusted(signals: [EventKind: Int], netStrength: Double)
    /// **自己沒有歷史，位置變動來自鄰居的移動。**
    ///
    /// `positions` 與 `displacement` 同號：正數代表相對上移、負數代表下沉。
    ///
    /// #1 verify R3：先前這種情形回報 `.noAdjustment`，於是一筆下移三名的結果
    /// 同時聲稱「移動了三名」與「沒有套用任何調整」。
    ///
    /// #1 verify R4：修法寫成 `positions: -displacement`，**假設沒有歷史的候選
    /// 只會往下移**。錯了——`dismissed` 讓鄰居的 netStrength 變負，於是沒有歷史
    /// 的候選會相對**上移**，而 reason 回報 `positions: -1`。實測：`a` 帶
    /// `dismissed: 5`、`b` 無歷史 → b 上移一名、reason 說它被擠下 −1 名。
    /// **修法在它所修的那個缺陷的鏡像上重演了同一件事**：reason 描述的與實際
    /// 發生的相反。改為與 displacement 同號，語意由文件說明方向。
    case displacedByPeers(positions: Int)
    /// 有歷史，但 anchor 已 orphan，所以歷史不計入。
    case orphanedHistoryIgnored
}

/// 重排後的一筆結果。
public struct RankedResult: Sendable, Equatable {
    public let candidate: Candidate
    /// 相對於純檢索順序的位移。**正數代表上移**（索引變小）。
    public let displacement: Int
    public let reason: RankingReason

    public init(candidate: Candidate, displacement: Int, reason: RankingReason) {
        self.candidate = candidate
        self.displacement = displacement
        self.reason = reason
    }
}

/// 策略違規。這些是程式錯誤，一律外顯而不是夾成合法值。
///
/// 夾（clamp）會讓一個行為不合規的策略看起來像合規的策略——那正是比較實驗
/// 最不能容忍的失真。
public enum StrategyViolation: Error, Sendable, Equatable {
    case crossedRelevanceBand(from: RelevanceBand, to: RelevanceBand)
    case displacementBoundExceeded(bound: Int, attempted: Int)
    /// 重排結果不是輸入的排列（多了、少了、或換了東西）。
    case candidateSetChanged
    /// tie-only 策略把候選移出了它原本所屬的等分區段。
    case movedAcrossTieRuns
    /// 候選的 base score 不是有限值。
    ///
    /// 這是**前置條件**而非邊角處理：`NaN` 讓 `x == x` 為 false，而策略與守衛都
    /// 用等值比較切分等分區段——#1 verify R3 實測 `ConservativeStrategy` 因此
    /// 無限迴圈（不拋錯，直接掛住燒 CPU），與 R1 修掉的交錯迴圈是同一個
    /// failure class。在 seam 入口一次擋掉，比讓每個迴圈各自防禦可靠。
    case nonFiniteBaseScore(Anchor)
}

/// 所有策略共用的前置條件。
public enum MemoryStrategySupport {
    /// base score 必須是有限值。
    ///
    /// 這條是**前置條件**，在 seam 入口一次擋掉，不讓每個迴圈各自防禦。理由是
    /// 實證的：`NaN` 讓 `x == x` 為 false，而等分區段的切分、守衛的排列比對都
    /// 建立在等值比較上。#1 verify R3 實測 `ConservativeStrategy` 因此無限迴圈
    /// ——不拋錯、直接掛住——與 R1 修掉的交錯迴圈是同一個 failure class。
    /// 讓它在最上游變成一個具名錯誤，比在三個地方各補一次防禦可靠。
    public static func requireFiniteBaseScores(_ candidates: [Candidate]) throws {
        for candidate in candidates where !candidate.baseScore.isFinite {
            throw StrategyViolation.nonFiniteBaseScore(candidate.anchor)
        }
    }

    /// 在一段連續區間內依強度做**有界**重排。
    ///
    /// 每一輪由左往右掃相鄰對，強度較高者往前換，且**每個元素每輪最多參與一次
    /// 交換**。因此單輪位移至多 1，跑 `bound` 輪之後任一元素的位移至多 `bound`
    /// ——雙向上限由構造保證。
    ///
    /// 這是 `human-like` 與 `conservative` **共用**的重排核心，兩檔的差別因此
    /// 落在「餵給它哪些區間」：human-like 給整條相關性帶，conservative 只給
    /// base score 完全相等的區段。**同機制、不同條件**——這句話原本只寫在註解裡，
    /// 現在是 code 的形狀（#1 verify R4 指出原本的論證挑錯了證據，見
    /// `ConservativeStrategy` 的說明）。
    public static func boundedReorderByStrength(
        _ items: inout [Candidate], range: Range<Int>, projection: Projection, bound: Int
    ) {
        guard bound > 0, range.count > 1 else { return }
        for _ in 0..<bound {
            var movedThisPass: Set<Anchor> = []
            var i = range.lowerBound + 1
            while i < range.upperBound {
                let left = items[i - 1]
                let right = items[i]
                if projection.netStrength(for: right.anchor)
                    > projection.netStrength(for: left.anchor),
                    !movedThisPass.contains(left.anchor),
                    !movedThisPass.contains(right.anchor)
                {
                    items.swapAt(i - 1, i)
                    movedThisPass.insert(left.anchor)
                    movedThisPass.insert(right.anchor)
                }
                i += 1
            }
            if movedThisPass.isEmpty { break }  // 已到不動點
        }
    }
}

/// 使用歷史能影響排序的**唯一**入口。
///
/// 簽章上收得到的只有候選與 projection：沒有 CorpusReader（策略讀不到語料）、
/// 也沒有 `FileEventStore`（本模組不依賴 LTMMemory）。
///
/// **兩者的強度不同，不可混為一談**（#1 verify R1 實測推翻原宣稱、R2 指出這裡
/// 漏改）：簽章不收 CorpusReader 是型別層事實，但 `CorpusReader` 與
/// `Anchor.dereference` 都是 LTMCore 的 public API，策略側自建 reader 仍可還原
/// 原文；依賴宣告擋掉的只是 `FileEventStore` 這個便利型別，`Event: Codable`
/// 在 LTMCore，用 Foundation 直接讀檔即可繞過。兩條 SHALL NOT 目前**沒有
/// 執行點**，追蹤於 #14。
public protocol MemoryStrategy: Sendable {
    /// 策略識別碼。由「消費哪些訊號」定義，不由調整幅度定義——所以同一個策略
    /// 配不同位移上限仍是同一個 id。
    var id: RankingPolicyID { get }

    /// 這個策略會消費哪些事件種類。空集合代表完全不看使用歷史。
    ///
    /// **策略軸是「消費哪些訊號」加上「在什麼條件下作用」，永遠不是「調整幅度」。**
    /// 這句話比原本寫的寬：先前只寫訊號集合，於是 `conservative`（與 human-like
    /// 同訊號、只在等分時作用）在字面上被自己的 protocol doc 禁止（#1 verify R3）。
    /// 幅度仍然不算——把 human-like 的上限調到 0 得到的是「什麼都不做」，
    /// 不是 tie-breaking，兩者不是同一個機制的兩種強度。
    var consumedSignals: Set<EventKind> { get }

    func rerank(_ candidates: [Candidate], with projection: Projection) throws -> [RankedResult]
}
