// probe-tokenizer.swift — #2 的一次性量測探針（v2，修 PR #8 verify 的 12 條 blocking）
//
// 目的：量出 SQLite FTS5 各 tokenizer 配置對中英混雜技術對話的 known-item Recall@20，
// 並特徵化 NLTokenizer 的丟字條件。
//
// 隱私（CLAUDE.md 鐵律）：語料在執行期直接讀 ~/.claude/projects/，只讀不寫；
// 任何語料片段都不得寫進本檔或任何提交物。本檔中所有字面字串皆為合成資料。
// 只有聚合數字被印出供寫入 docs/measurements/。
//
// 用法：swift scripts/probe-tokenizer.swift [docs] [queriesPerBucket] [seed]
//   swift scripts/probe-tokenizer.swift 2000 120 42

import Foundation
import NaturalLanguage
import SQLite3

setvbuf(stdout, nil, _IONBF, 0)   // 不緩衝：崩潰時仍能看到進度，定位得到現場

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

let argDocs = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 2000 : 2000
let argQPB = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 120 : 120
let argSeed = CommandLine.arguments.count > 3 ? UInt64(CommandLine.arguments[3]) ?? 42 : 42

func die(_ msg: String) -> Never { FileHandle.standardError.write(("✗ " + msg + "\n").data(using: .utf8)!); exit(1) }

/// 可重現的 PRNG（SplitMix64）—— 取代 shuffle()/randomElement() 的系統亂數，讓數字可重跑。
struct Seeded: RandomNumberGenerator {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
var rng = Seeded(argSeed)

// MARK: - Script 判定（單一定義，供切段／查詢構造共用；修 finding 34 的不一致）

func isCJKScalar(_ u: Unicode.Scalar) -> Bool {
    (u.value >= 0x3400 && u.value <= 0x4DBF) || (u.value >= 0x4E00 && u.value <= 0x9FFF)
        || (u.value >= 0xF900 && u.value <= 0xFAFF)
}
func isCJK(_ c: Character) -> Bool { c.unicodeScalars.contains(where: isCJKScalar) }
func isLatinAlnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

// MARK: - 語料讀取（每檔設上限，避免少數長 session 主宰；下限放低以涵蓋短文本區間）

let minDocChars = 20        // 修 finding 13/17：原本 80 排除了診斷失敗案例所在的長度區間
let maxBlocksPerFile = 4    // 修 finding 19/27/32：原本抽乾每檔，樣本被長 session 主宰

func loadCorpus(limit: Int) -> [String] {
    let root = ("~/.claude/projects" as NSString).expandingTildeInPath
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: root) else { die("無法列舉 \(root)") }
    var files: [String] = []
    while let p = en.nextObject() as? String {
        if p.hasSuffix(".jsonl") { files.append(root + "/" + p) }
    }
    files.sort()                    // 先排序再用 seeded shuffle → 完全可重現
    files.shuffle(using: &rng)

    var docs: [String] = []
    for f in files {
        if docs.count >= limit { break }
        guard let data = fm.contents(atPath: f),
              let text = String(data: data, encoding: .utf8) else { continue }
        var takenFromFile = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if takenFromFile >= maxBlocksPerFile || docs.count >= limit { break }
            guard let ld = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user" || type == "assistant",
                  let msg = obj["message"] as? [String: Any] else { continue }
            var blocks: [[String: Any]] = []
            if let arr = msg["content"] as? [[String: Any]] { blocks = arr }
            else if let s = msg["content"] as? String { blocks = [["type": "text", "text": s]] }
            for b in blocks {
                guard (b["type"] as? String) == "text",
                      let t = (b["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      t.count >= minDocChars else { continue }
                docs.append(String(t.prefix(600)))
                takenFromFile += 1
                break                // 每行最多取一個 block，分散來源
            }
        }
    }
    return docs
}

// MARK: - 斷詞與丟字度量

func segNaive(_ s: String) -> [String] {
    let tk = NLTokenizer(unit: .word); tk.string = s
    var w: [String] = []
    tk.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in w.append(String(s[r])); return true }
    return w
}

