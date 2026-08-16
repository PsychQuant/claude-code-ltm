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
    /// 0：它從不重排，所以任何非零位移都是違規。
    ///
    /// 這不是形式上的填空——seam 現在無條件用它呼叫 `RankingGuard.check`，
    /// 所以「archival 的每一筆位移都是 0」從註解變成守衛會擋的事。
    public let displacementBound = 0

    public init() {}

    public func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        // 前置條件對三檔一致：非有限 base score 在 seam 入口就擋掉，不因為這一檔
        // 不重排就放行——放行會讓「哪一檔會擋」變成呼叫端要記得的事。
        // 連看都不看 projection。這不是省事，是定義。
        return input.candidates.map {
            RankedResult(candidate: $0, displacement: 0, reason: .noAdjustment)
        }
    }
}
