import CryptoKit
import Foundation
import Testing

@testable import LTMIndex

/// #47：byte-cursor 來源內分批的掃描層——每個 chunk 帶可對檔案驗證的切點游標。

// MARK: - ① Canary：CryptoKit hasher 的值語意快照

/// **整個 #47 唯一的外部假設**：`SHA256` 是 value type，複製後對副本 `finalize()`
/// 得到中間 digest、原件可以繼續 `update`。swiftinterface 宣告
/// `public struct SHA256 : Swift.Sendable` 且 `finalize()` 非 mutating——若內部
/// 共享可變參考態，那個 Sendable 宣告就不健全。這條現在即綠；**它變紅 = 假設
/// 破產**，fallback 是 CommonCrypto 的 `CC_SHA256_CTX`（純 C struct，值複製有
/// 快照保證），不是回退 staging 方案。
@Test("增量 hasher 的快照等於一次性 digest")
func snapshotOfIncrementalHasherMatchesOneShotDigest() {
    var hasher = SHA256()
    hasher.update(data: Data("ab".utf8))
    let snapshot = hasher
    let mid = snapshot.finalize().map { String(format: "%02x", $0) }.joined()
    #expect(mid == CorpusScanner.hexDigest(Data("ab".utf8)))

    hasher.update(data: Data("cd".utf8))
    let full = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    #expect(full == CorpusScanner.hexDigest(Data("abcd".utf8)))
}

// MARK: - ② 每個 chunk 的游標可對檔案驗證

@Test("每個 chunk 帶可驗證的切點游標")
func everyChunkCarriesAVerifiableCursor() throws {
    let corpus = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: corpus) }
    // 混四種 skip 行 + 三個 turn + 尾端半行（無換行）。
    let lines = [
        "{\"type\":\"summary\",\"summary\":\"摘要行\"}",
        turnLine(
            uuid: "00000001-aaaa-bbbb-cccc-dddddddddddd", session: sessionForCursorTests,
            role: "user", text: "第一段內容第一段內容第一段內容"),
        "not json at all",
        turnLine(
            uuid: "00000002-aaaa-bbbb-cccc-dddddddddddd", session: sessionForCursorTests,
            role: "assistant", text: "第二段內容第二段內容第二段內容"),
        "{\"type\":\"user\",\"uuid\":\"bad\"}",
        turnLine(
            uuid: "00000003-aaaa-bbbb-cccc-dddddddddddd", session: sessionForCursorTests,
            role: "user", text: "第三段內容第三段內容第三段內容"),
    ]
    let url = try writeSession(
        in: corpus, project: "proj-cursor", file: "s.jsonl", lines: lines)
    // 尾端補半行（不含換行——parse 要留給下一輪）。
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"type\":\"user\",\"uuid\":\"".utf8))
    try handle.close()

    let fileData = try Data(contentsOf: url)
    let result = try CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting).scan()

    #expect(result.chunks.count == 3, "三個合法 turn，實得 \(result.chunks.count)")
    var previousEnd = 0
    for scanned in result.chunks {
        #expect(scanned.endOffset > previousEnd, "endOffset 嚴格遞增")
        previousEnd = scanned.endOffset
        #expect(
            CorpusScanner.hexDigest(fileData.prefix(scanned.endOffset))
                == scanned.prefixHashAtEnd,
            "游標必須對檔案可驗證：offset \(scanned.endOffset)")
    }
    let state = try #require(result.state.files["proj-cursor/s.jsonl"])
    #expect(previousEnd <= state.processedBytes, "最後一個切點不超過最終游標")
    #expect(
        state.processedBytes < fileData.count, "半行要留給下一輪（processed < 檔案大小）")
}

// MARK: - ③ 中途游標續讀不 invalidate

@Test("以 chunk 切點當 prior 游標續讀：只吐之後的 chunk、不 invalidate、終態相同")
func aMidFileCursorResumesWithoutInvalidation() throws {
    let corpus = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: corpus) }
    let lines = (1...4).map { i in
        turnLine(
            uuid: String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", i),
            session: sessionForCursorTests,
            role: i.isMultiple(of: 2) ? "assistant" : "user",
            text: "第 \(i) 段內容第 \(i) 段內容第 \(i) 段內容")
    }
    _ = try writeSession(in: corpus, project: "proj-cursor", file: "r.jsonl", lines: lines)
    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)

    let fullScan = try scanner.scan()
    #expect(fullScan.chunks.count == 4)
    let cutAt = fullScan.chunks[1]  // 第 2 個 chunk 的切點當「已提交到這裡」

    let resumed = try scanner.scan(
        previous: ScanState(files: [
            "proj-cursor/r.jsonl": SourceFileState(
                prefixHash: cutAt.prefixHashAtEnd, processedBytes: cutAt.endOffset)
        ]))
    #expect(
        resumed.invalidatedSources.isEmpty,
        "中途游標雜湊相符就不是 invalidated——這正是 Expected ② 不需要 staging 的理由")
    #expect(
        resumed.chunks.map(\.chunk.uuid) == fullScan.chunks.suffix(2).map(\.chunk.uuid),
        "只吐游標之後的 chunk")
    #expect(
        resumed.state.files["proj-cursor/r.jsonl"]
            == fullScan.state.files["proj-cursor/r.jsonl"],
        "續讀後的終態與一次掃完相同")
}

private let sessionForCursorTests = "11111111-2222-3333-4444-555555555555"