/// 先依 script 切段，只對 CJK 段呼叫 NLTokenizer（規避語言偵測失準）
func segByScript(_ s: String) -> [String] {
    var out: [String] = []; var buf = ""; var bufIsCJK: Bool? = nil
    func flush() {
        guard !buf.isEmpty else { return }
        if bufIsCJK == true { out.append(contentsOf: segNaive(buf)) }
        else { out.append(contentsOf: buf.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)) }
        buf = ""
    }
    for ch in s {
        let cjk = isCJK(ch)
        if bufIsCJK == nil { bufIsCJK = cjk } else if cjk != bufIsCJK { flush(); bufIsCJK = cjk }
        buf.append(ch)
    }
    flush()
    return out.filter { !$0.isEmpty }
}

/// 丟字度量：分子分母使用**同一個字元集合**（letter/number），並比對**多重集合**而非只比長度。
/// 修 finding 9（分母不一致→負值抵銷）與 finding 16（只驗總數、不驗是否同一批字）。
struct SegStat {
    let inputCount: Int
    let keptCount: Int          // token 中屬於 letter/number 的字元數
    let missingCount: Int       // 多重集合差集大小：輸入有、token 沒有的字元數
    let latinRuns: Int
    let inputChars: Int
    var lossRatio: Double { inputCount == 0 ? 0 : Double(missingCount) / Double(inputCount) }
}

func latinRunCount(_ s: String) -> Int {
    var runs = 0, inRun = false
    for c in s { if isLatinAlnum(c) { if !inRun { runs += 1; inRun = true } } else { inRun = false } }
    return runs
}

func segStat(_ s: String, tokens: [String]) -> SegStat {
    func bag(_ x: String) -> [Character: Int] {
        var m: [Character: Int] = [:]
        for c in x where c.isLetter || c.isNumber { m[c, default: 0] += 1 }
        return m
    }
    let inBag = bag(s), outBag = bag(tokens.joined())
    var missing = 0
    for (c, n) in inBag { missing += max(0, n - (outBag[c] ?? 0)) }
    return SegStat(inputCount: inBag.values.reduce(0, +),
                   keptCount: outBag.values.reduce(0, +),
                   missingCount: missing,
                   latinRuns: latinRunCount(s),
                   inputChars: s.count)
}

// MARK: - SQLite（每個呼叫檢查回傳碼；修 finding 4/25/31 的靜默吞錯）

/// FTS5 phrase 字面值：整段包雙引號，內部雙引號以連續兩個跳脫。
/// 不做這件事的話，含 `"` 的查詢會讓 FTS5 回 "unterminated string"——
/// 而 v1 因為吞掉 prepare/step 錯誤，會把它靜默轉成 0 命中、汙染 recall。
func ftsPhrase(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

final class DB {
    var h: OpaquePointer?
    init() { if sqlite3_open(":memory:", &h) != SQLITE_OK { die("sqlite3_open 失敗: \(String(cString: sqlite3_errmsg(h)))") } }
    deinit { sqlite3_close(h) }

    func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "unknown"
            die("sqlite3_exec 失敗: \(m)\n   SQL: \(sql)")
        }
    }
    func insert(_ table: String, _ rowid: Int, _ text: String) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, "INSERT INTO \(table)(rowid,x) VALUES(?1,?2)", -1, &st, nil) == SQLITE_OK
        else { die("prepare insert \(table) 失敗: \(String(cString: sqlite3_errmsg(h)))") }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, sqlite3_int64(rowid))
        sqlite3_bind_text(st, 2, text, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(st) == SQLITE_DONE
        else { die("insert \(table) rowid=\(rowid) 失敗: \(String(cString: sqlite3_errmsg(h)))") }
    }
    /// BM25 排序的 top-k rowid。查詢語法錯誤（非「查無結果」）會中止。
    func search(_ table: String, _ match: String, k: Int) -> [Int] {
        var st: OpaquePointer?
        let sql = "SELECT rowid FROM \(table) WHERE \(table) MATCH ?1 ORDER BY bm25(\(table)) LIMIT \(k)"
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK
        else { die("prepare search \(table) 失敗: \(String(cString: sqlite3_errmsg(h)))") }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, match, -1, SQLITE_TRANSIENT)
        var out: [Int] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { out.append(Int(sqlite3_column_int64(st, 0))) }
            else if rc == SQLITE_DONE { break }
            else { die("search \(table) 執行失敗 (rc=\(rc)): \(String(cString: sqlite3_errmsg(h)))\n   MATCH: \(match)") }
        }
        return out
    }
    /// smoke test：確認該 tokenizer 真的可用（而非建表成功但比對永遠落空）
    func smoke(_ table: String, _ probe: String, _ query: String) {
        exec("CREATE VIRTUAL TABLE __smoke_\(table) USING fts5(x, tokenize='\(table)');")
        insert("__smoke_\(table)", 1, probe)
        let hit = search("__smoke_\(table)", ftsPhrase(query), k: 1)
        exec("DROP TABLE __smoke_\(table);")
        if hit.isEmpty { die("tokenizer '\(table)' smoke test 失敗：索引 [\(probe)] 後查 [\(query)] 無命中") }
    }
}

