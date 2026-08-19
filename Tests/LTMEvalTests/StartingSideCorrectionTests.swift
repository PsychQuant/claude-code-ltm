import Foundation
import Testing

@testable import LTMCore
@testable import LTMEval

/// 起手方分層計分（fixed-effect 校正）的測試。
///
/// 呼應 design.md「Starting-side correction uses a fixed-effect model, not
/// stratified win rates」——這裡驗的是**一個**校正後數字，且用具體數字證明它
/// 跟未校正的原始 pooled rate 不同，不只驗證「有回傳一個 Double」。

private let policyA = RankingPolicyID("a")
private let policyB = RankingPolicyID("b")

@Test func correctedEstimateDiffersFromNaivePooledRateOnTheWorkedExample() throws {
    // 對應 design.md 與 spec 的具體例子：100 次呈現，60 次以 A 起手、40 次以 B 起手。
    // A 起手那 60 次裡，30 次記給 A（該層 rate = 0.5）；
    // B 起手那 40 次裡，36 次記給 A（該層 rate = 0.9）。
    var observations: [StartingSideObservation] = []
    observations.append(
        contentsOf: (0..<30).map { _ in StartingSideObservation(side: .a, creditedTo: policyA) })
    observations.append(
        contentsOf: (0..<30).map { _ in StartingSideObservation(side: .a, creditedTo: policyB) })
    observations.append(
        contentsOf: (0..<36).map { _ in StartingSideObservation(side: .b, creditedTo: policyA) })
    observations.append(
        contentsOf: (0..<4).map { _ in StartingSideObservation(side: .b, creditedTo: policyB) })
    #expect(observations.count == 100)

    let naivePooledRate =
        Double(observations.filter { $0.creditedTo == policyA }.count) / Double(observations.count)
    #expect(abs(naivePooledRate - 0.66) < 1e-9, "前提：pooled rate 是 66/100")

    let corrected = try #require(
        startingSideCorrectedPreference(observations, towardPolicy: policyA))
    #expect(abs(corrected - 0.70) < 1e-9, "校正後 = (0.5 + 0.9) / 2，不等於 pooled 的 0.66")
    #expect(corrected != naivePooledRate)
}

@Test func aOneSidedObservationSetYieldsNoCorrection() {
    // 所有觀測都以同一側起手 → 另一層樣本數為 0，無法做兩層平均。
    let observations = (0..<50).map { _ in
        StartingSideObservation(side: .a, creditedTo: policyA)
    }
    #expect(startingSideCorrectedPreference(observations, towardPolicy: policyA) == nil)
}

@Test func anEmptyObservationSetYieldsNoCorrection() {
    #expect(startingSideCorrectedPreference([], towardPolicy: policyA) == nil)
}

@Test func balancedEqualRatesYieldTheSameRateEitherWay() throws {
    // 兩層 rate 相同時，校正前後應該一致（校正只在兩層 rate 有落差時才會偏離 pooled）。
    var observations: [StartingSideObservation] = []
    observations.append(
        contentsOf: (0..<30).map { _ in StartingSideObservation(side: .a, creditedTo: policyA) })
    observations.append(
        contentsOf: (0..<30).map { _ in StartingSideObservation(side: .a, creditedTo: policyB) })
    observations.append(
        contentsOf: (0..<20).map { _ in StartingSideObservation(side: .b, creditedTo: policyA) })
    observations.append(
        contentsOf: (0..<20).map { _ in StartingSideObservation(side: .b, creditedTo: policyB) })

    let corrected = try #require(
        startingSideCorrectedPreference(observations, towardPolicy: policyA))
    #expect(abs(corrected - 0.5) < 1e-9)
}
