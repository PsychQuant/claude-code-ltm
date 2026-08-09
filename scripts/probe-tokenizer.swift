// probe-tokenizer.swift — #2 的一次性量測探針
//
// 目的：量出 SQLite FTS5 各 tokenizer 配置對中英混雜技術對話的 known-item Recall@20，
// 並特徵化 NLTokenizer 的丟字條件。
//
// 隱私（CLAUDE.md 鐵律）：語料在執行期直接讀 ~/.claude/projects/，
// 不複製任何片段到 repo；只有聚合數字被印出供寫入 docs/measurements/。
//
// 用法：swift scripts/probe-tokenizer.swift [docs] [queriesPerBucket]
//   swift scripts/probe-tokenizer.swift 600 120

import Foundation
import NaturalLanguage
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

let argDocs = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 600 : 600
let argQPB = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 120 : 120

// MARK: - 語料讀取

/// 從 ~/.claude/projects 抽樣對話 text block。只取 user/assistant 的 type=="text" 區塊。
func loadCorpus(limit: Int) -> [String] {
    let root = ("~/.claude/projects" as NSString).expandingTildeInPath
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: root) else { return [] }
    var files: [String] = []
    while let p = en.nextObject() as? String {
        if p.hasSuffix(".jsonl") { files.append(root + "/" + p) }
    }
    files.shuffle()

    var docs: [String] = []
    outer: for f in files {
        guard let data = fm.contents(atPath: f),
              let text = String(data: data, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
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
                      t.count >= 80 else { continue }
                docs.append(String(t.prefix(600)))
                if docs.count >= limit { break outer }
            }
        }
    }
    return docs
}

// MARK: - NLTokenizer 斷詞 + 丟字特徵化

struct SegStat {
    let inputChars: Int
    let coveredChars: Int
    let latinRuns: Int
    let detectedLang: String
    var lossRatio: Double { inputChars == 0 ? 0 : 1.0 - Double(coveredChars) / Double(inputChars) }
}

func latinRunCount(_ s: String) -> Int {
    var runs = 0, inRun = false
    for ch in s.unicodeScalars {
        let isLatin = (ch.value >= 0x41 && ch.value <= 0x5A) || (ch.value >= 0x61 && ch.value <= 0x7A)
        if isLatin && !inRun { runs += 1; inRun = true }
        if !isLatin { inRun = false }
    }
    return runs
}

/// 直接用 NLTokenizer 斷詞（naive 版；用於量測其丟字行為）
func segNaive(_ s: String) -> [String] {
    let tk = NLTokenizer(unit: .word); tk.string = s
    var w: [String] = []
    tk.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in w.append(String(s[r])); return true }
    return w
}

/// 依 script 先切段，只對 CJK 段做 NLTokenizer（規避語言偵測失準的候選修法）
func segByScript(_ s: String) -> [String] {
    func isCJK(_ u: Unicode.Scalar) -> Bool {
        (u.value >= 0x3400 && u.value <= 0x9FFF) || (u.value >= 0xF900 && u.value <= 0xFAFF)
    }
    var out: [String] = []
    var buf = ""
    var bufIsCJK: Bool? = nil
    func flush() {
        guard !buf.isEmpty else { return }
        if bufIsCJK == true { out.append(contentsOf: segNaive(buf)) }
        else {
            let parts = buf.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            out.append(contentsOf: parts.map(String.init))
        }
        buf = ""
    }
    for ch in s {
        let cjk = ch.unicodeScalars.contains(where: isCJK)
        if bufIsCJK == nil { bufIsCJK = cjk }
        else if cjk != bufIsCJK { flush(); bufIsCJK = cjk }
        buf.append(ch)
    }
    flush()
    return out.filter { !$0.isEmpty }
}

func segStat(_ s: String, tokens: [String]) -> SegStat {
    let rec = NLLanguageRecognizer(); rec.processString(s)
    return SegStat(inputChars: s.filter { $0.isLetter || $0.isNumber }.count,
                   coveredChars: tokens.joined().count,
                   latinRuns: latinRunCount(s),
                   detectedLang: rec.dominantLanguage?.rawValue ?? "nil")
}

// MARK: - SQLite 輔助

