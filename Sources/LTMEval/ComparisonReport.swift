import Foundation
import LTMCore

/// 單一策略在某個切片裡的得分。
public struct StrategyScore: Sendable, Equatable {
    /// opened／cited／pinned 的次數。
    public let credits: Int
    /// dismissed 的次數。記在**當時貢獻該位置的那一邊**頭上。
    public let penalties: Int
    /// 分母：這一邊貢獻了幾個被呈現的位置（由 `shown` 事件計數）。
    public let presented: Int

    public var net: Int { credits - penalties }

    /// per-presentation rate。分母是自己的呈現數，不是互動總數——兩邊貢獻的
    /// 位置數不一定相同，用共同分母會讓貢獻多的那邊被稀釋。
    ///
    /// **分母為零時是 `nil` 而不是 0**（#1 verify R5）。舊版回 0.0，於是一個
    /// 沒有任何 `shown` 事件、卻贏下每一筆被觀測互動的策略，rate 讀作 0.0
    /// ——與從沒得過分的策略在同一欄位上無法區分。而這不是邊角：`presented`
    /// 只由 `.shown` 累加，任何只送 opened／cited 而沒送 shown 的呼叫端，
    /// 每一格都會是那個假的 0.0。
    ///
    /// 這與 `aggregate` 被改成 optional 是同一個理由——**型別要能表達
    /// 「這裡沒有數字」**，否則消費端讀到的是一個看起來很有信心的零。
    public var rate: Double? { presented == 0 ? nil : Double(net) / Double(presented) }
}

/// 一個 query class 的一列。
public struct ClassRow: Sendable, Equatable {
    public let queryClass: QueryClass
    /// 這一類累積了幾次被計分的互動。太少就是太少，要看得見。
    public let observations: Int
    public let scores: [RankingPolicyID: StrategyScore]
}

/// 一個 generation 的一列。
public struct GenerationRow: Sendable, Equatable {
    public let generation: GenerationID
    public let observations: Int
    public let scores: [RankingPolicyID: StrategyScore]
    /// 這個 generation 內的逐類拆解。
    ///
    /// 跨 generation 時頂層 `classRows` 是空的，逐類數字改由這裡提供——
    /// 見 `ComparisonReport.classRows` 的說明。
    public let classRows: [ClassRow]
}

/// 兩策略的比較結果。
///
/// **不存在「只有整體數字」的形態**：`classRows` 是必有的，`aggregate` 只能
/// 伴隨它出現。理由是 #2 的實測——向量融合的整體 +1pp 全部集中在中文雙字桶，
/// 只看整體會判成「沒有差異」。
public struct ComparisonReport: Sendable, Equatable {
    /// 逐類的一列。**跨 generation 時為空**。
    ///
    /// #1 verify R6 的 CRITICAL：先前只有 `aggregate` 在跨 generation 時變 nil，
    /// 而每一個 `ClassRow` 仍然把所有 generation 的 credits／penalties／presented
    /// 加總——`ClassRow` 沒有 generation 欄位，所以那些數字正是 spec 禁止的
    /// 「single figure」。同一份 diff 裡名為
    /// `crossGenerationReportHasNoPooledAggregateAtAll` 的測試，產出的正是一個
    /// 跨兩個 generation 的 `.cjk2char` 列，而它只斷言 `aggregate == nil`。
    ///
    /// 診斷對、只修了兩條聚合路徑中的一條——與 R4／R5 是同一個形狀。
    public let classRows: [ClassRow]
    /// 整體數字。**跨 generation 時為 nil**——spec 寫的是 "Results from different
    /// generations SHALL NOT be silently pooled into a single figure"，而先前把它
    /// 宣告成非 optional，等於型別上根本無法表達「這裡不該有整體數字」，於是
    /// 只讀 aggregate 的消費端會拿到被明文禁止的混合結論。（#1 verify 2026-08-11）
    public let aggregate: StrategyScoreTable?
    /// 資料橫跨一個以上的 generation。
    public let spansGenerations: Bool
    /// 只在 `spansGenerations` 為真時非空。
    public let generationRows: [GenerationRow]
    /// 被**合法**略過的事件數。
    ///
    /// 略過只有兩種合法理由，沒有第三種（#1 verify R4：先前這兩種與兩種資料
    /// 不一致共用同一個 `continue`，四件事一起消失在同一行）。把它們數出來
    /// 是為了讓「這份報告只用到了多少事件」在報告本身讀得到——分母的來源
    /// 不該只存在於讀 code 的人腦中。
    public let skipped: SkippedEvents
    /// 起手方的分派計數。
    ///
    /// **記下來但沒人讀，等於沒記**（#1 verify R5）。R4 把 `startingSide` 寫進
    /// presentation record，理由逐字是「記下來才能事後檢查分派是否平衡」——
    /// 而那個事後檢查沒有任何程式碼實作它，於是「偏誤已消除」仍然是一句
    /// 從報告讀不出來的宣稱。這是 R3→R4 那個「只完成一半」的第三次。
    ///
    /// 這裡只做**可見**：把計數放進報告，讓失衡是讀得到的事實。**按起手方
    /// 分層計分**（真正能校正位置效應的做法）需要先決定分層之後的統計量，
    /// 屬於評估設計，追蹤於 #16。在那之前，讀者至少看得到分派長什麼樣子。
    public let startingSides: StartingSideCounts

