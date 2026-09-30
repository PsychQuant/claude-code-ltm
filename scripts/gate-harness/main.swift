// #60 的閘 harness：用 ltm 自己的 `IndexDatabase` 路徑跑閘，只印計數與時間，不印任何一列。
// 建置：swift build -c release --product gate-harness
// 用法：.build/release/gate-harness <index.sqlite3> <conns 1-20> <reps 1-20> [--cache-size N] [--no-mmap] [--old-sql]
//   --cache-size N  開好之後在同一條連線上下 PRAGMA cache_size=N
//   --no-mmap       開好之後在同一條連線上下 PRAGMA mmap_size=0
//   --old-sql       不呼叫 sourcesWithoutCursor()，改用 IndexDatabase.query 跑 #58 修正之前的兩條閘 SQL
// 印出的 rows：閘模式是 sourcesWithoutCursor() 回的項數；--old-sql 是兩條 SQL 回的列數加總
// （Q1 的 COUNT 永遠一列，所以 no-op 時是 1）。
// 主檔不存在或不是一般檔就拒絕（exit 66）。存在的話以讀寫開檔（ltm 的查詢也是）：`init` 會把它設成 WAL 模式，
// 關閉時可能 checkpoint——所以只對 ltm 的索引用，不要指向別的 SQLite 檔。
// 量測紀錄：docs/measurements/2026-09-07-gate-first-touch.md（表 9–11；表 6、7 用的是較早的版本）。
import Darwin
import Foundation
import LTMIndex
import SQLite3

func usage() -> rusage { var u = rusage(); getrusage(RUSAGE_SELF, &u); return u }
func fail(_ message: String, _ code: Int32) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(code) }
let usageLine = "用法：gate-harness <index.sqlite3> <conns 1-20> <reps 1-20> [--cache-size N（非 0）] [--no-mmap] [--old-sql]"
func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

let oldQ1 = "SELECT COUNT(*) FROM chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_sources)"
let oldQ2 = """
    SELECT DISTINCT s.source_key FROM chunk_sources s
    LEFT JOIN scan_state c ON c.source_key = s.source_key
    WHERE c.source_key IS NULL
    """

var args = Array(CommandLine.arguments.dropFirst())
var cacheSize: Int? = nil
var noMmap = false
var oldSQL = false
var rest: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--cache-size":
        guard let v = args.first.flatMap({ Int($0) }), v != 0 else { fail(usageLine, 64) }
        cacheSize = v; args.removeFirst()
    case "--no-mmap": noMmap = true
    case "--old-sql": oldSQL = true
    default: rest.append(a)
    }
}
guard rest.count == 3, let conns = Int(rest[1]), let reps = Int(rest[2]),
      (1...20).contains(conns), (1...20).contains(reps) else { fail(usageLine, 64) }
var st = stat()
guard lstat(rest[0], &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { fail("不跑：\(rest[0]) 不存在或不是一般檔", 66) }
var load = [Double](repeating: -1, count: 3)
_ = getloadavg(&load, 3)
print(String(format: "harness loadavg=%.2f %.2f %.2f cache_size=%@ mmap=%@ sql=%@", load[0], load[1], load[2],
             cacheSize.map(String.init) ?? "default", noMmap ? "off" : "on", oldSQL ? "old" : "gate"))
for c in 1...conns {
    let t0 = nowMs()
    let database = try IndexDatabase(path: rest[0])
    if let cacheSize { try database.execute("PRAGMA cache_size=\(cacheSize)") }
    if noMmap { try database.execute("PRAGMA mmap_size=0") }
    var mm: Int64 = -1, cs: Int64 = -1
    try database.query("PRAGMA mmap_size") { mm = sqlite3_column_int64($0, 0) }
    try database.query("PRAGMA cache_size") { cs = sqlite3_column_int64($0, 0) }
    print(String(format: "conn=%d open_ms=%.1f mmap_size=%lld cache_size=%lld", c, nowMs() - t0, mm, cs))
    for r in 1...reps {
        let a = usage(); let s = nowMs()
        var rows = 0
        if oldSQL {
            try database.query(oldQ1) { _ in rows += 1 }
            try database.query(oldQ2) { _ in rows += 1 }
        } else {
            rows = try database.sourcesWithoutCursor().count
        }
        let ms = nowMs() - s; let b = usage()
        print(String(format: "conn=%d rep=%d ms=%.1f majflt=%ld minflt=%ld rows=%d",
                     c, r, ms, b.ru_majflt - a.ru_majflt, b.ru_minflt - a.ru_minflt, rows))
    }
    database.close()
}