// MARK: - Embedding（依 script 選模型；統計成功率。修 finding 15/22/26）

var embedders: [NLScript: NLContextualEmbedding] = [:]
var embedOK = 0, embedFail = 0
var failReasons: [String: Int] = [:]

@available(macOS 14.0, *)
func loadEmbedders() {
    for sc in [NLScript.traditionalChinese, .simplifiedChinese, .latin] {
        guard let e = NLContextualEmbedding(script: sc) else { failReasons["init \(sc.rawValue) nil", default: 0] += 1; continue }
        do { try e.load(); embedders[sc] = e }
        catch { failReasons["load \(sc.rawValue): \(error)", default: 0] += 1 }
    }
    if embedders.isEmpty { die("NLContextualEmbedding 全部載入失敗——vector 軌無法量測: \(failReasons)") }
}

// R2 finding 3/4：v2 的 per-text script 路由會讓查詢與 gold 文件落在**不同模型**的向量空間，
// 內積因此無意義（且維度不合時 min() 會靜默截斷）。修法：一次實驗固定一個 script，
// 查詢與文件一律用同一個 embedder；兩個候選模型各跑一軌，把差異當結果報出來而不是藏起來。
let vecTracks: [(NLScript, NLLanguage, String)] = [
    (.traditionalChinese, .traditionalChinese, "Hant"),
    (.latin, .english, "Latn"),
]

func embedWith(_ script: NLScript, _ lang: NLLanguage, _ s: String) -> [Float]? {
    guard #available(macOS 14.0, *) else { return nil }
    guard let e = embedders[script] else {
        embedFail += 1; failReasons["no embedder for \(script.rawValue)", default: 0] += 1; return nil
    }
    let r: NLContextualEmbeddingResult
    do { r = try e.embeddingResult(for: s, language: lang) }
    catch { embedFail += 1; failReasons["embeddingResult: \(error)", default: 0] += 1; return nil }
    var sum = [Float](repeating: 0, count: e.dimension); var n = 0
    r.enumerateTokenVectors(in: s.startIndex..<s.endIndex) { vec, _ in
        for (i, v) in vec.enumerated() where i < sum.count { sum[i] += Float(v) }
        n += 1; return true
    }
    guard n > 0 else { embedFail += 1; failReasons["zero token vectors", default: 0] += 1; return nil }
    var norm: Float = 0
    for i in 0..<sum.count { sum[i] /= Float(n); norm += sum[i] * sum[i] }
    norm = norm.squareRoot()
    if norm > 0 { for i in 0..<sum.count { sum[i] /= norm } }
    embedOK += 1
    return sum
}

// MARK: - 融合

/// RRF。tie 以 rowid 遞增打破，確保跑跑之間穩定（修 finding 35）
func rrf(_ lists: [[Int]], k: Int) -> [Int] {
    var score: [Int: Double] = [:]
    for l in lists { for (rank, id) in l.enumerated() { score[id, default: 0] += 1.0 / Double(60 + rank + 1) } }
    return score.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(k).map(\.key)
}