    public struct StartingSideCounts: Sendable, Equatable {
        public let a: Int
        public let b: Int
        public init(a: Int, b: Int) {
            self.a = a
            self.b = b
        }

        /// 分派是否嚴重偏向一側。門檻刻意寬鬆（少於四分之一）：這是要讓
        /// 「明顯壞掉」被看見，不是做統計檢定。
        public var isSeverelyImbalanced: Bool {
            let total = a + b
            guard total > 0 else { return false }
            return min(a, b) * 4 < total
        }
    }

    public struct SkippedEvents: Sendable, Equatable {
        /// 事件不屬於任何一次呈現（例如從別處直接引用某段）。
        public let notFromAPresentation: Int
        /// 事件所屬的呈現是 null comparison，依 spec 整批不計分。
        public let fromNullComparison: Int

        public init(notFromAPresentation: Int, fromNullComparison: Int) {
            self.notFromAPresentation = notFromAPresentation
            self.fromNullComparison = fromNullComparison
        }
    }

    public typealias StrategyScoreTable = [RankingPolicyID: StrategyScore]
}

/// 計分時發現的資料不一致。外顯而不是靜默算到別人頭上。
public enum ComparisonDataError: Error, Sendable, Equatable {
    /// 同一個 PresentationID 出現在多筆紀錄上。
    case duplicatePresentationID(PresentationID)
    /// 事件宣稱的 generation 與它所屬呈現紀錄的不一致。
    case generationMismatch(presentation: PresentationID)
    /// 呈現紀錄的 attribution 把位置記給了不屬於這次比較的策略。
    ///
    /// #1 verify R3：先前 scorer 直接信任 `credit(for:)` 回來的任何 policy id，
    /// 於是一筆損壞（或第三方偽造）的紀錄可以把分數記到一個根本沒參與這次
    /// 比較的策略頭上，而報告會照常產出。
    case attributionNamesAThirdStrategy(presentation: PresentationID, policy: RankingPolicyID)
    /// 同一個 anchor 在一次呈現裡出現多次。
    case duplicateAnchorInPresentation(presentation: PresentationID, anchor: Anchor)
    /// 事件指向一個不在 `records` 裡的呈現。
    ///
    /// #1 verify R4：先前這種事件與「本來就不屬於任何呈現的事件」共用同一個
    /// `continue`，於是缺一筆紀錄的後果是**分母悄悄變小**、報告照常產出。
    /// 要對某個子集計分是合理需求，但那要由呼叫端先篩事件，不能讓 scorer
    /// 用「找不到就跳過」去猜。
    case unknownPresentationReference(PresentationID)
    /// 同一份報告裡的紀錄比較了不同的策略對。
    ///
    /// 併成一張表會讓從未互相比較過的兩個策略並列，而讀者無從得知。與
    /// generation 的分軸是同一個道理：不可比的東西不得靜默合併。
    case recordsCompareDifferentStrategyPairs(first: [String], second: [String])
    /// 事件的 anchor 不在它所宣稱那次呈現的 attribution 裡。
    ///
    /// 非 null 的紀錄現在保證每個 anchor 都有歸屬（見 `PresentationRecord`
    /// 的形狀約束），所以查不到只有一個意思：這次呈現根本沒有出示過這個
    /// anchor。那是損壞或偽造，不是略過。
    case anchorNotInPresentation(presentation: PresentationID, anchor: Anchor)
}

