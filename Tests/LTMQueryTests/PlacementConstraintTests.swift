import Foundation
import Testing

@testable import LTMCore
@testable import LTMQuery

// #32：策略的額外條件由 seam 執行，不由被約束者自己執行。
//
// 這一整檔的存在理由是「回歸鎖必須驅動生產路徑」。先前唯一覆蓋 tie-run 約束的
// 測試從不建構策略——它把手工排列直接餵給 `RankingGuard.checkTieRunsOnly`。
// 於是守衛的**邏輯**有覆蓋，守衛**在生產路徑上被呼叫**這件事沒有：實測把
// `ConservativeStrategy` 那一行換掉，67 條測試全綠。
//
// 下面的 conformer 刻意違規，並且**只透過 `rerank`**（seam 的唯一入口）被呼叫。

/// spec example 的候選：band 1 內 `A: 0.5`, `B: 0.5`, `C: 0.3`。
/// 等分區段是 `{A, B}` 與 `{C}`。
private func exampleCandidates() -> [Candidate] {
    [
        Candidate(anchor: testAnchor("A"), baseScore: 0.5, band: RelevanceBand(rank: 1)),
        Candidate(anchor: testAnchor("B"), baseScore: 0.5, band: RelevanceBand(rank: 1)),
        Candidate(anchor: testAnchor("C"), baseScore: 0.3, band: RelevanceBand(rank: 1)),
    ]
}

/// 一個**刻意不守規矩**的策略：照給定順序回傳，宣告什麼由建構時決定。
///
/// 它自己不做任何檢查——這正是重點。守衛存在的全部理由是攔截這種實作，而在
/// #32 之前，這條路徑從來沒有被走過。
private struct MisbehavingStrategy: MemoryStrategy {
    let id = RankingPolicyID("misbehaving")
    /// 觸發測試授權註冊（見 `StrategyRegistry.readyForTesting`）。
    private let authorized = StrategyRegistry.readyForTesting
    let consumedSignals: Set<EventKind> = []
    let displacementBound: Int
    let placementConstraints: Set<PlacementConstraint>
    /// 要回傳的 anchor 順序。
    let order: [String]

    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        var byAnchor: [Anchor: Candidate] = [:]
        for candidate in input.candidates { byAnchor[candidate.anchor] = candidate }
        var originalIndex: [Anchor: Int] = [:]
        for (i, candidate) in input.candidates.enumerated() { originalIndex[candidate.anchor] = i }

        var results: [RankedResult] = []
        for (newIndex, id) in order.enumerated() {
            let anchor = testAnchor(id)
            guard let candidate = byAnchor[anchor], let from = originalIndex[anchor] else {
                continue
            }
            // 自報的 displacement 必須與實際位置變化一致，否則會撞到 seam 的另一條
            // 後置條件而以錯誤的理由變紅——那會讓這條測試「為錯的理由紅」。
            results.append(
                RankedResult(
                    candidate: candidate,
                    displacement: from - newIndex,
                    reason: RankingReason(history: .none, movement: movement(from: from - newIndex))))
        }
        return results
    }

    private func movement(from displacement: Int) -> RankingReason.Movement {
        if displacement > 0 { return .advanced(positions: displacement) }
        if displacement < 0 { return .receded(positions: -displacement) }
        return .unmoved
    }
}

@Test func aDeclaredTieRunConstraintIsEnforcedBySeamOnAViolatingStrategy() throws {
    // spec scenario「A declared constraint is enforced on a strategy that violates it」
    // 與 example table 第二列：宣告 `[.withinTieRuns]`、回傳 `[C, A, B]`。
    //
    // C 從自己的區段 `{C}` 移進 `{A, B}`——策略自己完全沒檢查，seam 必須擋下。
    let strategy = MisbehavingStrategy(
        displacementBound: 2, placementConstraints: [.withinTieRuns], order: ["C", "A", "B"])

    #expect(throws: StrategyViolation.movedAcrossTieRuns) {
        _ = try strategy.rerank(exampleCandidates(), with: .empty(at: instant))
    }
}

@Test func aDeclaredTieRunConstraintAcceptsMovementInsideARun() throws {
    // example table 第一列：宣告 `[.withinTieRuns]`、回傳 `[B, A, C]` → 通過。
    // 沒有這一列，上一條測試可能是因為「seam 擋掉所有重排」而過，而不是因為
    // 它認得區段邊界。
    let strategy = MisbehavingStrategy(
        displacementBound: 2, placementConstraints: [.withinTieRuns], order: ["B", "A", "C"])

    let results = try strategy.rerank(exampleCandidates(), with: .empty(at: instant))
    #expect(results.map(\.candidate.anchor) == [testAnchor("B"), testAnchor("A"), testAnchor("C")])
}

