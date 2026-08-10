import Foundation
import LTMCore

/// 沒有記憶的那一檔：純檢索順序原封不動。
///
/// 它同時是 null object 與正確性的對照組——比較實驗需要一個「記憶不存在」的
/// 基準，而不是「記憶很弱」的基準。策略軸的語意是有無，不是強弱。
public struct ArchivalStrategy: MemoryStrategy {
    public let id = RankingPolicyID("archival")
    /// 空集合：完全不消費使用歷史。
    public let consumedSignals: Set<EventKind> = []

    public init() {}

    public func rerank(_ candidates: [Candidate], with projection: Projection) throws -> [RankedResult] {
        // 連看都不看 projection。這不是省事，是定義。
        candidates.map {
            RankedResult(candidate: $0, displacement: 0, reason: .noAdjustment)
        }
    }
}