final class DB {
    var h: OpaquePointer?
    init() { sqlite3_open(":memory:", &h) }
    deinit { sqlite3_close(h) }
    func exec(_ sql: String) { sqlite3_exec(h, sql, nil, nil, nil) }
    func insert(_ table: String, _ rowid: Int, _ text: String) {
        var st: OpaquePointer?
        sqlite3_prepare_v2(h, "INSERT INTO \(table)(rowid,x) VALUES(?1,?2)", -1, &st, nil)
        sqlite3_bind_int64(st, 1, sqlite3_int64(rowid))
        sqlite3_bind_text(st, 2, text, -1, SQLITE_TRANSIENT)
        sqlite3_step(st); sqlite3_finalize(st)
    }
    /// 回傳 BM25 排序的 top-k rowid
    func search(_ table: String, _ match: String, k: Int) -> [Int] {
        var st: OpaquePointer?
        let sql = "SELECT rowid FROM \(table) WHERE \(table) MATCH ?1 ORDER BY bm25(\(table)) LIMIT \(k)"
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(st, 1, match, -1, SQLITE_TRANSIENT)
        var out: [Int] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(Int(sqlite3_column_int64(st, 0))) }
        sqlite3_finalize(st)
        return out
    }
}

// MARK: - 查詢集（known-item）

enum Bucket: String, CaseIterable { case cjk2 = "中文2字", cjk3 = "中文3字", cjk4 = "中文4字", latin = "英數" }

struct Query { let bucket: Bucket; let text: String; let goldDoc: Int }

func cjkRuns(_ s: String) -> [String] {
    func isCJK(_ u: Unicode.Scalar) -> Bool { u.value >= 0x3400 && u.value <= 0x9FFF }
    var runs: [String] = []; var buf = ""
    for ch in s {
        if ch.unicodeScalars.contains(where: isCJK) { buf.append(ch) }
        else { if buf.count >= 2 { runs.append(buf) }; buf = "" }
    }
    if buf.count >= 2 { runs.append(buf) }
    return runs
}

func latinTokens(_ s: String) -> [String] {
    s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
        .filter { $0.count >= 4 && $0.allSatisfy { $0.isASCII } }
}

func buildQueries(_ docs: [String], perBucket: Int) -> [Query] {
    var qs: [Query] = []
    var counts: [Bucket: Int] = [:]
    for (i, d) in docs.enumerated().shuffled() {
        for (bucket, n) in [(Bucket.cjk2, 2), (.cjk3, 3), (.cjk4, 4)] {
            guard (counts[bucket] ?? 0) < perBucket else { continue }
            let runs = cjkRuns(d).filter { $0.count >= n }
            guard let run = runs.randomElement() else { continue }
            let start = Int.random(in: 0...(run.count - n))
            let idx = run.index(run.startIndex, offsetBy: start)
            let sub = String(run[idx..<run.index(idx, offsetBy: n)])
            qs.append(Query(bucket: bucket, text: sub, goldDoc: i))
            counts[bucket, default: 0] += 1
        }
        if (counts[.latin] ?? 0) < perBucket, let lt = latinTokens(d).randomElement() {
            qs.append(Query(bucket: .latin, text: lt, goldDoc: i))
            counts[.latin, default: 0] += 1
        }
        if Bucket.allCases.allSatisfy({ (counts[$0] ?? 0) >= perBucket }) { break }
    }
    return qs
}

// MARK: - 主流程

print("讀取語料…")
let docs = loadCorpus(limit: argDocs)
guard docs.count >= 50 else { print("語料不足（\(docs.count)），中止"); exit(1) }
print("語料：\(docs.count) 份文件，平均 \(docs.map(\.count).reduce(0,+) / docs.count) 字元\n")

