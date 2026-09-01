import Foundation
import Testing

@testable import LTMIndex

// #56：掃描並行化的等價測試。
//
// 並行版的唯一正確性宣稱是「輸出與循序逐 byte 相同」——所以測試的形狀就是
// 拿 width 4 與 width 1 跑同一份 fixture，對 `ScanResult` 的每一個欄位斷言全等
// （chunks 含順序、state、兩個集合、tally）。fixture 刻意涵蓋四類路徑：
// 純新檔、續讀（append）、invalidated（改寫）、skip 行（非法 JSON＋結尾半行）
// ——unreadable 由 chmod 000 另測（CI 以 root 跑時 chmod 無效，分開讓它可跳過）。
//
// 誠實界線（plan 明寫）：「width 硬改 1」的變異行為全等，本測試抓不到——
// 效能差異由 docs/measurements/ 的量測紀錄守，不由測試守。

private let sessionA = "11111111-2222-3333-4444-555555555555"

private func assertScanResultsEqual(
    _ a: ScanResult, _ b: ScanResult,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
) {
    #expect(a.chunks == b.chunks, "chunks（含順序）必須全等", sourceLocation: sourceLocation)
    #expect(a.state == b.state, sourceLocation: sourceLocation)
    #expect(a.invalidatedSources == b.invalidatedSources, sourceLocation: sourceLocation)
    #expect(a.unreadableSources == b.unreadableSources, sourceLocation: sourceLocation)
    #expect(a.skipped == b.skipped, sourceLocation: sourceLocation)
}

@Test("並行掃描（width 4）與循序（width 1）輸出全等——全量與增量兩輪")
func parallelScanMatchesSequentialScanExactly() throws {
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }

    // 8 個檔案跨 3 個 project：夠多才有真正的交錯機會。
    for p in 1...3 {
        for f in 1...(p == 3 ? 2 : 3) {
            try _ = writeSession(
                in: root, project: "proj-\(p)", file: "s\(f).jsonl",
                lines: (1...4).map {
                    turnLine(
                        uuid: "aaaaaaa\(p)-000\(f)-4000-8000-00000000000\($0)",
                        session: sessionA, role: $0.isMultiple(of: 2) ? "assistant" : "user",
                        text: "p\(p) f\(f) turn \($0) 內容")
                } + ["這行不是 JSON"])  // skip 行：unparseableLine 每檔 +1
        }
    }

    let scanner = CorpusScanner(corpusRoot: root, anchorKey: .forTesting)
    let seq1 = try scanner.scan(concurrency: 1)
    let par1 = try scanner.scan(concurrency: 4)
    assertScanResultsEqual(par1, seq1)
    #expect(!seq1.chunks.isEmpty)

    // 第二輪：append（續讀）＋改寫（invalidated）＋刪除（消失作廢）＋結尾半行。
    let appended = root.appendingPathComponent("proj-1/s1.jsonl")
    let more =
        turnLine(
            uuid: "bbbbbbb1-0001-4000-8000-000000000009", session: sessionA,
            role: "user", text: "append 的新 turn") + "\n" + "{\"half\": "  // 半行
    let handle = try FileHandle(forWritingTo: appended)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(more.utf8))
    try handle.close()
    try _ = writeSession(
        in: root, project: "proj-2", file: "s1.jsonl",
        lines: [
            turnLine(
                uuid: "ccccccc2-0001-4000-8000-000000000001", session: sessionA,
                role: "user", text: "整檔改寫後的內容")
        ])
    try FileManager.default.removeItem(at: root.appendingPathComponent("proj-3/s2.jsonl"))

    let seq2 = try scanner.scan(previous: seq1.state, concurrency: 1)
    let par2 = try scanner.scan(previous: seq1.state, concurrency: 4)
    assertScanResultsEqual(par2, seq2)
    #expect(seq2.invalidatedSources.contains { $0.hasSuffix("s1.jsonl") })
}

@Test("並行掃描對讀不到的檔案與循序同判——沿用 prior、標 unreadable")
func parallelScanTreatsUnreadableFilesLikeSequential() throws {
    // root 身分下 chmod 000 擋不住讀取；此時本測試驗不了要驗的東西，跳過。
    try #require(getuid() != 0, "root 不受權限位元約束")
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    for f in 1...3 {
        try _ = writeSession(
            in: root, project: "proj", file: "s\(f).jsonl",
            lines: [
                turnLine(
                    uuid: "ddddddd0-000\(f)-4000-8000-000000000001", session: sessionA,
                    role: "user", text: "檔 \(f)")
            ])
    }
    let scanner = CorpusScanner(corpusRoot: root, anchorKey: .forTesting)
    let first = try scanner.scan(concurrency: 1)
    let locked = root.appendingPathComponent("proj/s2.jsonl")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: locked.path)
    }
    let seq = try scanner.scan(previous: first.state, concurrency: 1)
    let par = try scanner.scan(previous: first.state, concurrency: 4)
    assertScanResultsEqual(par, seq)
    #expect(seq.unreadableSources.count == 1)
}