@Test func aStrategyDeclaringNoConstraintIsNotSubjectedToTheTieRunCheck() throws {
    // spec scenario「A strategy that declares no constraint is not subjected to it」
    // 與 example table **第三列**：宣告 `[]`、同樣回傳 `[C, A, B]` → 通過。
    //
    // 這一列是整組測試的關鍵：**同一個輸出**在第一條測試裡被拒、在這裡被接受，
    // 差別只有宣告。它證明宣告真的在 gate，而不是一條對所有策略都成立的規則。
    // **注意這條鎖的是什麼、不是什麼**：它鎖「宣告在 gate」，**不**鎖 extension 的預設
    // 方向。`MisbehavingStrategy` 自帶 stored `placementConstraints`，所以 protocol
    // extension 的預設**從不被諮詢**——把預設翻成 `[.withinTieRuns]` 之後這條照樣過
    // （#32 verify 實測；初版註解在這裡宣稱它會紅，那是錯的）。真正持有預設方向那個
    // 性質的是下面的 `theShippedStrategiesDeclareTheConstraintsTheSpecSays`。
    let strategy = MisbehavingStrategy(
        displacementBound: 2, placementConstraints: [], order: ["C", "A", "B"])

    let results = try strategy.rerank(exampleCandidates(), with: .empty(at: instant))
    #expect(results.map(\.candidate.anchor) == [testAnchor("C"), testAnchor("A"), testAnchor("B")])
}

@Test func theShippedStrategiesDeclareTheConstraintsTheSpecSays() throws {
    // 預設方向的鎖：翻成「預設受約束」時，`human-like` 帶內任意重排會被自己的
    // seam 擋掉——而那個失敗會看起來像策略的 bug。
    #expect(ArchivalStrategy().placementConstraints.isEmpty)
    #expect(HumanLikeStrategy().placementConstraints.isEmpty)
    #expect(ConservativeStrategy().placementConstraints == [.withinTieRuns])
}

// MARK: - #34：授權表是權威，策略的自報只能加碼

/// 宣告會**在呼叫之間變動**的 conformer。
///
/// `MisbehavingStrategy` 用的是 stored property，所以它結構上表現不出跨呼叫
/// 變異——#32 的 verify 正是用一個像這樣的探針證偽了「策略只能選、不能弱化」
/// 那句宣稱。它必須是 class：value type 的 getter 改不了自己的狀態。
private final class AlternatingConstraintStrategy: MemoryStrategy, @unchecked Sendable {
    /// **專屬識別碼，刻意不在 bootstrap 名單裡。**
    ///
    /// 這條測試需要一個授權**非空**的識別碼（要驗的正是「表的約束減不掉」），
    /// 而 bootstrap 把名單裡的每一個都註冊成空集合。若共用 `misbehaving`，
    /// 測試先註冊 `[.withinTieRuns]`、隨後建構 conformer 時 bootstrap 才首次
    /// 初始化並把它蓋回 `[]`——實測過，`static let` 的初始化時機決定了成敗。
    /// 那是「靠順序」的形狀，換一個不重疊的名字就沒有順序可言。
    let id = RankingPolicyID("alternating-probe")
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 4
    let order: [String]

    private let lock = NSLock()
    private var callCount = 0

    /// **偶數次回宣告、奇數次回空集合。** 這正是 #32 那個探針的形狀。
    var placementConstraints: Set<PlacementConstraint> {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return callCount.isMultiple(of: 2) ? [] : [.withinTieRuns]
    }

    init(order: [String]) { self.order = order }

    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        let byID = Dictionary(
            input.candidates.map { ($0.anchor.turnID, $0) }, uniquingKeysWith: { a, _ in a })
        let originalIndex = Dictionary(
            uniqueKeysWithValues: input.candidates.enumerated().map { ($0.element.anchor, $0.offset) })
        return order.enumerated().compactMap { position, turnID in
            guard let candidate = byID[turnID] else { return nil }
            let displacement = (originalIndex[candidate.anchor] ?? position) - position
            return RankedResult(
                candidate: candidate, displacement: displacement,
                reason: RankingReason(
                    history: .none,
                    movement: displacement > 0
                        ? .advanced(positions: displacement)
                        : (displacement < 0 ? .receded(positions: -displacement) : .unmoved)))
        }
    }
}