/// issue #2 明文指定的 "OR"：兩路候選取聯集，依各自最佳名次排序（修 finding 14/33/37）
func orMerge(_ a: [Int], _ b: [Int], k: Int) -> [Int] {
    var best: [Int: Int] = [:]
    for (r, id) in a.enumerated() { best[id] = min(best[id] ?? Int.max, r) }
    for (r, id) in b.enumerated() { best[id] = min(best[id] ?? Int.max, r) }
    return best.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }.prefix(k).map(\.key)
}

// MARK: - 主流程

print("讀取語料（seed=\(argSeed)，每檔上限 \(maxBlocksPerFile) block，最短 \(minDocChars) 字元）…")
let docs = loadCorpus(limit: argDocs)
guard docs.count >= 200 else { die("語料不足（\(docs.count)）") }
let lens = docs.map(\.count).sorted()
print("語料：\(docs.count) 份，字元數 median \(lens[lens.count/2])、min \(lens.first!)、max \(lens.last!)\n")

// --- 丟字特徵化：長度 × Latin run 兩軸網格（修 finding 10/12 的「缺控制實驗」）---
print("== NLTokenizer 丟字特徵化 ==")
let naive = docs.map { segStat($0, tokens: segNaive($0)) }
let byScript = docs.map { segStat($0, tokens: segByScript($0)) }
func summarize(_ name: String, _ st: [SegStat]) {
    let avg = st.map(\.lossRatio).reduce(0,+) / Double(st.count)
    let mx = st.map(\.lossRatio).max() ?? 0
    print("  \(name): 平均 \(String(format: "%.2f%%", avg*100))，最大 \(String(format: "%.1f%%", mx*100))，" +
          ">5% 的文件 \(st.filter{ $0.lossRatio > 0.05 }.count)/\(st.count)")
}
summarize("naive     ", naive)
summarize("by-script ", byScript)

print("\n  -- 控制網格（naive 平均丟字率）：列=字元長度，欄=Latin run 數 --")
let lenBins = [(0,60),(60,150),(150,400),(400,10_000)]
let runBins = [(0,1),(1,5),(5,20),(20,10_000)]
// 注意：不要用 String(format:"%s") —— Swift 的 %s 期待 C 字串，傳 Swift String 會 segfault。
func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : String(repeating: " ", count: w - s.count) + s }

var header = "    長度\\Latin run |"
for (a,b) in runBins { header += " " + pad(b > 9999 ? "20+" : "\(a)-\(b)", 11) + " |" }
print(header)
print("    （每格：平均丟字率 / 該格 n。兩軸在本語料高度共線——長文本幾乎必然有多個 Latin run，")
print("      故空格與 n 極不均，不足以支撐強因果宣稱。）")
for (lo,hi) in lenBins {
    var row = "    " + pad(hi > 9999 ? "400+" : "\(lo)-\(hi)", 12) + " |"
    for (ra,rb) in runBins {
        let g = zip(docs, naive).filter { $0.0.count >= lo && $0.0.count < hi && $0.1.latinRuns >= ra && $0.1.latinRuns < rb }.map(\.1)
        row += g.isEmpty ? pad("—", 11) + " |"
             : pad(String(format: "%.1f%%/n=%d", g.map(\.lossRatio).reduce(0,+)/Double(g.count)*100, g.count), 11) + " |"
    }
    print(row)
}

// 合成的短混雜句（**非語料片段**，修 CRITICAL finding 1/2/3/11/24）：
// 結構刻意模仿被測條件——短、CJK 與 Latin 交替、含兩段 Latin。
let synthetic = "標記某個節點然後做對照，這是 zQ7 範例的difftool 基準"
let sN = segStat(synthetic, tokens: segNaive(synthetic))
let sS = segStat(synthetic, tokens: segByScript(synthetic))
print("\n    合成短混雜句（\(synthetic.count) 字元、\(sN.latinRuns) 個 Latin run）：naive 丟字 " +
      "\(String(format: "%.1f%%", sN.lossRatio*100))，by-script \(String(format: "%.1f%%", sS.lossRatio*100))")

