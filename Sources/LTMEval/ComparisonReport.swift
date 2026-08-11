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
    public var rate: Double { presented == 0 ? 0 : Double(net) / Double(presented) }
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
}

/// 兩策略的比較結果。
///
/// **不存在「只有整體數字」的形態**：`classRows` 是必有的，`aggregate` 只能
/// 伴隨它出現。理由是 #2 的實測——向量融合的整體 +1pp 全部集中在中文雙字桶，
/// 只看整體會判成「沒有差異」。
public struct ComparisonReport: Sendable, Equatable {
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

    public typealias StrategyScoreTable = [RankingPolicyID: StrategyScore]
}

/// 計分時發現的資料不一致。外顯而不是靜默算到別人頭上。
public enum ComparisonDataError: Error, Sendable, Equatable {
    /// 同一個 PresentationID 出現在多筆紀錄上。
    case duplicatePresentationID(PresentationID)
    /// 事件宣稱的 generation 與它所屬呈現紀錄的不一致。
    case generationMismatch(presentation: PresentationID)
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
        // 程式錯誤，必須 throw。（#1 verify 2026-08-11）
        var byID: [PresentationID: PresentationRecord] = [:]
        for record in records {
            guard byID.updateValue(record, forKey: record.id) == nil else {
                throw ComparisonDataError.duplicatePresentationID(record.id)
            }
        }

        var credits: [Key: Int] = [:]
        var penalties: [Key: Int] = [:]
        var presented: [Key: Int] = [:]
        var observations: [QueryClass: Int] = [:]
        var generationObservations: [GenerationID: Int] = [:]
        var generations: Set<GenerationID> = []

        for event in events {
            guard let presentationID = event.presentation,
                let record = byID[presentationID],
                !record.isNullComparison,
                let policy = record.credit(for: event.anchor)
            else { continue }

            // 歸屬用**紀錄**的 generation，不是事件自報的。兩者不一致代表資料
            // 損壞（或事件被錯標），靜默採信事件會讓一次呈現被切成兩半、rate
            // 悄悄歸零。
            guard event.generation == record.generation else {
                throw ComparisonDataError.generationMismatch(presentation: record.id)
            }

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
                    scores: table { $0.generation == generation })
            }
            : []

        return ComparisonReport(
            classRows: classRows,
            // 跨 generation 時**不產出**整體數字，而不是產出一個標了警語的數字。
            aggregate: spans ? nil : table { _ in true },
            spansGenerations: spans,
            generationRows: generationRows)
    }

    private struct Key: Hashable {
        let policy: RankingPolicyID
        let queryClass: QueryClass
        let generation: GenerationID
    }
}