@Test("宣告在呼叫之間變動時，授權表的約束每一次都套用")
func anAlternatingDeclarationIsComposedAway() throws {
    // 授權必須**非空**——這條要驗的是「表的約束減不掉」。專屬識別碼，用完撤銷。
    StrategyRegistry.registerForTesting(
        RankingPolicyID("alternating-probe"), constraints: [.withinTieRuns])
    defer { StrategyRegistry.unregisterForTesting(RankingPolicyID("alternating-probe")) }

    // `[A: 0.5, B: 0.5, C: 0.3]` → 兩個等分區段 `{A, B}` 與 `{C}`。
    let candidates = exampleCandidates()
    let strategy = AlternatingConstraintStrategy(order: ["C", "A", "B"])  // C 離開自己的區段
    let projection = Projection.empty(at: instant)

    // **每一次**都要拋。先前（讀實例的宣告）第二次會過——#32 的探針實測。
    for call in 1...4 {
        #expect(throws: StrategyViolation.movedAcrossTieRuns) {
            _ = try strategy.rerank(candidates, with: projection)
        }
        _ = call
    }
}

@Test("策略可以給自己加約束，授權表沒要求也算數")
func aStrategyMayHoldItselfToMoreThanItsAuthority() throws {
    // `misbehaving` 的測試授權是空集合（無約束），而實例宣告 tie-run。
    let candidates = exampleCandidates()
    let strategy = MisbehavingStrategy(
        displacementBound: 4, placementConstraints: [.withinTieRuns], order: ["C", "A", "B"])

    #expect(throws: StrategyViolation.movedAcrossTieRuns) {
        _ = try strategy.rerank(candidates, with: .empty(at: instant))
    }
}

@Test("授權表裡沒有的識別碼被具名拒絕，且策略的 rerankChecked 從未被進入")
func anUnknownIdentifierIsRefusedBeforeReranking() throws {
    let candidates = exampleCandidates()
    let strategy = UnregisteredStrategy()

    #expect(throws: StrategyViolation.unauthorizedStrategy(RankingPolicyID("never-registered"))) {
        _ = try strategy.rerank(candidates, with: .empty(at: instant))
    }
    // **斷言下在「有沒有被進入」上，不只是「有沒有拋」**：拒絕必須發生在重排
    // 之前，否則一個未授權的策略仍然跑過了它的邏輯。
    #expect(!strategy.wasEntered.withLock { $0 }, "拒絕必須在 rerankChecked 之前發生")
}

/// 刻意不註冊授權的 conformer。
private final class UnregisteredStrategy: MemoryStrategy, @unchecked Sendable {
    let id = RankingPolicyID("never-registered")
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 1
    let wasEntered = TestRegistryBox(false)

    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        wasEntered.withLock { $0 = true }
        return input.candidates.map {
            RankedResult(
                candidate: $0, displacement: 0,
                reason: RankingReason(history: .none, movement: .unmoved))
        }
    }
}

@Test("三檔出貨策略宣告的約束與它們的授權條目相同——合成對它們是恆等運算")
func theShippedStrategiesMatchTheirAuthority() {
    let shipped: [any MemoryStrategy] = [
        ArchivalStrategy(), HumanLikeStrategy(), ConservativeStrategy(),
    ]
    for strategy in shipped {
        let authorized = StrategyRegistry.authorizedConstraints(for: strategy.id)
        #expect(authorized != nil, "出貨策略 \(strategy.id.value) 必須在授權表裡")
        #expect(
            authorized == strategy.placementConstraints,
            "授權條目與策略自己的宣告不同，合成就不再是恆等運算——見 \(strategy.id.value)")
    }
}

@Test("registry 的識別碼集合與授權表的鍵集合相同")
func theRegistryAndTheAuthorityTableAgreeOnWhichStrategiesExist() {
    for name in StrategyRegistry.known {
        let id = RankingPolicyID(name)
        #expect(StrategyRegistry.make(id) != nil, "\(name) 在 known 裡卻組不出實例")
        #expect(
            StrategyRegistry.authorizedConstraints(for: id) != nil,
            "\(name) 在 known 裡卻沒有授權條目——兩份清單開始漂移了")
    }
}



// MARK: - #34 verify：授權表真正買到的能力，以及它買不到的

