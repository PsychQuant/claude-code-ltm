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
// ## 分數用「原始 token 字串」比對，不解析成 Double（#18 verify R1）
//
// 這條路唯一的疑慮是 JSON 的 Double 會不會讓相異的分數看起來相等（假平手）或
// 反之（漏掉真平手）。**兩端的答案不一樣**：
//
//   寫入端（引擎 Double → 文字）：**單射**。實測 `1.0/65.0` 印成
//     `0.015384615384615385`、`(1.0/65.0).nextUp` 印成 `0.015384615384615387`。
//     相等的值必印出同一串、相差 1 ulp 的必印出不同串。
//
//   讀取端（文字 → Double，經 `JSONSerialization`）：**不保真**。同一組實測，
//     兩個字串都被讀成 bits `…650`，而真值是 `…648` 與 `…649`——差 2 ulp，
//     且把那對 1-ulp 鄰居**合併成同一個值**。在兩通道分數空間
//     （`1/(60+a)+1/(60+b)`，a,b ∈ [1,100]）上，引擎內 5,009 個互異值經
//     `JSONSerialization` 往返後只剩 5,004。
//
// 初版誤把「寫入端單射」當成「讀取端保真」，用 `JSONSerialization` 解析分數。
// 那個實驗**結構上不可能**抓到這個失敗：它測的是印出去的字串，缺陷在讀回來的
// 數值。方向只有一邊——不會漏掉真平手，但會製造假平手。
//
// 所以現在**完全不解析分數**：從原始 JSON 位元組取出 `"score"` 的原始 token，
// 直接比字串。寫入端單射保證「token 相同 ⟺ 引擎 Double 相同」。`band` 仍走
// `JSONSerialization`——它是整數，不受浮點解析影響。
//
// 分桶用**生產環境那一份** `QueryClassifier`（編譯時直接帶入
// `Sources/LTMEval/QueryClass.swift`），不在本檔抄一份分類規則。
//
// 用法：
//   swiftc -o /tmp/rrfties scripts/measure-rrf-ties.swift Sources/LTMEval/QueryClass.swift
//   LTM_CORPUS_ROOT=<語料目錄> LTM_DERIVED_ROOT=<索引目錄> \
//     /tmp/rrfties <ltm 執行檔> scripts/rrf-tie-queries.txt [k]
//
// 兩個環境變數**必須都給**（見下方守衛）。初版的用法行只寫了 `LTM_DERIVED_ROOT`,
// 逐字就是守衛要擋的那個指令——文件教人下被禁止的命令（#18 verify R1）。
//
// 入口寫成 `@main` 而不是 top-level code：多檔編譯時只有 `main.swift` 能放
// top-level，而本檔必須與 `QueryClass.swift` 一起編才拿得到生產的分類器。

import Dispatch
import Foundation

/// 一筆命中裡本量測用得到的部分。
///
/// `scoreToken` 是分數在 JSON 裡的**原始文字**，不是解析後的 Double（見檔頭）。
struct Hit {
    let scoreToken: String
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
    if denominator == 0 { return "n/a" }
    let ratio: Double = 100.0 * Double(numerator) / Double(denominator)
    return String(format: "%.1f%%", ratio)
}

