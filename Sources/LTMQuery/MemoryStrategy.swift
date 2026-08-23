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
///
/// ## 兩個**正交**的軸，不是一個列舉
///
/// 這個型別被同一類缺陷咬了三輪，每一輪都是同一個原因：把「這一筆自己的歷史
/// 處於什麼狀態」與「它相對純檢索順序移動了沒有」擠進一個 enum，於是每個
/// case 都在同時宣稱兩件事，而其中一件常常是錯的。
///
/// - **R3**：下移三名的候選回報 `.noAdjustment`——同時聲稱「移動了三名」與
///   「沒有套用任何調整」。
/// - **R4**：修法寫成 `positions: -displacement`，假設沒有歷史的候選只會下移。
///   錯了——`dismissed` 讓鄰居的 netStrength 變負，於是它會相對**上移**，
///   而 reason 回報負數。修法在自己所修缺陷的鏡像上重演了同一件事。
/// - **R5**：兩個變體同時還在。(a) 自己有正向歷史、卻被更強的鄰居壓下去的
///   候選收到 `.adjusted`，而那個 case 的 doc 逐字寫「**被使用歷史上推**」；
///   (b) orphan 分支在最上面無條件 return，於是一筆實際被鄰居擠動的 orphan
///   只回報「歷史不計入」，沒有方向、也沒有說明它為何移動；(c) reinforcement 2
///   與 suppression 2 相抵的候選被歸進「自己沒有歷史」那一支。
///
/// 三輪都在補 case，而缺陷是**結構**：一個值域無法忠實表達兩個獨立的事實。
/// 所以改成兩個欄位。
///
/// ## 刻意不宣稱因果
///
/// `Movement` 只說方向與幅度，不說「因為誰」。這是誠實邊界：一筆候選上移，
/// 可能是自己的歷史夠強、可能是鄰居被 `dismissed` 壓下去、也可能兩者都有份，
/// 而有界重排的逐輪交換不保留足以區分它們的資訊。上一版硬要在標籤裡回答
/// 「因為誰」，三輪的錯都出在那個回答上。`history` 給出這一筆自己的訊號，
/// `movement` 給出實際發生的位移，消費端要下因果結論時自己承擔。
public struct RankingReason: Sendable, Equatable {
    /// 這一筆**自己的**使用歷史處於什麼狀態。
    public enum History: Sendable, Equatable {
        /// 沒有計入的歷史。**包含「有事件但淨強度為零」**（例如 reinforcement 與
        /// suppression 相抵）——所以它的語意是「歷史沒有讓它動」，不是「從沒被用過」。
        case none
        /// 有計入的歷史。`signals` 指名是哪些事件。
        case counted(signals: [EventKind: Int], netStrength: Double)
        /// **anchor 不再解析得到原本的文字**，所以它的任何事件都不計入。
        ///
        /// 措辭刻意不說「有歷史」（#1 verify R5）：orphan 是 anchor 的性質，
        /// 不是歷史的性質。一個只有 `shown` 事件的 anchor 也會落在這裡，而
        /// spec 明寫「只有曝光等同於沒有事件」——舊措辭會讓那種情形讀成
        /// 「它有深思熟慮的歷史，只是被忽略了」。
        case orphaned
    }

    /// 相對於純檢索順序，它移動了沒有、往哪邊。
    public enum Movement: Sendable, Equatable {
        case unmoved
        /// 上移（索引變小）。`positions` 為正。
        case advanced(positions: Int)
        /// 下移。`positions` 為正，方向由 case 本身表達。
        case receded(positions: Int)
    }

    public let history: History
    public let movement: Movement

    public init(history: History, movement: Movement) {
        self.history = history
        self.movement = movement
    }

