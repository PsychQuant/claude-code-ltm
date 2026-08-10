import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// 依賴約束的驗證標的是 Package.swift：LTMQuery 的 dependencies 只有 LTMCore。
// 因此 `EventStore` 在本模組不是可見型別，「retrieval 直接讀事件存放」是編譯
// 錯誤而不是 review 疏漏。這個檔案裡刻意沒有 `import LTMMemory`——加上去就
// 會讓這條斷言失效，所以它同時是一道防線。

let instant = Date(timeIntervalSince1970: 3_000_000)

func testAnchor(_ id: String) -> Anchor {
    Anchor(
        source: "fixture-a",
        turn: Turn(id: id, role: "user", timestamp: Date(), text: "合成候選文字 \(id)，長度足夠切出 span。"),
        span: 0..<8)
}

func candidates(_ ids: [String], band: Int = 0) -> [Candidate] {
    ids.enumerated().map {
        Candidate(anchor: testAnchor($1), baseScore: 1.0 - Double($0) * 0.01, band: RelevanceBand(rank: band))
    }
}

func projection(_ entries: [(Anchor, [EventKind: Int])]) -> Projection {
    var stats: [Anchor: AnchorStatistics] = [:]
    for (anchor, counts) in entries {
        let opened: Int = counts[.opened] ?? 0
        let cited: Int = counts[.cited] ?? 0
        let pinned: Int = counts[.pinned] ?? 0
        let dismissed: Int = counts[.dismissed] ?? 0
        let reinforcement = Double(opened) + Double(cited) * 2 + Double(pinned) * 3
        let suppression = Double(dismissed) * 2
        stats[anchor] = AnchorStatistics(
            reinforcement: reinforcement, suppression: suppression, impressions: 0,
            lastDeliberateInteraction: instant, deliberateCounts: counts)
    }
    return Projection(statistics: stats, instant: instant)
}

/// 只做恆等的最小策略，用來驗 seam 本身的契約（不是 archival 的替身——那個
/// 有自己的測試）。
private struct IdentityProbe: MemoryStrategy {
    let id = RankingPolicyID("identity-probe")
    let consumedSignals: Set<EventKind> = []
    func rerank(_ candidates: [Candidate], with projection: Projection) throws -> [RankedResult] {
        candidates.map { RankedResult(candidate: $0, displacement: 0, reason: .noAdjustment) }
    }
}

@Test func rerankReturnsAPermutationOfItsInput() throws {
    let input = candidates(["a", "b", "c", "d"])
    let output = try IdentityProbe().rerank(input, with: .empty(at: instant))

    #expect(output.count == input.count)
    #expect(Set(output.map(\.candidate.anchor)) == Set(input.map(\.anchor)))
}

@Test func everyResultCarriesDisplacementAndReason() throws {
    let input = candidates(["a", "b", "c"])
    let output = try IdentityProbe().rerank(input, with: .empty(at: instant))

    // 零位移也必須有 reason——「沒調整」是一個要被說出口的事實，不是空白。
    for result in output {
        #expect(result.displacement == 0)
        #expect(result.reason == .noAdjustment)
    }
}

@Test func strategyIdentityIsAPolicyIdentifier() {
    #expect(IdentityProbe().id == RankingPolicyID("identity-probe"))
}