/// 冒用出貨識別碼的外來 conformer：宣告 `conservative` 卻不帶約束。
///
/// **這是授權表唯一真正買到的能力**，而先前沒有任何測試涵蓋它（#34 verify，
/// devil's advocate）。原有的 `theShippedStrategiesMatchTheirAuthority` 是一條
/// **等式**，所以表與策略自報一起被清空時它照樣綠——實測：同時拿掉兩邊的
/// `.withinTieRuns`，377 條只紅一條 #32 時代的自報斷言，四條新測試全綠。
///
/// 等式抓得到「兩份漂移」，抓不到「兩份一起被清空」，而後者才是把授權表變成
/// 裝飾的那個動作。這條測試下的是**行為**斷言，不是自報比對。
private struct ImpersonatingStrategy: MemoryStrategy {
    let id = RankingPolicyID("conservative")
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 4
    /// **刻意宣告空集合**——要驗的正是「表的約束減不掉」。
    let placementConstraints: Set<PlacementConstraint> = []

    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        // `[C, A, B]`：C 離開自己的等分區段。
        let byID = Dictionary(
            input.candidates.map { ($0.anchor.turnID, $0) }, uniquingKeysWith: { a, _ in a })
        let original = Dictionary(
            uniqueKeysWithValues: input.candidates.enumerated().map { ($0.element.anchor, $0.offset) })
        return ["C", "A", "B"].enumerated().compactMap { position, turnID in
            guard let candidate = byID[turnID] else { return nil }
            let displacement = (original[candidate.anchor] ?? position) - position
            return RankedResult(
                candidate: candidate, displacement: displacement,
                reason: RankingReason(
                    history: .none,
                    movement: displacement > 0
                        ? .advanced(positions: displacement)
                        : (displacement < 0 ? .receded(positions: -displacement) : .unmoved)))
        }
    }
}

@Test("冒用 conservative 之名的 conformer 在查表之後、重排之前就被具名拒絕")
func impersonatingAShippedIdentifierIsRefusedOutright() throws {
    // **這條斷言在 #37 換過一次，換的方向要記下來。**
    //
    // 原本斷言 `movedAcrossTieRuns`：冒用者被放進來、排完之後才因為跨等分區段
    // 被抓。#37 之後它在**更早**的門口就被擋——自報 `conservative` 而型別不是
    // `ConservativeStrategy`，於是根本沒有機會重排。
    //
    // 改斷言不是遷就實作：更早拒絕是嚴格更強的保證（原本的攔截依賴「它剛好排出
    // 一個違規的順序」，一個冒用身分卻**乖乖照排**的 conformer 從前是通過的）。
    // 但代價要說清楚——見下一條測試。
    do {
        _ = try ImpersonatingStrategy().rerank(exampleCandidates(), with: .empty(at: instant))
        Issue.record("冒用出貨識別碼的 conformer 應該被拒絕")
    } catch let violation as StrategyViolation {
        guard case .impersonatedShippedStrategy(let declared, _) = violation else {
            Issue.record("拒絕的理由應該是冒用，實際是 \(violation)")
            return
        }
        #expect(declared == RankingPolicyID("conservative"), "錯誤要指名它自報的那個識別碼")
    }
}

@Test("測試註冊口減不掉出貨識別碼的授權——同一條合成紀律套用在鉤子自己身上")
func theTestHookCannotSubtractFromAShippedAuthority() throws {
    // #34 verify 抓到的具體缺陷：初版的註冊口是無條件覆蓋，而 lookup 第一行就
    // return——註冊 `conservative` 為空集合會把 tie-run 約束減掉，讓「只為測試」
    // 的鉤子成為本機制要擋的那個洞的新路徑。實測確認過。
    //
    // 第一版修法是 `precondition`，但那**測不到**（trap 不是 Swift error），
    // 實測拿掉它零測試變紅——一條不可能失敗的守衛。現在改成聯集：註冊值與表的
    // 條目相加，於是「減掉」在結構上做不到，而且是可斷言的行為。
    StrategyRegistry.registerForTesting(RankingPolicyID("conservative"), constraints: [])
    defer { StrategyRegistry.unregisterForTesting(RankingPolicyID("conservative")) }

    #expect(
        StrategyRegistry.authorizedConstraints(for: RankingPolicyID("conservative"))
            == [.withinTieRuns],
        "註冊空集合不得減掉表裡的約束")

    // 行為層：即使註冊了空集合，冒用者仍然被擋——**但 #37 之後擋它的不再是聯集**。
    //
    // 誠實記下這條測試因此失去了什麼：冒用檢查在查表之後、聯集使用之前就拒絕，
    // 所以「表的約束減不掉」這件事**不再有經由冒用者的行為觀察窗口**，只剩上面
    // 那條 unit 斷言。這不是保證變弱（更早拒絕更強），是那個性質的執行點上移了。
    //
    // 聯集**另一側**（策略可以往上加）仍有行為鎖，而且不受 #37 影響——
    // `aStrategyMayHoldItselfToMoreThanItsAuthority` 用的是測試識別碼，
    // `make` 對它回 `nil`，冒用檢查因此碰不到它。
    do {
        _ = try ImpersonatingStrategy().rerank(exampleCandidates(), with: .empty(at: instant))
        Issue.record("註冊空集合之後，冒用者仍然應該被拒絕")
    } catch let violation as StrategyViolation {
        guard case .impersonatedShippedStrategy = violation else {
            Issue.record("拒絕的理由應該是冒用，實際是 \(violation)")
            return
        }
    }
}

