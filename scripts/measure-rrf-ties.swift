// measure-rrf-ties.swift — #18 的一次性量測探針
//
// 問題：`conservative` 在 base score 兩兩相異時可證明等同於 `archival`
// （測試 `conservativeNeverReordersCandidatesWithDifferentBaseScores` 就是在證
// 這件事）。所以**平手發生率就是這一檔的全部價值**，而它沒有量過。
//
// 隱私（CLAUDE.md 鐵律）：查詢集是自行撰寫的通用技術詞彙；本檔與其輸出**只有
// 聚合數字與查詢字串本身**，不含任何命中片段、專案名或 uuid。連解析都不解
// 那些欄位——讀進來就有可能被印出去，不讀是最省事的保證。
//
// ## 為什麼是「跑 CLI 再讀 JSON」而不是在探針裡重算一次 RRF
//
// CLAUDE.md：「同一件事有兩個寫者，就是兩份會漂移的規格」。在探針裡重寫一份
// 融合，量到的會是那份重寫的平手率，不是生產路徑的。所以本檔**不含任何檢索
// 邏輯**——它呼叫 `ltm query --json`，讀回真正的 `score` 與 `band`。
//
// 這條路唯一的疑慮是 JSON 的 Double 序列化會不會把相異值印成相同字串（假平手）
// 或反之（漏掉真平手）。已實測 Foundation 的序列化在 1 ulp 粒度上是單射的：
//
//     1.0 / 65.0           → 0.015384615384615385
//     (1.0 / 65.0).nextUp  → 0.015384615384615387
//
// 相等的值印出相同字串、相差 1 ulp 的印出不同字串，所以 `JSONSerialization`
// 讀回來的 Double 與引擎內部的位元完全相同，精確相等比較是忠實的。
//
// 分桶用**生產環境那一份** `QueryClassifier`（編譯時直接帶入
// `Sources/LTMEval/QueryClass.swift`），不在本檔抄一份分類規則。
//
// 用法：
//   swiftc -O -o /tmp/rrfties scripts/measure-rrf-ties.swift Sources/LTMEval/QueryClass.swift
//   LTM_DERIVED_ROOT=<索引目錄> /tmp/rrfties <ltm 執行檔> scripts/rrf-tie-queries.txt [k]
//
// 入口寫成 `@main` 而不是 top-level code：多檔編譯時只有 `main.swift` 能放
// top-level，而本檔必須與 `QueryClass.swift` 一起編才拿得到生產的分類器。

import Foundation

/// 一筆命中裡本量測用得到的部分。
struct Hit {
    let score: Double
    let band: Int
}

/// 一個查詢的量測結果。
struct QueryStats {
    let klass: QueryClass
    let hitCount: Int
    /// 相鄰配對總數（`hitCount - 1`，不足兩筆時為 0）
    let adjacentPairs: Int
    /// 相鄰且 **score 相等**——issue #18 原文的判準
    let adjacentTiedByScore: Int
    /// 相鄰且 **(band, score) 都相等**——`ConservativeStrategy` 實際用的判準。
    /// 兩者刻意分開報：band-major 排序讓帶界上可能出現「分數相同但不同帶」的
    /// 相鄰對，那種對策略**不作用**，只看 score 會高估這一檔的作用面。
    let adjacentTiedByBandAndScore: Int
    /// 長度 ≥ 2 的平手區段長度（依 (band, score) 切）
    let runLengths: [Int]
}

func percent(_ numerator: Int, _ denominator: Int) -> String {
    denominator == 0
        ? "n/a"
        : String(format: "%.1f%%", 100.0 * Double(numerator) / Double(denominator))
}

func analyse(_ hits: [Hit], klass: QueryClass) -> QueryStats {
    var tiedByScore = 0
    var tiedByBoth = 0
    if hits.count >= 2 {
        for index in 1..<hits.count where hits[index].score == hits[index - 1].score {
            tiedByScore += 1
            if hits[index].band == hits[index - 1].band { tiedByBoth += 1 }
        }
    }

    // 極大區段：連續且 (band, score) 完全相同。**長度 1 的不算**——一個候選的
    // 區段裡沒有東西可以互換，對 tie-breaker 毫無意義（#18 明寫這一點）。
    var runLengths: [Int] = []
    var start = 0
    while start < hits.count {
        var end = start + 1
        while end < hits.count,
            hits[end].band == hits[start].band,
            hits[end].score == hits[start].score
        { end += 1 }
        if end - start >= 2 { runLengths.append(end - start) }
        start = end
    }

    return QueryStats(
        klass: klass, hitCount: hits.count, adjacentPairs: max(hits.count - 1, 0),
        adjacentTiedByScore: tiedByScore, adjacentTiedByBandAndScore: tiedByBoth,
        runLengths: runLengths)
}