// --- NLTokenizer 丟字特徵化 ---
print("== NLTokenizer 丟字特徵化 ==")
var naiveStats: [SegStat] = [], scriptStats: [SegStat] = []
for d in docs {
    naiveStats.append(segStat(d, tokens: segNaive(d)))
    scriptStats.append(segStat(d, tokens: segByScript(d)))
}
func report(_ name: String, _ st: [SegStat]) {
    let lossy = st.filter { $0.lossRatio > 0.05 }
    let severe = st.filter { $0.lossRatio > 0.20 }
    let avgLoss = st.map(\.lossRatio).reduce(0,+) / Double(st.count)
    let maxLoss = st.map(\.lossRatio).max() ?? 0
    print("  \(name): 平均丟字率 \(String(format: "%.1f%%", avgLoss * 100))，最大 \(String(format: "%.1f%%", maxLoss * 100))")
    print("    丟字 >5%: \(lossy.count)/\(st.count)　>20%: \(severe.count)/\(st.count)")
    if !lossy.isEmpty {
        let avgRunsLossy = Double(lossy.map(\.latinRuns).reduce(0,+)) / Double(lossy.count)
        let clean = st.filter { $0.lossRatio <= 0.05 }
        let avgRunsClean = clean.isEmpty ? 0 : Double(clean.map(\.latinRuns).reduce(0,+)) / Double(clean.count)
        print("    丟字組平均 Latin run 數 \(String(format: "%.1f", avgRunsLossy))；正常組 \(String(format: "%.1f", avgRunsClean))")
        var langs: [String: Int] = [:]
        for s in lossy { langs[s.detectedLang, default: 0] += 1 }
        let top = langs.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        print("    丟字組偵測語言分布：\(top)")
    }
}
report("naive（整份直接斷詞）", naiveStats)
report("by-script（先切 CJK/Latin 段）", scriptStats)

// 與診斷時發現的短字串失敗案例對帳：丟字是否只發生在短文本？
print("\n  -- 依輸入長度分層（naive）--")
for (lo, hi) in [(0, 60), (60, 150), (150, 400), (400, 10_000)] {
    let grp = zip(docs, naiveStats).filter { $0.0.count >= lo && $0.0.count < hi }.map(\.1)
    guard !grp.isEmpty else { continue }
    let avg = grp.map(\.lossRatio).reduce(0,+) / Double(grp.count)
    print("    \(lo)–\(hi) 字元 (n=\(grp.count)): 平均丟字 \(String(format: "%.1f%%", avg * 100))")
}
let known = "釘選某個版本然後做比較，這是 gAB 手稿的 latexdiff baseline"
let ks = segStat(known, tokens: segNaive(known))
let kss = segStat(known, tokens: segByScript(known))
print("    診斷時的失敗案例（\(known.count) 字元）：naive 丟字 \(String(format: "%.1f%%", ks.lossRatio * 100))" +
      "，by-script 丟字 \(String(format: "%.1f%%", kss.lossRatio * 100))")
print("")

// --- 建四種 FTS5 配置 ---
print("== 建索引 ==")
let db = DB()
db.exec("CREATE VIRTUAL TABLE u61 USING fts5(x, tokenize='unicode61');")
db.exec("CREATE VIRTUAL TABLE tri USING fts5(x, tokenize='trigram');")
db.exec("CREATE VIRTUAL TABLE seg USING fts5(x, tokenize='unicode61');")
for (i, d) in docs.enumerated() {
    db.insert("u61", i, d)
    db.insert("tri", i, d)
    db.insert("seg", i, segByScript(d).joined(separator: " "))
}
print("  u61 / tri / seg 建立完成\n")

// --- 向量索引 ---
print("== 建向量（NLContextualEmbedding）==")
var docVecs: [[Float]] = []
var embedder: NLContextualEmbedding? = nil
if #available(macOS 14.0, *) {
    embedder = NLContextualEmbedding(script: .traditionalChinese)
    try? embedder?.load()
}
func embed(_ s: String) -> [Float]? {
    guard #available(macOS 14.0, *), let e = embedder,
          let r = try? e.embeddingResult(for: s, language: .traditionalChinese) else { return nil }
    var sum: [Float] = Array(repeating: 0, count: e.dimension); var n = 0
    r.enumerateTokenVectors(in: s.startIndex..<s.endIndex) { vec, _ in
        for (i, v) in vec.enumerated() where i < sum.count { sum[i] += Float(v) }
        n += 1; return true
    }
    guard n > 0 else { return nil }
    var norm: Float = 0
    for i in 0..<sum.count { sum[i] /= Float(n); norm += sum[i] * sum[i] }
    norm = norm.squareRoot()
    if norm > 0 { for i in 0..<sum.count { sum[i] /= norm } }
    return sum
}
let t0 = Date()
for d in docs { docVecs.append(embed(d) ?? []) }
print("  \(docs.count) 份文件耗時 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s\n")