public enum ComparisonScorer {
    /// 由呈現紀錄與事件算出報告。
    ///
    /// 計分規則：opened／cited／pinned 算給當時貢獻該位置的那一邊，dismissed
    /// 從那一邊扣，`shown` 只當分母。null comparison 的呈現整批略過——兩邊排序
    /// 相同時，任何歸屬都是憑空造出來的偏好。
    public static func report(
        records: [PresentationRecord],
        events: [Event]
    ) throws -> ComparisonReport {
        // 先前用 `Dictionary(uniqueKeysWithValues:)`，重複 ID 會直接 trap
        // （fatalError）而不是回報錯誤。呈現紀錄來自檔案，重複是資料問題不是
        // 紀錄層的拒絕原因。程式錯誤，必須 throw。（#1 verify 2026-08-11）
        //
        // R5：一份報告裡的紀錄**必須比較同一對策略**。先前不檢查，於是混入
        // A/B 與 B/C 的紀錄會被靜默併成一張表，把從未互相比較過的兩個策略
        // 並列——與同一函式為 generation 建的防護是同一個缺陷類別。
        var pair: Set<RankingPolicyID>?
        var byID: [PresentationID: PresentationRecord] = [:]
        for record in records {
            guard byID.updateValue(record, forKey: record.id) == nil else {
                throw ComparisonDataError.duplicatePresentationID(record.id)
            }
            let thisPair: Set<RankingPolicyID> = [record.strategyA, record.strategyB]
            if let existing = pair, existing != thisPair {
                throw ComparisonDataError.recordsCompareDifferentStrategyPairs(
                    first: existing.map(\.value).sorted(),
                    second: thisPair.map(\.value).sorted())
            }
            pair = thisPair
            // 紀錄本身也要驗，不能只驗事件：損壞或偽造的 attribution 會讓分數
            // 記到沒參與比較的策略頭上，而報告照常產出（#1 verify R3）。
            var seen: Set<Anchor> = []
            for entry in record.attribution {
                guard seen.insert(entry.anchor).inserted else {
                    throw ComparisonDataError.duplicateAnchorInPresentation(
                        presentation: record.id, anchor: entry.anchor)
                }
                if let policy = entry.creditedTo,
                    policy != record.strategyA, policy != record.strategyB
                {
                    throw ComparisonDataError.attributionNamesAThirdStrategy(
                        presentation: record.id, policy: policy)
                }
            }
        }

        var credits: [Key: Int] = [:]
        var penalties: [Key: Int] = [:]
        var presented: [Key: Int] = [:]
        var observations: [QueryClass: Int] = [:]
        var generationObservations: [GenerationID: Int] = [:]
        var generations: Set<GenerationID> = []

        var skippedNotFromAPresentation = 0
        var skippedNullComparison = 0

        for event in events {
            // **每個事件的處置只有三種：計分、合法略過、拒絕。**
            //
            // 上一版寫「封閉列舉，只有這四種，不得類推第五種」，而第五種
            // （`generationMismatch`）就在同一個迴圈往下 12 行——我在寫下封閉性
            // 宣告的同一個函式裡違反了它（#1 verify R5，requirements 與
            // devils-advocate 各自指出）。這次的寫法把「拒絕」當成**一種**處置、
            // 底下列它的原因，於是新增一個拒絕原因不會讓封閉性宣告變成謊話。
            //
            // 合法略過恰有兩種：不屬於任何呈現、屬於 null comparison。
            // 拒絕目前有三個原因：呈現紀錄不存在、anchor 不在該次呈現、
            // 事件自報的 generation 與紀錄不符。另有三個**紀錄層**的拒絕原因
            // 在迴圈之前（重複 PresentationID、歸屬指向第三方策略、同一次呈現
            // 內 anchor 重複）。
            guard let presentationID = event.presentation else {
                skippedNotFromAPresentation += 1  // 合法：不屬於任何呈現
                continue
            }
            guard let record = byID[presentationID] else {
                throw ComparisonDataError.unknownPresentationReference(presentationID)
            }
            // **generation 一致性在 null-comparison 之前驗。** 先前 null 的分支
            // 先 `continue`，於是一筆 generation 對不上的事件只要指向 null 紀錄
            // 就會被洗成「合法略過」——資料不一致偽裝成正常情形（#1 verify R6）。
            guard event.generation == record.generation else {
                throw ComparisonDataError.generationMismatch(presentation: record.id)
            }
            guard !record.isNullComparison else {
                skippedNullComparison += 1  // 合法：兩邊排序相同，不得歸屬
                continue
            }
            guard let policy = record.credit(for: event.anchor) else {
                throw ComparisonDataError.anchorNotInPresentation(
                    presentation: presentationID, anchor: event.anchor)
            }

            // 歸屬用**紀錄**的 generation，不是事件自報的。兩者不一致代表資料
            // 損壞（或事件被錯標），靜默採信事件會讓一次呈現被切成兩半、rate
            // 悄悄歸零。
            generations.insert(record.generation)
            let key = Key(policy: policy, queryClass: record.queryClass, generation: record.generation)

            switch event.kind {
            case .shown:
                presented[key, default: 0] += 1
            case .opened, .cited, .pinned:
                credits[key, default: 0] += 1
                observations[record.queryClass, default: 0] += 1
                generationObservations[record.generation, default: 0] += 1
            case .dismissed:
                penalties[key, default: 0] += 1
                observations[record.queryClass, default: 0] += 1
                generationObservations[record.generation, default: 0] += 1
            }
        }

        let allKeys = Set(credits.keys).union(penalties.keys).union(presented.keys)

        func table(_ filter: (Key) -> Bool) -> ComparisonReport.StrategyScoreTable {
            var result: ComparisonReport.StrategyScoreTable = [:]
            for policy in Set(allKeys.filter(filter).map(\.policy)) {
                let keys = allKeys.filter { filter($0) && $0.policy == policy }
                result[policy] = StrategyScore(
                    credits: keys.reduce(0) { $0 + (credits[$1] ?? 0) },
                    penalties: keys.reduce(0) { $0 + (penalties[$1] ?? 0) },
                    presented: keys.reduce(0) { $0 + (presented[$1] ?? 0) })
            }
            return result
        }

        let classRows = Set(allKeys.map(\.queryClass))
            .sorted { $0.rawValue < $1.rawValue }
            .map { queryClass in
                ClassRow(
                    queryClass: queryClass,
                    observations: observations[queryClass] ?? 0,
                    scores: table { $0.queryClass == queryClass })
            }

        let spans = generations.count > 1
        let generationRows =
            spans
            ? generations.sorted { $0.value < $1.value }.map { generation in
                GenerationRow(
                    generation: generation,
                    observations: generationObservations[generation] ?? 0,
                    scores: table { $0.generation == generation },
                    classRows: Set(allKeys.filter { $0.generation == generation }.map(\.queryClass))
                        .sorted { $0.rawValue < $1.rawValue }
                        .map { queryClass in
                            ClassRow(
                                queryClass: queryClass,
                                observations: observations[queryClass] ?? 0,
                                scores: table {
                                    $0.queryClass == queryClass && $0.generation == generation
                                })
                        })
            }
            : []

        return ComparisonReport(
            // 跨 generation 時頂層逐類列必須是空的：`ClassRow` 沒有 generation
            // 欄位，一個橫跨兩個 generation 的列就是 spec 禁止的 single figure。
            classRows: spans ? [] : classRows,
            // 跨 generation 時**不產出**整體數字，而不是產出一個標了警語的數字。
            // **`classRows` 空時 aggregate 也必須是 nil**（#1 verify R5）。
            // doc、design.md 與 spec 三處都寫「不存在只有整體數字的形態」，
            // 而型別完全沒有阻止它——同一檔的 `nullComparisonsAreExcludedFromScoring`
            // 產出的正是那個被禁止的形狀（classRows 空、aggregate 非 nil）。
            // 不變式寫在三個文件裡而 code 不擋，那是三份會分岔的規格。
            aggregate: (spans || classRows.isEmpty) ? nil : table { _ in true },
            spansGenerations: spans,
            generationRows: generationRows,
            skipped: ComparisonReport.SkippedEvents(
                notFromAPresentation: skippedNotFromAPresentation,
                fromNullComparison: skippedNullComparison),
            startingSides: ComparisonReport.StartingSideCounts(
                a: records.count { $0.startingSide == .a },
                b: records.count { $0.startingSide == .b }))
    }

    private struct Key: Hashable {
        let policy: RankingPolicyID
        let queryClass: QueryClass
        let generation: GenerationID
    }
}