/// 從原始 JSON 位元組取出每個 `"score"` 鍵的**原始 token**。
///
/// 只認 pretty-printed 的鍵位置：開引號前跳過空白後必須是 `{` 或 `,`。這擋掉
/// 出現在字串值裡的字面 `"score"`（語料片段可能含它）。呼叫端另外用命中數交叉
/// 核對，兩者都過才採用。
///
/// UTF-8 的多位元組序列不含任何 ASCII 位元組，所以在位元組層比對 ASCII 樣式
/// 不會誤切到中文字中間。
func scoreTokens(inRawJSON bytes: [UInt8]) -> [String] {
    let key: [UInt8] = Array("\"score\"".utf8)
    let spacing: Set<UInt8> = Set(" \n\r\t".utf8)
    let skippable: Set<UInt8> = Set(" \n\r\t:".utf8)
    let numeric: Set<UInt8> = Set("0123456789+-.eE".utf8)
    let keyPrefix: Set<UInt8> = Set("{,".utf8)

    var tokens: [String] = []
    var i: Int = 0
    while i + key.count <= bytes.count {
        if bytes[i] != key[0] {
            i += 1
            continue
        }
        if Array(bytes[i..<(i + key.count)]) != key {
            i += 1
            continue
        }
        var back: Int = i - 1
        while back >= 0 && spacing.contains(bytes[back]) {
            back -= 1
        }
        if back < 0 || !keyPrefix.contains(bytes[back]) {
            i += 1
            continue
        }
        var j: Int = i + key.count
        while j < bytes.count && skippable.contains(bytes[j]) {
            j += 1
        }
        var token: [UInt8] = []
        while j < bytes.count && numeric.contains(bytes[j]) {
            token.append(bytes[j])
            j += 1
        }
        if !token.isEmpty {
            tokens.append(String(decoding: token, as: UTF8.self))
        }
        i = j
    }
    return tokens
}

func analyse(_ hits: [Hit], klass: QueryClass) -> QueryStats {
    var tiedByScore: Int = 0
    var tiedByBoth: Int = 0
    if hits.count >= 2 {
        for index in 1..<hits.count {
            if hits[index].scoreToken != hits[index - 1].scoreToken { continue }
            tiedByScore += 1
            if hits[index].band == hits[index - 1].band { tiedByBoth += 1 }
        }
    }

    // 極大區段：連續且 (band, score) 完全相同。**長度 1 的不算**——一個候選的
    // 區段裡沒有東西可以互換，對 tie-breaker 毫無意義（#18 明寫這一點）。
    var runLengths: [Int] = []
    var start: Int = 0
    while start < hits.count {
        var end: Int = start + 1
        while end < hits.count
            && hits[end].band == hits[start].band
            && hits[end].scoreToken == hits[start].scoreToken
        {
            end += 1
        }
        if end - start >= 2 { runLengths.append(end - start) }
        start = end
    }

    return QueryStats(
        klass: klass, hitCount: hits.count, adjacentPairs: max(hits.count - 1, 0),
        adjacentTiedByScore: tiedByScore, adjacentTiedByBandAndScore: tiedByBoth,
        runLengths: runLengths)
}

/// 跑一次真正的查詢。回 `nil` 代表這一筆**失敗**（與「命中 0 筆」不同，見呼叫端）。
func runQuery(_ query: String, ltmPath: String, k: Int, timeoutSeconds: Int) -> [Hit]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ltmPath)
    process.arguments = ["query", query, "--json", "--k", String(k), "--all-projects"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
        try process.run()
    } catch {
        return nil
    }

    // 兩條 pipe **同時**排空。初版是「stdout 讀完才讀 stderr」，那只處理了一個
    // 方向：stderr 一旦填滿 pipe buffer，子行程會卡在 write(stderr) 上、父行程
    // 卡在 read(stdout) 上——雙向死鎖（#18 verify R1）。
    var outData = Data()
    let group = DispatchGroup()
    let queue = DispatchQueue.global()
    group.enter()
    queue.async {
        outData = out.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }
    group.enter()
    queue.async {
        _ = err.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    // 子行程逾時就殺掉並回報失敗。沒有這個的話，探針自己在檔頭記錄的那個
    // 「單一查詢三分鐘未返回」情境會讓整份量測無限期掛住而沒有任何訊號。
    let deadline: DispatchTime = DispatchTime.now() + DispatchTimeInterval.seconds(timeoutSeconds)
    if group.wait(timeout: deadline) == DispatchTimeoutResult.timedOut {
        process.terminate()
        _ = group.wait(timeout: DispatchTime.now() + DispatchTimeInterval.seconds(5))
        return nil
    }
    process.waitUntilExit()
    if process.terminationStatus != 0 { return nil }

    let parsed = try? JSONSerialization.jsonObject(with: outData)
    guard let objects = parsed as? [[String: Any]] else { return nil }

    let tokens: [String] = scoreTokens(inRawJSON: [UInt8](outData))
    guard tokens.count == objects.count else {
        // 交叉核對不過就整筆作廢。token 數與命中數對不上代表抽取抓到了不該抓的
        // 東西（或漏了），而錯位的相鄰關係是**無聲**的：平手率會偏掉且沒有訊號。
        let message = "✗ score token 數 (\(tokens.count)) 與命中數 (\(objects.count)) 不符：\(query)\n"
        FileHandle.standardError.write(Data(message.utf8))
        return nil
    }

    var hits: [Hit] = []
    for (index, object) in objects.enumerated() {
        guard let band = object["band"] as? Int else { return nil }
        hits.append(Hit(scoreToken: tokens[index], band: band))
    }
    return hits
}