func vectorTop(_ q: String, k: Int) -> [Int] {
    guard let qv = embed(q), !qv.isEmpty else { return [] }
    var scored: [(Int, Float)] = []
    for (i, dv) in docVecs.enumerated() where !dv.isEmpty {
        var s: Float = 0
        for j in 0..<min(qv.count, dv.count) { s += qv[j] * dv[j] }
        scored.append((i, s))
    }
    return scored.sorted { $0.1 > $1.1 }.prefix(k).map(\.0)
}

func rrf(_ lists: [[Int]], k: Int) -> [Int] {
    var score: [Int: Double] = [:]
    for l in lists { for (rank, id) in l.enumerated() { score[id, default: 0] += 1.0 / Double(60 + rank + 1) } }
    return score.sorted { $0.value > $1.value }.prefix(k).map(\.key)
}

// --- 查詢集 ---
let queries = buildQueries(docs, perBucket: argQPB)
var byBucket: [Bucket: Int] = [:]
for q in queries { byBucket[q.bucket, default: 0] += 1 }
print("== 查詢集 ==")
for b in Bucket.allCases { print("  \(b.rawValue): \(byBucket[b] ?? 0) 條") }
print("")

// --- 量測 ---
let K = 20
struct Acc { var hit = 0; var total = 0 }
var results: [String: [Bucket: Acc]] = [:]
func record(_ config: String, _ b: Bucket, _ hit: Bool) {
    results[config, default: [:]][b, default: Acc()].total += 1
    if hit { results[config, default: [:]][b, default: Acc()].hit += 1 }
}

print("== 量測 Recall@\(K) ==")
for q in queries {
    let phrase = "\"\(q.text)\""
    let ru = db.search("u61", phrase, k: K)
    let rt = db.search("tri", phrase, k: K)
    let segQ = segByScript(q.text).joined(separator: " ")
    let rs = db.search("seg", "\"\(segQ)\"", k: K)
    let rboth = rrf([rt, rs], k: K)
    let rv = vectorTop(q.text, k: K)
    let rfused = rrf([rs, rv], k: K)

    record("unicode61", q.bucket, ru.contains(q.goldDoc))
    record("trigram", q.bucket, rt.contains(q.goldDoc))
    record("segment+unicode61", q.bucket, rs.contains(q.goldDoc))
    record("trigram+segment (RRF)", q.bucket, rboth.contains(q.goldDoc))
    record("vector-only", q.bucket, rv.contains(q.goldDoc))
    record("fused (seg+vector RRF)", q.bucket, rfused.contains(q.goldDoc))
}

// 機率 baseline：隨機取 K 份時 gold doc 落在其中的機率 = K/N。
// 低於此值的配置等同「不如亂猜」；語料太小時整張表都會被這個 floor 灌水。
let chance = Double(K) / Double(docs.count) * 100
print("機率 baseline（隨機 top-\(K) / \(docs.count) 份）：\(String(format: "%.1f%%", chance))")
if chance > 10 { print("⚠ baseline 過高，語料規模不足以區辨配置差異——請加大 docs 參數") }
print("")

let order = ["unicode61", "trigram", "segment+unicode61", "trigram+segment (RRF)", "vector-only", "fused (seg+vector RRF)"]
var header = "| 配置 |"
var sep = "|---|"
for b in Bucket.allCases { header += " \(b.rawValue) |"; sep += "---|" }
header += " 全體 |"; sep += "---|"
print(header); print(sep)
for cfg in order {
    guard let m = results[cfg] else { continue }
    var row = "| \(cfg) |"
    var th = 0, tt = 0
    for b in Bucket.allCases {
        let a = m[b] ?? Acc()
        th += a.hit; tt += a.total
        row += a.total == 0 ? " — |" : " \(String(format: "%.0f%%", Double(a.hit)/Double(a.total)*100)) |"
    }
    row += tt == 0 ? " — |" : " **\(String(format: "%.0f%%", Double(th)/Double(tt)*100))** |"
    print(row)
}