@Test("registry 的識別碼集合與授權表的鍵集合**互相**涵蓋")
func theRegistryAndTheAuthorityTableCoverEachOther() {
    // 先前只驗 `known ⊆ 表`（單向）。實測把 `known` 砍掉一個識別碼，377 條全綠
    // ——而 `known` 餵的是 CLI 的「可用策略」錯誤訊息，於是一檔組得出來卻不列名
    // 的策略不會被任何測試抓到（#34 verify）。
    //
    // 反向要能驗，表的鍵集合必須列舉得出來。它是 switch 而不是字典，所以這裡
    // 用「已知的全集」對照：任何**不在** `known` 裡的名字都必須查無授權。
    for name in StrategyRegistry.known {
        #expect(
            StrategyRegistry.authorizedConstraints(for: RankingPolicyID(name)) != nil,
            "\(name) 在 known 裡卻沒有授權條目")
        #expect(StrategyRegistry.make(RankingPolicyID(name)) != nil, "\(name) 在 known 裡卻組不出實例")
    }
    // 反向：一個曾經在表裡、但被移出 `known` 的識別碼會被這條抓到。
    for name in ["archival", "human-like", "conservative"] {
        #expect(
            StrategyRegistry.known.contains(name),
            "\(name) 有授權條目／組得出實例，卻不在 known 裡——CLI 的『可用策略』會漏列它")
    }
}

/// `id` 每次讀都換一個**未授權**的名字——用來驗錯誤指名的是被查表的那一個。
private final class ShiftingUnauthorizedIdentity: MemoryStrategy, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var id: RankingPolicyID {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return RankingPolicyID("ghost-\(calls)")
    }
    let consumedSignals: Set<EventKind> = []
    let displacementBound = 0
    let placementConstraints: Set<PlacementConstraint> = []

    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
    {
        input.candidates.map {
            RankedResult(
                candidate: $0, displacement: 0,
                reason: RankingReason(history: .none, movement: .unmoved))
        }
    }
}

@Test("拒絕訊息指名的是被拿去查表的那一個識別碼")
func theRefusalNamesTheIdentifierThatWasActuallyLookedUp() throws {
    // #36 階段 3：先前 seam 讀兩次 `id`——一次查表、一次組錯誤。交替回值的 getter
    // 因此能讓錯誤說「ghost-1 被拒」而實際被查的是 ghost-2。
    //
    // 這條**不是** #37 的修法：`id` 仍是未經驗證的 per-call 自報，跨呼叫仍能換
    // 身分。它鎖住的只有「單次呼叫內部一致」。
    var thrown: StrategyViolation?
    do {
        _ = try ShiftingUnauthorizedIdentity().rerank(exampleCandidates(), with: .empty(at: instant))
    } catch let error as StrategyViolation {
        thrown = error
    } catch {
        Issue.record("預期 StrategyViolation，實得 \(error)")
        return
    }
    guard case .unauthorizedStrategy(let named) = thrown else {
        Issue.record("預期 unauthorizedStrategy，實得 \(String(describing: thrown))")
        return
    }
    // 第一次讀到的是 `ghost-1`，而查表用的就是它。讀兩次的話錯誤會指名 `ghost-2`。
    #expect(
        named.value == "ghost-1",
        "錯誤指名了一個從未被用來查表的識別碼——使用者拿到的線索是錯的")
}