@main
enum Probe {
    static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("✗ " + message + "\n").utf8))
        exit(1)
    }

    /// 空字串視同未設：`LTM_CORPUS_ROOT=` 會讓查表回一個空字串，非 nil 卻也不是
    /// 有效路徑——初版只比 nil，這種寫法直接穿過（#18 verify R1）。
    static func nonEmptyEnv(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name] else { return nil }
        if value.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return value
    }

    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)

        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { die("用法：rrfties <ltm 執行檔> <查詢檔> [k]") }
        let ltmPath: String = arguments[1]
        let queriesPath: String = arguments[2]

        // 解析失敗**不**靜默退回預設：使用者顯式給了 k 就代表在意它，安靜換成 20
        // 會讓報告的表頭寫著一個沒被執行的參數。
        var k: Int = 20
        if arguments.count > 3 {
            guard let parsed = Int(arguments[3]), parsed > 0 else {
                die("k 必須是正整數（收到：" + arguments[3] + "）")
            }
            k = parsed
        }

        guard FileManager.default.isExecutableFile(atPath: ltmPath) else {
            die("`" + ltmPath + "` 不是可執行檔。先跑 `swift build -c release`。")
        }
        guard let raw = try? String(contentsOfFile: queriesPath, encoding: .utf8) else {
            die("讀不到查詢檔 `" + queriesPath + "`")
        }

        // **兩個根都必須顯式給**。初版是 XOR（只擋「一邊設一邊不設」），於是
        // 「兩邊都不設」放行——而那一支會對真實語料跑一整輪查詢，每次都對
        // **生產索引**做增量續讀（寫入）。那比被擋掉的情形更糟，卻是唯一沒被擋
        // 的（#18 verify R1）。本量測沒有任何情境需要跑在預設根上。
        let corpusRoot: String? = nonEmptyEnv("LTM_CORPUS_ROOT")
        let derivedRoot: String? = nonEmptyEnv("LTM_DERIVED_ROOT")
        if corpusRoot == nil || derivedRoot == nil {
            var message = "LTM_CORPUS_ROOT 與 LTM_DERIVED_ROOT 都必須顯式指定（空字串視同未設）。\n"
            message += "  LTM_CORPUS_ROOT  = " + (corpusRoot ?? "（未設）") + "\n"
            message += "  LTM_DERIVED_ROOT = " + (derivedRoot ?? "（未設）") + "\n"
            message += "缺任何一個時，該根會取預設值（真實語料 / 生產索引），查詢會對它做增量\n"
            message += "續讀——量到的不是你指定的那個索引，中途還在長大，而且不會有任何錯誤訊息。\n"
            message += "兩邊都不設時尤其糟：整輪查詢都打在生產索引上。"
            die(message)
        }

        var queries: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            queries.append(trimmed)
        }
        guard !queries.isEmpty else { die("查詢檔裡沒有查詢") }

        var stats: [QueryStats] = []
        var failed: [String] = []
        var emptyCount: Int = 0

        for (index, query) in queries.enumerated() {
            let progress = "[" + String(index + 1) + "/" + String(queries.count) + "] " + query + "\n"
            FileHandle.standardError.write(Data(progress.utf8))
            guard let hits = runQuery(query, ltmPath: ltmPath, k: k, timeoutSeconds: 120) else {
                failed.append(query)
                continue
            }
            if hits.isEmpty { emptyCount += 1 }
            stats.append(analyse(hits, klass: QueryClassifier.classify(query)))
        }

        // 失敗要出聲。沉默的跳過等於報告少了東西而沒有人會發現（CLAUDE.md）。
        if !failed.isEmpty {
            print("⚠ " + String(failed.count) + " 個查詢執行失敗、未計入：" + failed.joined(separator: "、"))
            print("")
        }

        var summary = "查詢 " + String(queries.count)
        summary += "　成功 " + String(stats.count)
        summary += "　零命中 " + String(emptyCount)
        summary += "　k=" + String(k)
        print(summary)

        // 零命中查詢仍計入「至少一段平手的查詢」的分母（它確實是一個查詢，只是
        // 沒有候選可平手）。分桶列出來，讓讀者能自己決定要不要換分母。
        var emptyByClass: [QueryClass: Int] = [:]
        for stat in stats where stat.hitCount == 0 {
            emptyByClass[stat.klass, default: 0] += 1
        }
        if !emptyByClass.isEmpty {
            var parts: [String] = []
            for klass in QueryClass.allCases {
                let n: Int = emptyByClass[klass] ?? 0
                if n > 0 { parts.append(klass.rawValue + "=" + String(n)) }
            }
            print("零命中的分桶分佈：" + parts.joined(separator: "、") + "（仍計入下表的查詢數分母）")
        }
        print("")

        var header = "| 桶 | 查詢數 | 候選數 | 相鄰平手（僅 score）"
        header += " | 相鄰平手（band+score） | 至少一段平手的查詢"
        header += " | 平手段數 | 落在平手段內的候選 | 最長段 |"
        print(header)
        print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")

        // **五桶一律都印，即使沒有查詢落在該桶**。靜默略過會讓讀者分不清
        // 「量了、是 0」與「根本沒量」——而 issue 要求的是五桶都報告。
        for klass in QueryClass.allCases {
            var group: [QueryStats] = []
            for stat in stats where stat.klass == klass { group.append(stat) }
            if group.isEmpty {
                print("| " + klass.rawValue + " | 0 | 0 | n/a | n/a | n/a | 0 | n/a | — |")
            } else {
                emit(klass.rawValue, group)
            }
        }
        emit("**全部**", stats)

        // 段長分佈：長度 2 與長度 8 對 tie-breaker 的意義差很多。
        var histogram: [Int: Int] = [:]
        for stat in stats {
            for length in stat.runLengths { histogram[length, default: 0] += 1 }
        }
        if !histogram.isEmpty {
            print("")
            print("| 平手段長度 | 段數 |")
            print("|---:|---:|")
            for length in histogram.keys.sorted() {
                print("| " + String(length) + " | " + String(histogram[length] ?? 0) + " |")
            }
        }

        // 有查詢失敗就以非零狀態結束。初版一律回 0，於是「半份量測」與「完整量測」
        // 在 shell 層無法分辨（#18 verify R1）。
        if !failed.isEmpty { exit(1) }
    }

    static func emit(_ label: String, _ group: [QueryStats]) {
        var pairs: Int = 0
        var tiedScore: Int = 0
        var tiedBoth: Int = 0
        var withRun: Int = 0
        var candidates: Int = 0
        var runs: [Int] = []
        for stat in group {
            pairs += stat.adjacentPairs
            tiedScore += stat.adjacentTiedByScore
            tiedBoth += stat.adjacentTiedByBandAndScore
            candidates += stat.hitCount
            if !stat.runLengths.isEmpty { withRun += 1 }
            runs.append(contentsOf: stat.runLengths)
        }
        var covered: Int = 0
        for length in runs { covered += length }
        let longest: Int = runs.max() ?? 0

        var row = "| " + label
        row += " | " + String(group.count)
        row += " | " + String(candidates)
        row += " | " + percent(tiedScore, pairs)
        row += " | " + percent(tiedBoth, pairs)
        row += " | " + percent(withRun, group.count)
        row += " | " + String(runs.count)
        row += " | " + percent(covered, candidates)
        row += " | " + (longest == 0 ? "—" : String(longest))
        row += " |"
        print(row)
    }
}
