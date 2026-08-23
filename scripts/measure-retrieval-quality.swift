// measure-retrieval-quality.swift — known-item 檢索品質量測
//
// 用法（它是套件裡的一個 executable target，路徑就是本檔）：
//
//   LTM_CORPUS_ROOT=<語料目錄> LTM_DERIVED_ROOT=<索引目錄> \
//     swift run measure-retrieval [樣本數] [seed]
//
// **兩個環境變數都必須顯式給**（見下方守衛）。少任何一個都會退回預設值——
// 真實語料與生產索引——而查詢路徑會對它做增量續讀：量到的不是你指定的那個
// 索引，中途還在長大，而且不會有任何錯誤訊息。這條守衛與
// `measure-rrf-ties.swift` 是同一條，理由也一樣（#18 verify R1）。
//
// ## 它量什麼，不量什麼
//
// 量的是**檢索**：一個從語料抽出來的查詢，能不能把它被抽出來的那一段找回來，
// 以及排在第幾名。三軌各自報（lexical-only／vector-only／fused）。
//
// **不量策略。** 記憶策略之間的比較需要的是使用歷史與交錯呈現，與本檔完全無關
// （見 `wire-evaluation-machinery` 的 design：兩條評估路徑要的東西相反）。
//
// ## 隱私
//
// 查詢與 gold 指標在過程中被用掉就丟：`KnownItemReport` 的每個欄位都是計數或
// 比率，沒有任何來自語料的東西（`KnownItemHarnessTests` 對序列化後的 bytes
// 下了斷言）。本檔的輸出只印那份聚合。
//
// ## 為什麼三軌走 `RetrievalEngine` 的通道參數，而不是在這裡重算 RRF
//
// 「同一件事有兩個寫者，就是兩份會漂移的規格」。在這裡重寫一份融合，量到的是
// 那份重寫的行為，不是生產路徑的。

import Foundation
import SQLite3

import LTMCore
import LTMEval
import LTMIndex
import LTMService

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("✗ " + message + "\n").utf8))
    exit(1)
}

func nonEmptyEnv(_ name: String) -> String? {
    guard let value = ProcessInfo.processInfo.environment[name] else { return nil }
    return value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value
}

/// 索引背書的抽樣來源。
///
/// 一次把 (rowid, anchor, text) 撈進記憶體：抽樣要能依序號取，而 SQL 的
/// `OFFSET` 在大表上是線性掃描；語料段數是十萬量級，一次撈完遠比抽一次查一次
/// 便宜。**這是評估路徑，不是生產路徑**——生產路徑不會這樣做。
struct IndexedCorpus: KnownItemCorpus {
    let samples: [KnownItemSample]

    var count: Int { samples.count }
    func sample(at index: Int) -> KnownItemSample? {
        samples.indices.contains(index) ? samples[index] : nil
    }

    /// anchor **從索引裡既有的欄位重建**，與 `RetrievalEngine.loadChunk` 逐欄一致。
    ///
    /// 不在這裡重新計算內容雜湊：那會是同一件事的第二個寫者，而它一旦與寫入端
    /// 對正規化的處理有半點出入，gold 就永遠比不中任何檢索結果——症狀是「recall
    /// 全部掛零」，看起來像檢索壞了。
    static func load(from database: IndexDatabase) throws -> IndexedCorpus {
        var samples: [KnownItemSample] = []
        var skippedRows = 0
        try database.query(
            """
            SELECT uuid, project_fingerprint, anchor_hash, anchor_span_lower,
                   anchor_span_upper, text
            FROM chunks
            """, bind: []
        ) { statement in
            func text(_ column: Int32) -> String {
                guard let raw = sqlite3_column_text(statement, column) else { return "" }
                let count = Int(sqlite3_column_bytes(statement, column))
                return String(decoding: UnsafeBufferPointer(start: raw, count: count), as: UTF8.self)
            }
            let uuid = text(0)
            let fingerprint = text(1)
            let hashHex = text(2)
            let lower = Int(sqlite3_column_int64(statement, 3))
            let upper = Int(sqlite3_column_int64(statement, 4))
            let body = text(5)
            // 索引是磁碟上的外來資料：損壞的列跳過、**計數**，不 trap。
            guard let hash = try? ContentHash(validating: hashHex),
                (try? Anchor.validate(lower: lower, upper: upper)) != nil,
                (try? OpaqueIdentifier.validate(fingerprint)) != nil,
                (try? OpaqueIdentifier.validate(uuid)) != nil
            else {
                skippedRows += 1
                return
            }
            samples.append(
                KnownItemSample(
                    anchor: Anchor(
                        source: fingerprint, turnID: uuid, contentHash: hash,
                        span: lower..<upper),
                    text: body))
        }
        if skippedRows > 0 {
            print("⚠ 索引裡有 \(skippedRows) 列無法重建 anchor，已排除在母體之外")
        }
        return IndexedCorpus(samples: samples)
    }
}