/// 跑一次真正的查詢。回 `nil` 代表這一筆**失敗**（與「命中 0 筆」不同，見呼叫端）。
func runQuery(_ query: String, ltmPath: String, k: Int) -> [Hit]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ltmPath)
    process.arguments = ["query", query, "--json", "--k", String(k), "--all-projects"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return nil }
    // 先讀完再 wait：pipe 緩衝滿了會讓子行程卡在 write、父行程卡在 wait 上。
    let data = out.fileHandleForReading.readDataToEndOfFile()
    _ = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
        let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return nil }

    var hits: [Hit] = []
    for object in objects {
        // 缺欄位整筆查詢作廢，而不是跳過這一列：少一列會讓相鄰關係接錯，
        // 而接錯是無聲的——平手率會偏掉而沒有任何訊號。
        guard let score = object["score"] as? Double, let band = object["band"] as? Int
        else { return nil }
        hits.append(Hit(score: score, band: band))
    }
    return hits
}

@main
enum Probe {
    static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("✗ " + message + "\n").utf8))
        exit(1)
    }

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)

        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { die("用法：rrfties <ltm 執行檔> <查詢檔> [k]") }
        let ltmPath = arguments[1]
        let queriesPath = arguments[2]
        let k = arguments.count > 3 ? (Int(arguments[3]) ?? 20) : 20

        guard FileManager.default.isExecutableFile(atPath: ltmPath) else {
            die("`\(ltmPath)` 不是可執行檔。先跑 `swift build -c release`。")
        }
        guard let raw = try? String(contentsOfFile: queriesPath, encoding: .utf8) else {
            die("讀不到查詢檔 `\(queriesPath)`")
        }

        // 兩個根只設一個，是**不會報錯**的誤設：查詢路徑會拿預設的另一個根，
        // 於是每次查詢都對真實語料做一次增量續讀——量到的索引不是你以為的那個，
        // 而且中途還在長大。實際踩過：只設 `LTM_DERIVED_ROOT` 時，單一查詢跑了
        // 三分鐘 CPU 仍未返回（它在掃 5 GB 語料），而測量本身不會有任何抱怨。
        let environment = ProcessInfo.processInfo.environment
        let corpusRoot = environment["LTM_CORPUS_ROOT"]
        let derivedRoot = environment["LTM_DERIVED_ROOT"]
        if (corpusRoot == nil) != (derivedRoot == nil) {
            die("""
                LTM_CORPUS_ROOT 與 LTM_DERIVED_ROOT 必須同時設定或同時不設。
                  LTM_CORPUS_ROOT  = \(corpusRoot ?? "（未設）")
                  LTM_DERIVED_ROOT = \(derivedRoot ?? "（未設）")
                只設一個時，另一個會取預設值，查詢會對不相干的語料做增量續讀——
                量到的不是你指定的那個索引，而且不會有任何錯誤訊息。
                """)
        }
        let queries = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !queries.isEmpty else { die("查詢檔裡沒有查詢") }

        var stats: [QueryStats] = []
        var failed: [String] = []
        var empty: [String] = []

        for (index, query) in queries.enumerated() {
            FileHandle.standardError.write(Data("[\(index + 1)/\(queries.count)] \(query)\n".utf8))
            guard let hits = runQuery(query, ltmPath: ltmPath, k: k) else {
                failed.append(query)
                continue
            }
            if hits.isEmpty { empty.append(query) }
            stats.append(analyse(hits, klass: QueryClassifier.classify(query)))
        }

        // 失敗要出聲。沉默的跳過等於報告少了東西而沒有人會發現（CLAUDE.md）。
        if !failed.isEmpty {
            print("⚠ \(failed.count) 個查詢執行失敗、未計入：\(failed.joined(separator: "、"))")
            print("")
        }

        print("查詢 \(queries.count)　成功 \(stats.count)　零命中 \(empty.count)　k=\(k)")
        print("")
        print(
            "| 桶 | 查詢數 | 候選數 | 相鄰平手（僅 score） | 相鄰平手（band+score） | "
                + "至少一段平手的查詢 | 平手段數 | 落在平手段內的候選 | 最長段 |")
        print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
        for klass in QueryClass.allCases {
            let group = stats.filter { $0.klass == klass }
            if group.isEmpty { continue }
            emit(klass.rawValue, group)
        }
        emit("**全部**", stats)

        // 段長分佈：長度 2 與長度 8 對 tie-breaker 的意義差很多。
        var histogram: [Int: Int] = [:]
        for length in stats.flatMap(\.runLengths) { histogram[length, default: 0] += 1 }
        if !histogram.isEmpty {
            print("")
            print("| 平手段長度 | 段數 |")
            print("|---:|---:|")
            for length in histogram.keys.sorted() { print("| \(length) | \(histogram[length]!) |") }
        }
    }

    static func emit(_ label: String, _ group: [QueryStats]) {
        let pairs = group.reduce(0) { $0 + $1.adjacentPairs }
        let tiedScore = group.reduce(0) { $0 + $1.adjacentTiedByScore }
        let tiedBoth = group.reduce(0) { $0 + $1.adjacentTiedByBandAndScore }
        let withRun = group.filter { !$0.runLengths.isEmpty }.count
        let runs = group.flatMap(\.runLengths)
        let candidates = group.reduce(0) { $0 + $1.hitCount }
        print(
            "| \(label) | \(group.count) | \(candidates) | \(percent(tiedScore, pairs)) | "
                + "\(percent(tiedBoth, pairs)) | \(percent(withRun, group.count)) | "
                + "\(runs.count) | \(percent(runs.reduce(0, +), candidates)) | \(runs.max() ?? 0) |")
    }
}
