import Foundation
import Testing

@testable import LTMCore
@testable import LTMIndex

// Fixture 一律合成。CLAUDE.md 的隱私邊界寫得很直接：測試 fixture 不從真實
// `~/.claude/projects/` 複製片段進 repo。這裡的文字全是造出來的。

/// 造一個臨時語料樹，回傳它的根。呼叫端負責刪。
func makeFixtureCorpus() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// 一則合法的 turn 紀錄。
func turnLine(
    uuid: String, session: String, role: String, text: String,
    timestamp: String = "2026-08-17T06:00:00.000Z"
) -> String {
    let object: [String: Any] = [
        "type": role == "user" ? "user" : "assistant",
        "uuid": uuid,
        "sessionId": session,
        "timestamp": timestamp,
        "message": ["role": role, "content": text],
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

func writeSession(
    in corpusRoot: URL, project: String, file: String, lines: [String]
) throws -> URL {
    let projectDir = corpusRoot.appendingPathComponent(project)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let url = projectDir.appendingPathComponent(file)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
}

private let sessionA = "11111111-2222-3333-4444-555555555555"

@Test("全量掃描讀出每一則 turn，並帶齊四欄指標")
func fullScanProducesPointeredChunks() throws {
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try writeSession(
        in: root, project: "proj-one", file: "session.jsonl",
        lines: [
            turnLine(
                uuid: "aaaaaaaa-0000-0000-0000-000000000001", session: sessionA,
                role: "user", text: "第一則提問"),
            turnLine(
                uuid: "aaaaaaaa-0000-0000-0000-000000000002", session: sessionA,
                role: "assistant", text: "第一則回覆"),
        ])

    let result = try CorpusScanner(corpusRoot: root).scan()

    #expect(result.chunks.count == 2)
    for chunk in result.chunks {
        #expect(chunk.project == "proj-one")
        #expect(!chunk.sessionID.isEmpty)
        #expect(!chunk.uuid.isEmpty)
        #expect(chunk.timestamp.timeIntervalSince1970 > 0)
    }
}

@Test("附加後的增量掃描只讀新內容，且不作廢既有來源")
func incrementalScanReadsOnlyTheTail() throws {
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try writeSession(
        in: root, project: "proj-one", file: "session.jsonl",
        lines: [
            turnLine(
                uuid: "aaaaaaaa-0000-0000-0000-000000000001", session: sessionA,
                role: "user", text: "第一則提問")
        ])
    let scanner = CorpusScanner(corpusRoot: root)
    let first = try scanner.scan()
    #expect(first.chunks.count == 1)

    let appended =
        turnLine(
            uuid: "aaaaaaaa-0000-0000-0000-000000000002", session: sessionA,
            role: "assistant", text: "後來補上的回覆") + "\n"
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(appended.utf8))
    try handle.close()

    let second = try scanner.scan(previous: first.state)

    // 只讀到新那一則——舊的那則不會重複出現。
    #expect(second.chunks.count == 1)
    #expect(second.chunks.first?.uuid == "aaaaaaaa-0000-0000-0000-000000000002")
    #expect(second.invalidatedSources.isEmpty)
}

@Test("被改寫的來源整份重解，並回報需要作廢")
func rewrittenSourceIsFullyReparsed() throws {
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try writeSession(
        in: root, project: "proj-one", file: "session.jsonl",
        lines: [
            turnLine(
                uuid: "aaaaaaaa-0000-0000-0000-000000000001", session: sessionA,
                role: "user", text: "原始內容")
        ])
    let scanner = CorpusScanner(corpusRoot: root)
    let first = try scanner.scan()

    // 改寫既有 bytes（不是附加）——長度刻意變長，避免測試只靠「變短」通過。
    _ = try writeSession(
        in: root, project: "proj-one", file: "session.jsonl",
        lines: [
            turnLine(
                uuid: "aaaaaaaa-0000-0000-0000-000000000001", session: sessionA,
                role: "user", text: "改寫後的內容，比原本長一些"),
            turnLine(
                uuid: "aaaaaaaa-0000-0000-0000-000000000003", session: sessionA,
                role: "assistant", text: "新增的一則"),
        ])

    let second = try scanner.scan(previous: first.state)

    #expect(second.invalidatedSources.contains("proj-one/session.jsonl"))
    #expect(second.chunks.count == 2)
    // 舊 anchor 綁的是舊文字，所以改寫後的 chunk 一定有不同的 content hash。
    #expect(second.chunks.first?.anchor.contentHash != first.chunks.first?.anchor.contentHash)
}

@Test("非 turn 紀錄與缺欄位紀錄被跳過並記帳，不中止掃描")
func malformedRecordsAreSkippedAndTallied() throws {
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try writeSession(
        in: root, project: "proj-one", file: "session.jsonl",
        lines: [
            #"{"type":"queue-operation","operation":"enqueue"}"#,
            #"{"type":"user","sessionId":"11111111-2222-3333-4444-555555555555","timestamp":"2026-08-17T06:00:00.000Z","message":{"role":"user","content":"缺 uuid"}}"#,
            #"{"type":"user","uuid":"aaaaaaaa-0000-0000-0000-000000000009","sessionId":"含中文的非法識別碼","timestamp":"2026-08-17T06:00:00.000Z","message":{"role":"user","content":"識別碼不合法"}}"#,
            #"not json at all"#,
            turnLine(
                uuid: "aaaaaaaa-0000-0000-0000-000000000001", session: sessionA,
                role: "user", text: "唯一一則合法內容"),
        ])

    let result = try CorpusScanner(corpusRoot: root).scan()

    #expect(result.chunks.count == 1)
    #expect(result.skipped.notATurn == 1)
    #expect(result.skipped.missingPointerField == 1)
    #expect(result.skipped.malformedIdentifier == 1)
    #expect(result.skipped.unparseableLine == 1)
}

@Test("只有 tool payload 的 turn 沒有可索引文字，被跳過而不是造出空 anchor")
func toolOnlyTurnIsSkipped() throws {
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let toolOnly = """
        {"type":"assistant","uuid":"aaaaaaaa-0000-0000-0000-00000000000a",\
        "sessionId":"11111111-2222-3333-4444-555555555555",\
        "timestamp":"2026-08-17T06:00:00.000Z",\
        "message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}
        """
    _ = try writeSession(
        in: root, project: "proj-one", file: "session.jsonl", lines: [toolOnly])

    let result = try CorpusScanner(corpusRoot: root).scan()

    #expect(result.chunks.isEmpty)
    #expect(result.skipped.noIndexableText == 1)
}

@Test("block 陣列只取 text block")
func blockArrayTakesTextBlocksOnly() {
    let content: [[String: Any]] = [
        ["type": "thinking", "thinking": "內部推理不該進索引"],
        ["type": "text", "text": "第一段"],
        ["type": "tool_use", "name": "Read"],
        ["type": "text", "text": "第二段"],
    ]
    #expect(CorpusScanner.indexableText(from: content) == "第一段\n第二段")
}

/// 判定「在語料內」的合成 policy：把指定前綴當成語料。
///
/// 真正的判定（inode 身分、symlink、firmlink）由 LTMMemory 的 `CorpusLocation`
/// 提供並在 facade 注入，它自己的守衛測試在 LTMMemoryTests。這裡要驗的是
/// **`DerivedLocation` 有沒有真的去問 policy**，不是重測那份判定。
private struct PrefixPolicy: CorpusContainmentPolicy {
    let corpus: URL
    func isInsideReadOnlyCorpus(_ url: URL) -> Bool {
        url.path == corpus.path || url.path.hasPrefix(corpus.path + "/")
    }
}

@Test("衍生輸出路徑落在語料內時，建構就失敗")
func derivedLocationRefusesCorpusPaths() {
    let corpus = URL(fileURLWithPath: "/tmp/fake-corpus")
    let policy = PrefixPolicy(corpus: corpus)
    #expect(throws: DerivedLocation.LocationError.self) {
        _ = try DerivedLocation(root: corpus.appendingPathComponent("derived"), policy: policy)
    }
}