    /// 由 projection 與實際位移組出 reason。**所有策略共用這一條**——
    /// 三檔各自寫一份 switch 正是前三輪變體長出來的地方。
    public static func describing(
        _ anchor: Anchor, displacement: Int, in projection: Projection
    ) -> RankingReason {
        let history: History
        if projection.isOrphaned(anchor) {
            history = .orphaned
        } else if let stats = projection[anchor], stats.netStrength != 0 {
            history = .counted(signals: stats.deliberateCounts, netStrength: stats.netStrength)
        } else {
            history = .none
        }

        let movement: Movement =
            displacement > 0
            ? .advanced(positions: displacement)
            : (displacement < 0 ? .receded(positions: -displacement) : .unmoved)

        return RankingReason(history: history, movement: movement)
    }
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
    /// 某個位置上的帶與原順序不符。
    ///
    /// 參數叫 `expected`／`found` 而不是 `from`／`to`（#1 verify R5）：後者讀起來
    /// 是「這一筆從 X 移到 Y」，而實際帶進去的是「這個位置本來該是哪個帶」與
    /// 「現在是哪個帶」。對 `[a(帶0), z(帶1)] → [z, a]`，z 從沒離開帶 1，舊的
    /// 命名卻報 `from: 1, to: 0`。這個檔案裡有一個 `misreportedDisplacement`
    /// 專門為了「provenance 不得說謊」而存在，而這是一個讀反的 provenance 欄位。
    case crossedRelevanceBand(expected: RelevanceBand, found: RelevanceBand)
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
    /// 策略回報的 displacement 與實際位置變化不符。
    ///
    /// 這條的存在理由與 `crossedRelevanceBand` 一樣：provenance 若可以說謊，
    /// 比較實驗讀到的就不是實際發生的事。先前沒有任何地方驗它——策略自己算
    /// displacement、自己回報，守衛只看順序（#1 verify R4）。
    case misreportedDisplacement(Anchor, reported: Int, actual: Int)
    /// 策略回報的 `reason.movement` 與實際位置變化不符。
    ///
    /// `displacement` 與 `movement` 陳述同一件事，所以兩個都要驗——R5 只驗了
    /// 前者（#1 verify R6）。
    case misreportedMovement(
        Anchor, reported: RankingReason.Movement, actual: RankingReason.Movement)
    /// projection 裡的統計形狀不合法（非有限值或負值）。
    ///
    /// seam 先前只驗 `Candidate.baseScore` 的有限性，projection 側完全不驗
    /// （#1 verify R5）。一個 NaN 的 netStrength 會讓
    /// `boundedReorderByStrength` 的 `>` 恆偽——不拋錯、不重排，`human-like`
    /// 對那一帶靜默退化成 `archival`，而被大量引用的 anchor 永遠卡在 NaN
    /// 鄰居後面。R3 修的是 base score 那一側，這是同一個根因的另一側。
    case malformedStatistics(Anchor, AnchorStatistics.Malformation)
    /// 策略宣告了負的位移上限。
    case negativeDisplacementBound(Int)
    /// 輸入的相關性帶不是非遞減的。
    ///
    /// 帶要能當圍籬，同一個帶必須在輸入裡形成單一連續區段。#1 verify R5 給了
    /// 反例：`[A(帶0), B(帶1), C(帶0)]` → `[C, B, A]`，逐位的帶序列都還是
    /// `[0,1,0]`、候選集合沒變、位移在上限內，守衛全部放行——但 A 與 C 都跨過了
    /// 帶 1 的 B。守衛的逐位比對只在帶連續時才等價於圍籬，而那個前提從來沒有
    /// 被驗證過。與其把圍籬檢查改成 O(n²) 的兩兩比較，不如在入口要求輸入有序
    /// ——檢索本來就是照相關性排出來的，非遞減是它真實的形狀。
    case bandsOutOfOrder(at: Int)
}

/// 進到 `rerankChecked` 的入場券。
///
/// ## 它是 capability，不是 proof——**seam 仍然可以被繞過**
///
/// R5 在這裡寫的是「`init` 是 internal，所以模組外造不出這個型別的值，也就
/// 呼叫不到 `rerankChecked`……是型別層的不可達」。**第二個子句不從第一個推出，
/// 而且是假的**（#1 verify R6，devils-advocate 在 worktree 外另建一個沒有
/// `@testable` 的 package 實測）：
///
/// 這個型別的設計就是把 token 交給**每一個** conformer。一個合法的外部
/// conformer 在自己的 `rerankChecked` 裡把收到的 `input` 存進一個 box——
/// `ValidatedCandidates` 是 `public` 且 `Sendable`，這是合法無警告的一行——
/// 之後模組外就能拿那個 token 直接呼叫任何策略的 `rerankChecked`，
/// 前置條件、排列性、帶保持、位移上限、displacement 誠實性**全部跳過**。
/// 實測一個回傳 3 筆（輸入 5 筆）的策略沒有觸發 `candidateSetChanged`。
///
/// ## 所以正確的陳述是
///
/// **前置與後置條件只在呼叫端走 `rerank` 時成立。** 走 `rerankChecked` 的
/// 呼叫端不受任何約束。這個型別把「不小心繞過」變得需要刻意為之（要先取得
/// token），但它擋不住刻意。
///
/// 要真正關掉，token 必須綁死在該次呼叫上（不可儲存、不可轉手），或者
/// `rerankChecked` 完全不能是 public requirement。兩者都是介面層的重新設計，
/// 追蹤於 #14（該 issue 已在追蹤「seam 的 SHALL NOT 沒有執行點」）。
///
/// 在那之前，**消費端不得因為「seam 保證過了」而省掉自己的檢查**——交錯器
/// 正是這樣刪掉自己那道排列檢查的，而它依據的就是上面那句假宣稱。
public struct ValidatedCandidates: Sendable {
    public let candidates: [Candidate]
    init(_ candidates: [Candidate]) { self.candidates = candidates }
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