@main
enum Measure {
    static func main() throws {
let arguments = CommandLine.arguments
let sampleSize = arguments.count > 1 ? (Int(arguments[1]) ?? 0) : 500
guard sampleSize > 0 else { die("樣本數必須是正整數（收到：\(arguments.count > 1 ? arguments[1] : "")）") }
let seed = arguments.count > 2 ? (UInt64(arguments[2]) ?? 0) : 42

let corpusRoot = nonEmptyEnv("LTM_CORPUS_ROOT")
let derivedRoot = nonEmptyEnv("LTM_DERIVED_ROOT")
if corpusRoot == nil || derivedRoot == nil {
    die(
        """
        LTM_CORPUS_ROOT 與 LTM_DERIVED_ROOT 都必須顯式指定（空字串視同未設）。
          LTM_CORPUS_ROOT  = \(corpusRoot ?? "（未設）")
          LTM_DERIVED_ROOT = \(derivedRoot ?? "（未設）")
        缺任何一個時，該根會取預設值（真實語料 / 生產索引），量到的不是你指定的
        那個索引，而且不會有任何錯誤訊息。兩邊都不設時尤其糟。
        """)
}

// 衍生根的檔案佈局（DB 檔名、側車檔名）由 `DerivedLocation` 擁有，這裡**不重寫
// 一份**：寫死 "index.sqlite3" / "vectors.f32" 就是第二個寫者，而它第一次就錯了
// （實際的側車叫 `vectors.bin`），症狀是「側車筆數不符」這個看起來像資料損壞的
// 錯誤訊息。containment policy 也沿用生產那一份。
let location = try DerivedLocation(
    root: URL(fileURLWithPath: derivedRoot!),
    policy: MemoryCorpusPolicy(corpusRoots: [URL(fileURLWithPath: corpusRoot!)]))
guard FileManager.default.fileExists(atPath: location.databaseURL.path) else {
    die("索引不存在（\(location.databaseURL.path)）。先跑 `ltm build`。")
}

let database = try IndexDatabase(path: location.databaseURL.path)
defer { database.close() }

let embedder = try ContextualEmbeddingProvider()
guard let indexedRevision = try database.stamps().embeddingRevision else {
    die("索引沒有 embedding revision 戳記。請跑 `ltm build --full`。")
}
guard indexedRevision == embedder.revision else {
    die(
        """
        索引的 embedding revision（\(indexedRevision)）與執行環境（\(embedder.revision)）不同代。
        跨 revision 的 cosine 不會報錯，只會安靜地給出無意義的距離——這裡拒答。
        """)
}

let dimension = try database.meta("vector_dimension").flatMap(Int.init) ?? embedder.dimension
let declaredVectors = try database.meta("vector_count").flatMap(Int.init) ?? 0
var vectors: VectorSidecar?
if declaredVectors > 0 {
    guard let opened = try? VectorSidecar.open(url: location.vectorsURL, dimension: dimension),
        opened.count == declaredVectors
    else {
        die("向量側車與索引宣稱的筆數不符——vector-only 這一軌會靜默失效，拒絕量測。")
    }
    vectors = opened
}
let engine = RetrievalEngine(database: database, vectors: vectors, embedder: embedder)

print("載入語料…")
let corpus = try IndexedCorpus.load(from: database)
print("可抽樣段數 \(corpus.count)　要求樣本 \(sampleSize)　seed \(seed)")
guard corpus.count > 0 else { die("索引裡沒有可抽樣的段落") }

let recallK = 20
let harness = KnownItemHarness(recallK: recallK, ndcgK: 10)
let report = try harness.run(corpus: corpus, sampleSize: sampleSize, seed: seed) { query in
    func anchors(_ channels: Set<ScoredChunk.Channel>) throws -> [Anchor] {
        try engine.search(query: query, limit: recallK, scope: .allProjects, channels: channels)
            .map(\.anchor)
    }
    return ChannelRankings(
        lexical: try anchors([.trigram, .segment]),
        vector: try anchors([.vector]),
        fused: try anchors(Set(ScoredChunk.Channel.allCases)))
}

// MARK: - 輸出

func percentage(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%.1f%%", value * 100)
}

func mean(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%.3f", value)
}

print("")
print("評到 \(report.scored) 對　跳過 \(report.skipped) 段（導不出可用查詢）")
print("Recall@\(recallK) / nDCG@10（nDCG 只在 recall 到的那些對上平均）")
print("")
print("| 桶 | 對數 | lexical recall | lexical nDCG | vector recall | vector nDCG | fused recall | fused nDCG |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for label in QueryClass.allCases {
    guard let cell = report.byQueryClass[label] else { continue }
    print(
        "| \(label.rawValue) | \(cell.fused.scored) "
            + "| \(percentage(cell.lexical.recallRate)) | \(mean(cell.lexical.meanNDCGAmongRecalled)) "
            + "| \(percentage(cell.vector.recallRate)) | \(mean(cell.vector.meanNDCGAmongRecalled)) "
            + "| \(percentage(cell.fused.recallRate)) | \(mean(cell.fused.meanNDCGAmongRecalled)) |")
}

// 全部合併的一列。**分桶在上、合併在下**，而不是只印合併：#2 實測向量融合的
// 整體增益全部集中在中文雙字桶，只看整體會判成「沒有差異」。
func combined(_ pick: (ChannelAggregates) -> ChannelAggregate) -> ChannelAggregate {
    report.byQueryClass.values.reduce(ChannelAggregate(scored: 0, recalled: 0, ndcgSum: 0)) {
        let cell = pick($1)
        return ChannelAggregate(
            scored: $0.scored + cell.scored, recalled: $0.recalled + cell.recalled,
            ndcgSum: $0.ndcgSum + cell.ndcgSum)
    }
}
let allLexical = combined(\.lexical)
let allVector = combined(\.vector)
let allFused = combined(\.fused)
print(
    "| **全部** | \(allFused.scored) "
        + "| \(percentage(allLexical.recallRate)) | \(mean(allLexical.meanNDCGAmongRecalled)) "
        + "| \(percentage(allVector.recallRate)) | \(mean(allVector.meanNDCGAmongRecalled)) "
        + "| \(percentage(allFused.recallRate)) | \(mean(allFused.meanNDCGAmongRecalled)) |")
    }
}