// --- 索引 ---
print("\n== 建索引 ==")
let db = DB()
db.smoke("unicode61", "alpha bravo", "bravo")
db.smoke("trigram", "alphabravo", "phabr")
db.exec("CREATE VIRTUAL TABLE u61 USING fts5(x, tokenize='unicode61');")
db.exec("CREATE VIRTUAL TABLE tri USING fts5(x, tokenize='trigram');")
db.exec("CREATE VIRTUAL TABLE seg USING fts5(x, tokenize='unicode61');")
for (i, d) in docs.enumerated() { db.insert("u61", i, d); db.insert("tri", i, d); db.insert("seg", i, segByScript(d).joined(separator: " ")) }
print("  smoke test 通過；u61 / tri / seg 就緒")

print("\n== 建向量 ==")
if #available(macOS 14.0, *) { loadEmbedders() }
print("  已載入 embedder: \(embedders.keys.map(\.rawValue).sorted().joined(separator: ", "))")
// 每個 track 用**單一固定模型**embed 全部文件；查詢在檢索時用同一模型 → 保證同一向量空間。
var trackDocVecs: [String: [[Float]]] = [:]
var trackDim: [String: Int] = [:]
for (script, lang, name) in vecTracks {
    guard embedders[script] != nil else { print("  track \(name)：embedder 缺席，跳過"); continue }
    let t0 = Date()
    let vs = docs.map { embedWith(script, lang, $0) ?? [] }
    let empty = vs.filter(\.isEmpty).count
    let dims = Set(vs.filter { !$0.isEmpty }.map(\.count))
    if dims.count > 1 { die("track \(name) 出現多種向量維度 \(dims)——不可比較") }
    trackDocVecs[name] = vs
    trackDim[name] = dims.first ?? 0
    print("  track \(name)：\(docs.count) 份耗時 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s，" +
          "dim=\(dims.first ?? 0)，空向量 \(empty)")
    if empty > docs.count / 10 { print("    ⚠ 空向量超過 10% —— 本 track 數字不可信") }
}
if !failReasons.isEmpty { print("  embedding 失敗原因：\(failReasons)") }

/// 同一 track 內比較；維度不合直接中止（不再靜默 min() 截斷）
func vectorTop(_ track: String, _ q: String, k: Int) -> [Int] {
    guard let dvs = trackDocVecs[track] else { return [] }
    let (script, lang, _) = vecTracks.first { $0.2 == track }!
    guard let qv = embedWith(script, lang, q), !qv.isEmpty else { return [] }
    if let d = trackDim[track], d > 0, qv.count != d { die("track \(track) 查詢向量維度 \(qv.count) ≠ 文件 \(d)") }
    var scored: [(Int, Float)] = []
    for (i, dv) in dvs.enumerated() where !dv.isEmpty {
        var s: Float = 0
        for j in 0..<qv.count { s += qv[j] * dv[j] }
        scored.append((i, s))
    }
    return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(k).map(\.0)
}

// --- 查詢集 ---
enum Bucket: String, CaseIterable {
    case cjk2 = "中文2字", cjk3 = "中文3字", cjk4 = "中文4字"
    case latin = "英數", mixed = "中英混雜", synonym = "跨語彙同義"
}
struct Query { let bucket: Bucket; let text: String; let gold: Int }

/// document frequency：多少份文件含此子字串（數到 cap+1 即早停）。
/// R2 finding 5：df==1 會系統性挑出稀有且獨特的字串——正是 lexical 最擅長的，因而灌水
/// 所有 lexical 配置。因此改為可調 cap，並在 cap=1 與 cap=5 兩種設定下各跑一次，
/// 讓「唯一性有多少貢獻」變成可讀的數字而不是隱藏假設。
func df(_ needle: String, cap: Int) -> (count: Int, first: Int) {
    var c = 0, first = -1
    for (i, d) in docs.enumerated() where d.contains(needle) {
        c += 1; if first < 0 { first = i }
        if c > cap { break }
    }
    return (c, first)
}