@Test("policy 放行時衍生根照常建立")
func derivedLocationAcceptsOutsidePaths() throws {
    let corpus = URL(fileURLWithPath: "/tmp/fake-corpus")
    let outside = URL(fileURLWithPath: "/tmp/fake-derived")
    let location = try DerivedLocation(root: outside, policy: PrefixPolicy(corpus: corpus))
    #expect(location.databaseURL.lastPathComponent == "index.sqlite3")
    #expect(location.stateURL.lastPathComponent == "state.json")
}

@Test("掃描不動語料：檔案內容與修改時間都不變")
func scanLeavesCorpusUntouched() throws {
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try writeSession(
        in: root, project: "proj-one", file: "session.jsonl",
        lines: [
            turnLine(
                uuid: "aaaaaaaa-0000-0000-0000-000000000001", session: sessionA,
                role: "user", text: "掃描前後都該一模一樣")
        ])
    let before = try Data(contentsOf: url)
    let beforeAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let beforeModified = beforeAttributes[.modificationDate] as? Date

    _ = try CorpusScanner(corpusRoot: root).scan()

    #expect(try Data(contentsOf: url) == before)
    let afterAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(afterAttributes[.modificationDate] as? Date == beforeModified)
}

@Test("三個 project、五十則 turn 的語料產生恰好五十個 chunk，四欄指標齊備")
func fixtureCorpusYieldsOneChunkPerTurn() throws {
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }

    // 三個 project，每個一個 session；50 則平均分配（17 / 17 / 16）。
    let layout = [("proj-alpha", 17), ("proj-beta", 17), ("proj-gamma", 16)]
    var expectedUUIDs: Set<String> = []
    for (index, (project, turnCount)) in layout.enumerated() {
        let session = "0000000\(index)-1111-2222-3333-444444444444"
        var lines: [String] = []
        for turn in 0..<turnCount {
            let uuid = String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", index * 100 + turn)
            expectedUUIDs.insert(uuid)
            lines.append(
                turnLine(
                    uuid: uuid, session: session,
                    role: turn.isMultiple(of: 2) ? "user" : "assistant",
                    text: "第 \(turn) 則合成內容"))
        }
        _ = try writeSession(in: root, project: project, file: "session.jsonl", lines: lines)
    }

    let result = try CorpusScanner(corpusRoot: root).scan()

    #expect(result.chunks.count == 50)
    #expect(Set(result.chunks.map(\.uuid)) == expectedUUIDs)
    #expect(Set(result.chunks.map(\.project)).count == 3)
    for chunk in result.chunks {
        #expect(!chunk.project.isEmpty)
        #expect(!chunk.sessionID.isEmpty)
        #expect(!chunk.uuid.isEmpty)
        #expect(chunk.timestamp.timeIntervalSince1970 > 0)
        // anchor 綁的內容必須真的能還原成該 chunk 的文字。
        #expect(chunk.anchor.turnID == chunk.uuid)
        #expect(chunk.anchor.source == chunk.sessionID)
    }
}
