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
    /// 沒有套用任何調整。`archival` 的每一筆都是這個。
    case noAdjustment
    /// 被使用歷史上推／下壓。`signals` 指名是哪些事件促成的。
    case adjusted(signals: [EventKind: Int], netStrength: Double)
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

    /// 這個策略會消費哪些事件種類。**策略軸就是這個集合**：要有第三檔，必須
    /// 指出它吃的訊號不同（例如只吃 cited/pinned），不得用「調整幅度不同」
    /// 來定義。空集合代表完全不看使用歷史。
    var consumedSignals: Set<EventKind> { get }

    func rerank(_ candidates: [Candidate], with projection: Projection) throws -> [RankedResult]
}