func cjkRuns(_ s: String) -> [String] {
    var runs: [String] = []; var buf = ""
    for ch in s { if isCJK(ch) { buf.append(ch) } else { if buf.count >= 2 { runs.append(buf) }; buf = "" } }
    if buf.count >= 2 { runs.append(buf) }
    return runs
}

/// 手寫的跨語彙同義詞對（**合成清單，非語料抽取**）
let aliases: [(String, String)] = [
    ("ANN", "近似"), ("embedding", "向量"), ("tokenizer", "斷詞"), ("recall", "召回"),
    ("index", "索引"), ("query", "查詢"), ("cluster", "分群"), ("baseline", "基準"),
    ("commit", "提交"), ("schema", "綱要"), ("cache", "快取"), ("branch", "分支"),
]

/// gold 一律是**抽出查詢的那份文件**（不是「第一個含它的文件」）。
/// dfCap > 1 時其他文件也含該子字串，檢索因此變難——這正是要量的敏感度。
func buildQueries(perBucket: Int, dfCap: Int) -> [Query] {
    var localRng = Seeded(argSeed &+ UInt64(dfCap))   // 兩種 cap 各自可重現
    var qs: [Query] = []; var n: [Bucket: Int] = [:]
    var order = Array(docs.indices); order.shuffle(using: &localRng)

    for i in order {
        let d = docs[i]
        // CJK 長度桶：排除「整個 run」當查詢（子字串必為 interior）
        for (bucket, L) in [(Bucket.cjk2, 2), (.cjk3, 3), (.cjk4, 4)] where (n[bucket] ?? 0) < perBucket {
            let runs = cjkRuns(d).filter { $0.count > L }
            guard let run = runs.randomElement(using: &localRng) else { continue }
            let start = Int.random(in: 0...(run.count - L), using: &localRng)
            let idx = run.index(run.startIndex, offsetBy: start)
            let sub = String(run[idx..<run.index(idx, offsetBy: L)])
            let f = df(sub, cap: dfCap); guard f.count >= 1 && f.count <= dfCap else { continue }
            qs.append(Query(bucket: bucket, text: sub, gold: i)); n[bucket, default: 0] += 1
        }
        // 英數
        if (n[.latin] ?? 0) < perBucket {
            let toks = d.split(whereSeparator: { !isLatinAlnum($0) }).map(String.init).filter { $0.count >= 4 }
            if let t = toks.randomElement(using: &localRng) {
                let f = df(t, cap: dfCap)
                if f.count >= 1 && f.count <= dfCap { qs.append(Query(bucket: .latin, text: t, gold: i)); n[.latin, default: 0] += 1 }
            }
        }
        // 中英混雜：跨 script 邊界的子字串
        if (n[.mixed] ?? 0) < perBucket {
            let chars = Array(d)
            var cands: [String] = []
            for j in 1..<max(1, chars.count) where j + 3 <= chars.count {
                if isCJK(chars[j-1]) != isCJK(chars[j]) && (isCJK(chars[j-1]) || isLatinAlnum(chars[j-1])) {
                    let lo = max(0, j-2), hi = min(chars.count, j+3)
                    let sub = String(chars[lo..<hi]).trimmingCharacters(in: .whitespaces)
                    if sub.count >= 4 && sub.contains(where: isCJK) && sub.contains(where: isLatinAlnum) { cands.append(sub) }
                }
            }
            if let sub = cands.randomElement(using: &localRng) {
                let f = df(sub, cap: dfCap)
                if f.count >= 1 && f.count <= dfCap { qs.append(Query(bucket: .mixed, text: sub, gold: i)); n[.mixed, default: 0] += 1 }
            }
        }
        if Bucket.allCases.filter({ $0 != .synonym }).allSatisfy({ (n[$0] ?? 0) >= perBucket }) { break }
    }

    // 跨語彙同義：文件含 A 面、不含 B 面；查詢用 B 面。gold 必須唯一（否則語意不明）
    for (en, zh) in aliases {
        for (side, other) in [(en, zh), (zh, en)] {
            guard (n[.synonym] ?? 0) < perBucket else { break }
            let hits = docs.indices.filter { docs[$0].localizedCaseInsensitiveContains(side) && !docs[$0].contains(other) }
            guard hits.count == 1 else { continue }
            qs.append(Query(bucket: .synonym, text: other, gold: hits[0])); n[.synonym, default: 0] += 1
        }
    }
    return qs
}
// --- 量測 ---
let K = 20
struct Acc { var hit = 0; var total = 0 }