    /// projection 的統計必須是有限的非負值。
    ///
    /// 驗**整份** projection 而不只是候選涉及的 anchor：一筆壞統計即使這次沒被
    /// 用到，下一次查詢就會用到，而那時錯誤會出現在另一個地方、看起來像另一個
    /// 問題。在唯一無條件會跑的位置一次驗完。
    public static func requireWellFormedStatistics(_ projection: Projection) throws {
        for (anchor, stats) in projection.statistics {
            if let problem = stats.malformation {
                throw StrategyViolation.malformedStatistics(anchor, problem)
            }
        }
    }

    /// 相關性帶必須非遞減。
    ///
    /// 這是**圍籬能成立的前提**，不是格式潔癖：守衛用逐位比對驗帶，而逐位比對
    /// 只在「同一個帶在輸入裡是單一連續區段」時才等價於「不得跨帶移動」。
    /// R5 的反例見 `StrategyViolation.bandsOutOfOrder`。
    public static func requireBandsInOrder(_ candidates: [Candidate]) throws {
        for i in 1..<max(candidates.count, 1) where candidates[i].band < candidates[i - 1].band {
            throw StrategyViolation.bandsOutOfOrder(at: i)
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
/// 一個策略可以宣告、但**不能定義**的放置約束。
///
/// ## 為什麼是封閉 enum 而不是策略提供的述詞
///
/// 這個型別的每一個 case 都由 seam 自己實作，策略只能**選**、不能**定義**。
/// 那正是它與 `MemoryStrategy.displacementBound` 的根本差別：上限的**值**由策略
/// 提供，所以策略可以宣告一個大數字來放寬自己的限制而守衛看不出來；這裡沒有值
/// 可以提供——`RankingGuard` 自己從候選的 `band` 與 `baseScore` 導出等分區段，
/// 兩者在任何策略被呼叫之前就已經在 seam 手上。
///
/// 策略可以**不宣告**某條約束（那是一個寫在介面上、審 spec 時看得到的選擇），
/// 但不能弱化一條它已經宣告的約束。
///
/// ## 這個列舉為什麼不違反「列舉會漏，性質不會」
///
/// 因為它住在 seam 裡，不住在散文裡。每個 case 都有 `RankingGuard` 側的實作，
/// 值域是封閉的，新增一個 case 是**帶著執行它的程式碼一起出貨**的 spec 變更
/// ——而會漏的那種列舉是文件裡的一份清單，沒有任何東西逼它保持完整。同一條窄
/// 例外也涵蓋 `QueryClass` 的封閉五值：值域由系統擁有，呼叫端只能選。
public enum PlacementConstraint: Sendable, Hashable, CaseIterable {
    /// 只能在**等分區段**內重排：區段是「同帶且 base score 完全相等」的極大連續段。
    ///
    /// 由 `RankingGuard.checkTieRunsOnly` 執行，區段的切法由該處的
    /// `tieRunIdentifiers` 決定——本模組不另寫第二份。
    case withinTieRuns
}

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

    /// 這個策略在**什麼條件下**才可以移動候選——策略軸的另外一半。
    ///
    /// 上面那條 doc 說策略軸是「消費哪些訊號」加上「在什麼條件下作用」，而在
    /// 這個成員出現之前，**只有前半有宣告點**。於是 `conservative` 的等分區段
    /// 條件只活在它自己的 `rerankChecked` 內部，唯一能執行它的地方就是策略自己
    /// ——被約束者執行自己的約束（#32）。
    ///
    /// **宣告不帶任何資料。** `RankingGuard` 從候選的 `band` 與 `baseScore` 自己
    /// 導出等分區段，兩者在任何策略被呼叫之前就在 seam 手上。所以策略只是在
    /// **選**哪些檢查適用於它，無法弱化一條已宣告的約束。這是它與
    /// `displacementBound` 的分野：那個由策略提供**值**，所以那個洞還開著
    /// （見該成員的說明，那裡是 source of truth）。
    ///
    /// 預設是空集合（見下方 extension）。方向是刻意的：預設成「受約束」會讓
    /// `human-like` 正確的輸出被自己的 seam 擋掉，而那個失敗看起來像策略的 bug；
    /// 預設成「不受約束」時，忘記宣告的新策略是**檢查不足**——那在對照 spec
    /// 審查時看得見，而不是在執行期以錯誤的拒絕出現。
    var placementConstraints: Set<PlacementConstraint> { get }

    /// 這個策略最多能把一筆結果移動幾個名次（雙向）。
    ///
    /// ## 這條**改善了兩件事，沒有改善第三件**，說清楚以免再被誤述
    ///
    /// 改善的：(a) 上限現在對**每一個**策略都會被套用，不需要策略自己記得
    /// 呼叫守衛；(b) `archival` 宣告 0，於是「它從不重排」變成守衛會擋的事。
    ///
    /// **沒有改善的**：值仍然由策略自己給。R5 的 doc 寫「上限不再由被約束者
    /// 提供……那個洞在結構上關掉了」——那是錯的（#1 verify R6 實測）。
    /// 「從 protocol 讀」就是「從策略讀」：R4 是策略把值當引數傳給守衛，
    /// R5 是 seam 讀策略的欄位，**來源相同，只換了管線**。R5 自己寫在下面
    /// 當作論證的那個反例（`[A,B,C,D,E]` → `[E,A,B,C,D]`、回報
    /// `[4,-1,-1,-1,-1]`）現在仍然通過——策略宣告 `displacementBound = 4` 即可。
    ///
    /// 要真的關掉，spec 得先回答「**誰有權決定上限**」（設定檔／呼叫端／
    /// 註冊表），而不是讓策略自報。那是尚未做出的設計決定，記在 #16。
    var displacementBound: Int { get }

    /// 這個策略要不要套用擴散激發（同框呈現群組間的間接 reinforcement）。
    ///
    /// 預設 `false`（透過下面的 extension）。擴散的 spec 授權只給
    /// `human-like`（見 `memory-strategy` spec「The human-like tier spreads
    /// reinforcement to co-presented anchors, one hop only」），但擴散的
    /// **機制**住在共用的 `project()`（`LTMMemory/Projection.swift`）——那個
    /// 函式一次摺完所有策略都要讀的統計，不為每個策略分別摺（同一件事兩個
    /// 寫者的教訓見 CLAUDE.md）。這個宣告是服務層知道「該不該把非零的
    /// `spreadingActivationFactor` 傳進 `ProjectionParameters`」的唯一依據——
    /// `LTMService.makeProjection` 讀它決定傳 0 還是預設值，`0` 沿用
    /// `Projection.swift` 既有文件語意「0 等於關閉擴散」。
    ///
    /// 先前沒有這個宣告：`makeProjection` 對任何 `consumedSignals` 非空的策略
    /// 一律用 `.default`（含非零 `spreadingActivationFactor`）建 projection，
    /// `conservative` 因為與 `human-like` 共用訊號集合而意外吃到擴散——
    /// spec 從未授權這件事（#15 verify HIGH finding）。
    var appliesSpreadingActivation: Bool { get }

    /// **實作點，不是呼叫點。** 呼叫端一律用 `rerank`。
    ///
    /// 參數型別是 `ValidatedCandidates` 而不是 `[Candidate]`，因為那個型別的
    /// `init` 是 internal——模組外造不出它，也就呼叫不到這個方法。R5 指出
    /// 上一版把它宣告成收 `[Candidate]` 的 public requirement，於是「不可繞過的
    /// seam」被一行正常 API 呼叫繞過。
    func rerankChecked(_ input: ValidatedCandidates, with projection: Projection) throws
        -> [RankedResult]
}

extension MemoryStrategy {
    /// 預設不套用擴散——新增這個 requirement 不需要既有 conformer 逐一表態。
    /// 只有 `HumanLikeStrategy` 覆寫為 `true`。
    public var appliesSpreadingActivation: Bool { false }

    /// 預設**不宣告任何額外條件**——既有 conformer 不需逐一表態，且方向刻意如此
    /// （理由見 protocol 上該成員的說明）。`ConservativeStrategy` 覆寫它。
    public var placementConstraints: Set<PlacementConstraint> { [] }
}

extension MemoryStrategy {
    /// seam 的**唯一**呼叫點：前置條件、實作、後置條件。
    ///
    /// ## 為什麼是 extension 而不是 protocol requirement
    ///
    /// `rerank` 刻意**不在** protocol 的需求清單裡，所以它不是 customization
    /// point：任何經由 `any MemoryStrategy` 的呼叫都必然走這裡，實作者無法用
    /// 覆寫把檢查繞掉。這是型別層的事實，不是紀律。
    ///
    /// #1 verify R4 指出前一版把這叫做「seam 入口」是假的：
    /// `requireFiniteBaseScores` 與 `RankingGuard` 都由每個策略**自願**呼叫，
    /// 新策略只要不呼叫就完全不受約束——而 seam 的全部意義就是「不可繞過」。
    /// 那時的「入口」只是一個約定俗成的第一行。
    ///
    /// **誠實邊界**：這些檢查只在呼叫端走 `rerank` 時執行。`rerankChecked` 是
    /// public requirement，任何持有 `ValidatedCandidates` 的人都能直接呼叫它而
    /// 跳過全部檢查——那個 token 可儲存、可轉手（見該型別的說明，R6 實測）。
    /// 具體型別上另外定義同名 `rerank` 也仍會被靜態呼叫選中。追蹤於 #14。
    public func rerank(_ candidates: [Candidate], with projection: Projection) throws
        -> [RankedResult]
    {
        // 負的上限是**外來策略給的值**，不是程式錯誤——所以 throw 而不是 trap。
        // `RankingGuard.check` 裡的 `precondition(bound >= 0)` 會讓一個宣告
        // `displacementBound = -1` 的合規 conformer 中止行程（#1 verify R6）。
        guard displacementBound >= 0 else {
            throw StrategyViolation.negativeDisplacementBound(displacementBound)
        }
        try MemoryStrategySupport.requireFiniteBaseScores(candidates)
        try MemoryStrategySupport.requireBandsInOrder(candidates)
        // **只有會消費歷史的策略才受 projection 形狀約束。**
        //
        // R5 把這條寫成無條件，於是 `archival` 會因為一筆它從不讀取的統計而
        // 失敗——而它的契約逐字是「不論給它什麼 projection 都產出相同輸出」，
        // 它存在的理由就是當記憶層本身可疑時仍然可用的對照組（#1 verify R6）。
        // 判準：**一個策略只受它能消費的資料的約束**。
        if !consumedSignals.isEmpty {
            try MemoryStrategySupport.requireWellFormedStatistics(projection)
        }
        let results = try rerankChecked(ValidatedCandidates(candidates), with: projection)

        // 後置條件：排列性、帶保持、**位移上限**、以及每一筆自報的 displacement
        // 等於實際的位置變化。上限走 `check` 而不是 `verifyPermutation`——R5：
        // 上一版把上限留給各策略自願呼叫，於是它不受 seam 約束。
        let placements = try RankingGuard.check(
            original: candidates, reordered: results.map(\.candidate),
            bound: displacementBound)

        // 策略**宣告**的額外條件，由 seam 執行——不是由策略自己執行（#32）。
        //
        // 先前 `conservative` 在自己的 `rerankChecked` 裡呼叫 tie-run 守衛。實測
        // 把那一行換成只驗排列的版本，`LTMQuery` 67 條測試全綠：唯一覆蓋該約束的
        // 測試從不建構策略，它把手工排列直接餵給守衛。**被約束者執行的約束不是
        // 約束**，而測不到生產路徑的回歸鎖不鎖任何東西。
        //
        // 這裡不重算等分區段——切法由 `RankingGuard` 的 `tieRunIdentifiers` 擁有，
        // 本處只呼叫。同一件事兩個寫者就是兩份會漂移的規格。
        for constraint in placementConstraints {
            switch constraint {
            case .withinTieRuns:
                _ = try RankingGuard.checkTieRunsOnly(
                    original: candidates, reordered: results.map(\.candidate))
            }
        }
        for (result, placement) in zip(results, placements) {
            guard result.displacement == placement.displacement else {
                throw StrategyViolation.misreportedDisplacement(
                    result.candidate.anchor,
                    reported: result.displacement, actual: placement.displacement)
            }
            // `movement` 陳述的是**同一件事**，所以同樣要對得上。R5 只驗了兩個
            // 欄位裡的一個（#1 verify R6）——一個策略可以回傳原順序、
            // displacement 全 0，卻附上 `movement: .advanced(positions: 999)`，
            // 而報告會照讀。這與 `misreportedDisplacement` 存在的理由是同一條：
            // provenance 若可以說謊，比較實驗讀到的就不是實際發生的事。
            let expected: RankingReason.Movement =
                placement.displacement > 0
                ? .advanced(positions: placement.displacement)
                : (placement.displacement < 0
                    ? .receded(positions: -placement.displacement) : .unmoved)
            guard result.reason.movement == expected else {
                throw StrategyViolation.misreportedMovement(
                    result.candidate.anchor,
                    reported: result.reason.movement, actual: expected)
            }
        }
        return results
    }
}
