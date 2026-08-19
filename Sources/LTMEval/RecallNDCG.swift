import Foundation
import LTMCore

/// 一次「(查詢, 應命中 anchor)」評分的兩階段結果。
///
/// **不是** `(recall: Bool, ndcg: Double?)` 這種可以互相矛盾的配對——那種形狀
/// 允許 `recall == false` 卻附一個非 nil 的 ndcg，一個沒有意義卻讀得到的狀態。
/// 用列舉讓「沒被 recall 到就沒有排序品質數字」在編譯期成立，跟本 repo既有的
/// `Dereference` / `AnchorStatistics.malformation` 是同一種紀律：欄位在某個狀態下
/// 沒有意義時，用 case 表達，不用可以互相矛盾的欄位配對。
///
/// 見 `openspec/changes/add-evaluation-metrics/design.md` 的
/// 「Recall@20 → nDCG@10 is a two-stage function, not two independent metrics」。
public enum RecallNDCGOutcome: Sendable, Equatable {
    /// 應命中的 anchor 不在 top-`recallK` 檢索結果裡——**沒有**排序品質數字，
    /// 因為沒有東西可以排序。這比「recall 到但排很後面」更嚴重，判準是刻意的：
    /// 一個聚合過的 nDCG 數字會把「完全沒找到」與「找到但排第 15 名」都吸收成
    /// 「nDCG 偏低」，抹掉這兩者的嚴重程度差異——而分辨這個差異正是兩階段設計
    /// 存在的理由。
    case notRecalled
    /// 應命中的 anchor 在 top-`recallK` 檢索結果裡；`ndcgAt10` 是它在 top-`ndcgK`
    /// 視窗內的正規化折扣累積增益（把它當唯一相關項算）。**若它落在 top-`recallK`
    /// 之內、但在 top-`ndcgK` 之外，這裡仍是 `.recalled`，只是 `ndcgAt10 == 0`**
    /// ——recall 到了，只是 nDCG 視窗看不到它，跟「完全沒找到」是不同的狀態。
    case recalled(ndcgAt10: Double)
}

/// 依 anchor 相等性替一次檢索結果打兩階段分數：先問「有沒有 recall 到」，
/// 只有 recall 到才問「排序品質多好」。
///
/// 純函式：不依賴 `EventStore`、`PresentationRecord`，或任何即時比較用的型別
/// ——這是一個獨立的評分基元，未來的 ground-truth harness 可以直接呼叫它，
/// 不必牽動交錯比較（interleaving）那整套機制。
///
/// - Parameters:
///   - retrieved: 檢索結果，依名次排序（index 0 = 第 1 名）。
///   - expected: 這次查詢「應該」命中的 anchor。
///   - recallK: recall 判定的視窗大小。預設 20（對應「Recall@20」）。
///   - ndcgK: nDCG 判定的視窗大小。預設 10（對應「nDCG@10」），**與 `recallK`
///     刻意分開**——兩階段指標的兩段本來就看不同大小的視窗，用同一個參數會讓
///     呼叫端無法只調其中一段。
public func scoreRecallAndRanking(
    retrieved: [Anchor], expected: Anchor, recallK: Int = 20, ndcgK: Int = 10
) -> RecallNDCGOutcome {
    guard let rank = retrieved.prefix(recallK).firstIndex(of: expected) else {
        return .notRecalled
    }
    // rank 是 0-indexed 位置；nDCG 視窗外（第 recallK 名以內、但第 ndcgK 名以外）
    // 一樣算 recalled，只是排序品質貢獻是 0——見 `RecallNDCGOutcome.recalled` 的說明。
    guard rank < ndcgK else { return .recalled(ndcgAt10: 0) }

    // 唯一相關項（relevance = 1）的情況下：
    //   DCG   = 1 / log2(rank + 2)   （rank 是 0-indexed，公式的 1-indexed 名次是 rank+1）
    //   IDCG  = 1 / log2(1 + 1) = 1  （理想情況：排第 1 名）
    // nDCG@ndcgK = DCG / IDCG = DCG。
    let dcg = 1.0 / log2(Double(rank + 2))
    return .recalled(ndcgAt10: dcg)
}

/// 同一次查詢，三個檢索通道（lexical-only／vector-only／fused）各自的兩階段結果。
///
/// **三個欄位都呼叫同一個 `scoreRecallAndRanking`**，不是三份各自維護的實作——
/// 本 repo 已經在 `RankingReason` 的歷史上踩過「三份幾乎相同的 switch，各自帶著
/// 自己的局部修法」這個形狀（見 `Sources/LTMQuery/Strategies/HumanLikeStrategy.swift`），
/// 這裡刻意用「一個函式、三個呼叫點」避免同一件事重演。
///
/// 見 design.md 的「Three-track reporting is a report shape, not three separate
/// comparison runs」。
public struct ChannelBreakdown: Sendable, Equatable {
    public let lexical: RecallNDCGOutcome
    public let vector: RecallNDCGOutcome
    public let fused: RecallNDCGOutcome

    public init(lexical: RecallNDCGOutcome, vector: RecallNDCGOutcome, fused: RecallNDCGOutcome) {
        self.lexical = lexical
        self.vector = vector
        self.fused = fused
    }
}