let chance = Double(K) / Double(docs.count) * 100
print("\n機率 baseline（隨機 top-\(K) / \(docs.count)）：\(String(format: "%.1f%%", chance))")
if chance > 5 { print("⚠ baseline 過高，語料規模不足") }

/// 對一組 (dfCap, vector track) 跑完整量測並印表
func runMeasurement(dfCap: Int, track: String?) {
    let queries = buildQueries(perBucket: argQPB, dfCap: dfCap)
    var res: [String: [Bucket: Acc]] = [:]
    func rec(_ cfg: String, _ b: Bucket, _ hit: Bool) {
        res[cfg, default: [:]][b, default: Acc()].total += 1
        if hit { res[cfg, default: [:]][b, default: Acc()].hit += 1 }
    }
    for q in queries {
        let phrase = ftsPhrase(q.text)
        let ru = db.search("u61", phrase, k: K)
        let rt = db.search("tri", phrase, k: K)
        let rs = db.search("seg", ftsPhrase(segByScript(q.text).joined(separator: " ")), k: K)
        let lexOR  = orMerge(rt, rs, k: K)
        let lexRRF = rrf([rt, rs], k: K)
        rec("unicode61", q.bucket, ru.contains(q.gold))
        rec("trigram", q.bucket, rt.contains(q.gold))
        rec("segment+unicode61", q.bucket, rs.contains(q.gold))
        rec("trigram+segment (OR)", q.bucket, lexOR.contains(q.gold))
        rec("trigram+segment (RRF)", q.bucket, lexRRF.contains(q.gold))
        if let tr = track {
            let rv = vectorTop(tr, q.text, k: K)
            rec("vector-only [\(tr)]", q.bucket, rv.contains(q.gold))
            rec("lexRRF + vector [\(tr)]", q.bucket, rrf([lexRRF, rv], k: K).contains(q.gold))
        }
    }
    var order = ["unicode61", "trigram", "segment+unicode61", "trigram+segment (OR)", "trigram+segment (RRF)"]
    if let tr = track { order += ["vector-only [\(tr)]", "lexRRF + vector [\(tr)]"] }

    let label = track.map { "df≤\(dfCap)　vector track = \($0)" } ?? "df≤\(dfCap)　lexical only"
    print("\n### \(label)")
    var counts = "查詢數："
    for b in Bucket.allCases { counts += " \(b.rawValue)=\(queries.filter { $0.bucket == b }.count)" }
    print(counts)
    var head = "| 配置 |"; var sep = "|---|"
    for b in Bucket.allCases { head += " \(b.rawValue) |"; sep += "---|" }
    head += " 全體 |"; sep += "---|"
    print(head); print(sep)
    for cfg in order {
        guard let m = res[cfg] else { continue }
        var row = "| \(cfg) |"; var th = 0, tt = 0
        for b in Bucket.allCases {
            let a = m[b] ?? Acc(); th += a.hit; tt += a.total
            row += a.total == 0 ? " — |" : " \(String(format: "%.0f%%", Double(a.hit)/Double(a.total)*100)) |"
        }
        row += tt == 0 ? " — |" : " **\(String(format: "%.0f%%", Double(th)/Double(tt)*100))** |"
        print(row)
    }
}

print("\n== 量測 Recall@\(K) ==")
for tr in vecTracks.map(\.2) where trackDocVecs[tr] != nil { runMeasurement(dfCap: 1, track: tr) }
// df 敏感度：放寬唯一性要求後，lexical 的優勢還剩多少（R2 finding 5）
runMeasurement(dfCap: 5, track: vecTracks.map(\.2).first { trackDocVecs[$0] != nil })

print("\nembedding 累計：成功 \(embedOK)、失敗 \(embedFail)" +
      (embedFail > 0 ? "　原因：\(failReasons)" : ""))
