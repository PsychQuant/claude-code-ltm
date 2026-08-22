import Foundation
import LTMCore

/// 一筆已配對好的觀測：這次呈現以哪一側起手、這次互動記給了哪個策略。
///
/// **呼叫端是 `ComparisonScorer.report`**（`ComparisonReport.swift` 的計分迴圈，
/// credit 事件那一支）——它是唯一同時知道 `policy` 與 `record.startingSide` 的地方。
/// 這句話先前寫成一般性的「呼叫端如何如何」，而**當時沒有任何呼叫端**：那讓下一個
/// 使用者必須自己重寫一次配對邏輯，也就是下面這段說要避免的東西（#16 verify）。
///
/// 舊的說法保留在下面，因為它解釋了為什麼配對不放在這個型別裡：
/// 呼叫端從既有的 `PresentationRecord.startingSide` 與已計分事件的歸屬
/// （`ComparisonScorer` 迴圈裡已經算出來的 `policy`）配對出這個型別，
/// 本型別本身不重做那段配對邏輯——避免與既有計分迴圈長出第二份可能漂移的實作。
public struct StartingSideObservation: Sendable, Equatable {
    public let side: InterleavingHarness.Side
    public let creditedTo: RankingPolicyID

    public init(side: InterleavingHarness.Side, creditedTo: RankingPolicyID) {
        self.side = side
        self.creditedTo = creditedTo
    }
}

/// 對一組觀測，算出「校正起手方效應後」對 `policy` 的偏好估計。
///
/// ## 為什麼是兩層 rate 的等權重平均，不是分開報兩個數字
///
/// 這不是「report 分別印出 A 起手時的 win rate 與 B 起手時的 win rate」（design.md
/// 明文否決的替代方案）——那仍然是**兩個**數字，樣本數小的那層會不可靠。這裡回傳
/// **一個**校正後數字：把兩層各自的 rate 等權重平均，而不是照樣本數加權（那正是
/// pooled rate 在做的事，也正是起手方分派不平衡時會被扭曲的地方）。
///
/// 這等同於一個只含 `startingSide` 這個二元共變量的線性機率模型（OLS）在兩層各自
/// 樣本平均值處的擬合值取平均——閉式解，不需要引入統計套件依賴，且與 issue #16
/// 的 spectra-discuss 結論（`outcome ~ policy + startingSide`）一致：用全部觀測值
/// 校正，而不是丟掉其中一層的樣本量。
///
/// - Returns: `nil` 代表兩層之一完全沒有觀測——此時無法做兩層平均，回傳一個由
///   單層樣本推出的「校正後」數字會是假的校正（見 design.md 的「degenerate 分佈」
///   失敗模式）。有觀測時才回傳非 nil。
public func startingSideCorrectedPreference(
    _ observations: [StartingSideObservation], towardPolicy policy: RankingPolicyID
) -> Double? {
    let sideA = observations.filter { $0.side == .a }
    let sideB = observations.filter { $0.side == .b }
    guard !sideA.isEmpty, !sideB.isEmpty else { return nil }

    let rateA = Double(sideA.filter { $0.creditedTo == policy }.count) / Double(sideA.count)
    let rateB = Double(sideB.filter { $0.creditedTo == policy }.count) / Double(sideB.count)
    return (rateA + rateB) / 2
}
