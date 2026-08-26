import Foundation
import Testing

@testable import LTMIndex

// #7：查「檢索」召不回「检索」。失效是**安靜的**——使用者只會覺得「沒這回事」。

@Test("繁簡雙向都會產生變體，且原詞永遠在第一個")
func variantsCoverBothDirectionsWithTheOriginalFirst() {
    let fromTraditional = QueryExpansion.variants(of: "檢索策略")
    #expect(fromTraditional.first == "檢索策略", "原詞必須在第一個——排序保證靠它")
    #expect(fromTraditional.contains("检索策略"))

    let fromSimplified = QueryExpansion.variants(of: "检索策略")
    #expect(fromSimplified.first == "检索策略")
    #expect(fromSimplified.contains("檢索策略"))
}

@Test("沒有繁簡差異的查詢只回一個變體，不做無謂的重複查詢")
func queriesWithoutVariantsExpandToThemselves() {
    #expect(QueryExpansion.variants(of: "embedding") == ["embedding"])
    #expect(QueryExpansion.variants(of: "人") == ["人"], "繁簡同形的字不該產生重複")
    #expect(QueryExpansion.variants(of: "") == [])
}

@Test("轉換是離線的——零對外通道")
func expansionIsOffline() {
    // 這條驗不到「沒有連線」，它驗的是**用的是哪個機制**：`CFStringTransform`
    // 是 macOS 內建的字串轉換，不是查表服務。
    //
    // 具名的缺口：一條真正的「沒有對外連線」測試需要攔截網路層，而本 repo 沒有
    // 那個機具。寫在這裡而不是留白——否則下一個人會以為這條測試證明了它。
    //
    // 能驗的是行為的確定性：同樣的輸入永遠給同樣的輸出，且不需要任何外部狀態。
    let first = QueryExpansion.variants(of: "擴散激發")
    let second = QueryExpansion.variants(of: "擴散激發")
    #expect(first == second)
    #expect(first.contains("扩散激发"))
}
