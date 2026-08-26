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

    let result = try CorpusScanner(corpusRoot: root, anchorKey: .forTesting).scan()

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
    let scanner = CorpusScanner(corpusRoot: root, anchorKey: .forTesting)
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
    let scanner = CorpusScanner(corpusRoot: root, anchorKey: .forTesting)
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

    let result = try CorpusScanner(corpusRoot: root, anchorKey: .forTesting).scan()

    #expect(result.chunks.count == 1)
    #expect(result.skipped.notATurn == 1)
    #expect(result.skipped.missingPointerField == 1)
    #expect(result.skipped.malformedIdentifier == 1)
    #expect(result.skipped.unparseableLine == 1)
}

@Test("只有 tool block 的 turn 現在會產出 chunk——但只含 metadata")
func toolOnlyTurnIsIndexedAsMetadata() throws {
    // **這條測試先前編碼的是相反的行為**（tool-only turn 被跳過）。#6 改掉了它：
    // 實測語料裡 78.7% 的字元量對檢索完全不可見，而 tool-only turn 正是其中一大類。
    //
    // 改的是「收不收」，不是「收多少」——payload 仍然不收，見下一條。
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let toolOnly = """
        {"type":"assistant","uuid":"aaaaaaaa-0000-0000-0000-00000000000a",\
        "sessionId":"11111111-2222-3333-4444-555555555555",\
        "timestamp":"2026-08-17T06:00:00.000Z",\
        "message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash",\
        "input":{"command":"swift test"}}]}}
        """
    _ = try writeSession(
        in: root, project: "proj-one", file: "session.jsonl", lines: [toolOnly])

    let result = try CorpusScanner(corpusRoot: root, anchorKey: .forTesting).scan()

    let chunk = try #require(result.chunks.first, "tool-only turn 現在該被索引")
    #expect(chunk.text.contains("Bash"), "工具名要搜得到")
    #expect(chunk.text.contains("swift test"), "指令要搜得到——那是「做了什麼」")
    #expect(result.skipped.noIndexableText == 0)
}

@Test("tool_use 的 payload 欄位不進索引，只有封閉列舉的 metadata 欄位")
func toolPayloadFieldsAreNotIndexed() {
    // #6 的**安全性質**：收的是「做了什麼」，不是「結果是什麼」。
    //
    // `content` / `new_string` / `old_string` 是 payload——一個 Write 呼叫的
    // `content` 就是整個檔案內容，而語料裡那可能是第三方逐字內容。
    let block: [String: Any] = [
        "type": "tool_use", "name": "Write",
        "input": [
            "file_path": "/tmp/notes.md",
            "content": "SENTINEL-第三方逐字內容-不得進索引",
            "old_string": "SENTINEL-舊內容",
        ],
    ]
    let text = CorpusScanner.indexableText(from: [block])

    #expect(text.contains("Write"))
    #expect(text.contains("/tmp/notes.md"), "路徑是 metadata")
    #expect(!text.contains("SENTINEL"), "payload 欄位外洩到索引")
}

@Test("tool_result 只記成敗，不記內容")
func toolResultRecordsOutcomeNotContent() {
    // 丟掉的 65.7% 就是這一項。收成敗讓「那次跑掛了嗎」搜得到，而不把輸出收進來。
    let ok: [String: Any] = ["type": "tool_result", "content": "SENTINEL-命令輸出"]
    let bad: [String: Any] = [
        "type": "tool_result", "is_error": true, "content": "SENTINEL-錯誤訊息",
    ]
    let text = CorpusScanner.indexableText(from: [ok, bad])

    #expect(text.contains("ok"))
    #expect(text.contains("error"))
    #expect(!text.contains("SENTINEL"), "tool_result 的內容外洩到索引")
}

@Test("指令裡夾帶的長內容被截斷——而那不是一道邊界")
func longCommandsAreClipped() {
    let smuggled = String(repeating: "秘", count: 500)
    let block: [String: Any] = [
        "type": "tool_use", "name": "Bash",
        "input": ["command": "echo \(smuggled) > f"],
    ]
    let text = CorpusScanner.indexableText(from: [block])

    #expect(text.count < 300, "超過上限要截斷")
    // **誠實邊界**：截斷讓夾帶的東西留不住完整，但一個**短的**夾帶仍然會整個進去。
    // 這條測試釘的是截斷有發生，不是「夾帶被擋住了」——後者不成立。
    let short: [String: Any] = [
        "type": "tool_use", "name": "Bash", "input": ["command": "echo 短夾帶 > f"],
    ]
    #expect(CorpusScanner.indexableText(from: [short]).contains("短夾帶"))
}

@Test("block 陣列：text 逐字保留，tool block 轉成 metadata，thinking 不進索引")
func blockArrayTakesTextAndToolMetadata() {
    let content: [[String: Any]] = [
        ["type": "thinking", "thinking": "內部推理不該進索引"],
        ["type": "text", "text": "第一段"],
        ["type": "tool_use", "name": "Read", "input": ["file_path": "/x"]],
        ["type": "text", "text": "第二段"],
    ]
    let text = CorpusScanner.indexableText(from: content)
    #expect(text.contains("第一段") && text.contains("第二段"))
    #expect(text.contains("Read") && text.contains("/x"))
    #expect(!text.contains("內部推理"), "thinking 不進索引")
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

    _ = try CorpusScanner(corpusRoot: root, anchorKey: .forTesting).scan()

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

    let result = try CorpusScanner(corpusRoot: root, anchorKey: .forTesting).scan()

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
        // source 是 **project 指紋**，不是 sessionID——後者在 session resume 時會變，
        // 用它定址會讓使用歷史蒸發（見 ProjectFingerprint）。sessionID 仍在 chunk 上，
        // 但只作導航用。
        #expect(chunk.anchor.source == ProjectFingerprint.of(chunk.project))
        #expect(chunk.anchor.source != chunk.sessionID)
    }
}

@Test("同一則 turn 經由兩個 session 檔觀察到時，anchor 相同（跨 resume 存活）")
func anchorSurvivesSessionResume() throws {
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }

    // 模擬 session resume：同一則 turn（相同 uuid、相同文字）被複製進第二個 session 檔，
    // 但帶著新的 sessionId。全語料 8,324 檔有 12,488 個 turn 是這個形狀（見
    // `docs/measurements/2026-08-18-resume-duplication.md`），
    // 其中 98.9% 的 sessionId 不同。
    let sharedTurn = "aaaaaaaa-0000-0000-0000-000000000001"
    let text = "跨越 resume 的同一段內容"
    _ = try writeSession(
        in: root, project: "proj-one", file: "session-A.jsonl",
        lines: [turnLine(uuid: sharedTurn, session: "11111111-1111-1111-1111-111111111111",
                         role: "user", text: text)])
    _ = try writeSession(
        in: root, project: "proj-one", file: "session-B.jsonl",
        lines: [
            turnLine(uuid: sharedTurn, session: "22222222-2222-2222-2222-222222222222",
                     role: "user", text: text),
            turnLine(uuid: "aaaaaaaa-0000-0000-0000-000000000002",
                     session: "22222222-2222-2222-2222-222222222222",
                     role: "assistant", text: "resume 之後才有的新內容"),
        ])

    let result = try CorpusScanner(corpusRoot: root, anchorKey: .forTesting).scan()
    let shared = result.chunks.filter { $0.uuid == sharedTurn }

    #expect(shared.count == 2, "掃描階段兩個檔各產生一筆；去重是索引層的職責（task 2.2）")
    // 關鍵斷言：兩筆的 sessionID 不同，但 anchor 完全相同——這正是舊實作壞掉的地方。
    #expect(Set(shared.map(\.sessionID)).count == 2)
    #expect(Set(shared.map(\.anchor)).count == 1, "同一則 turn 必須得到同一個 anchor，否則使用歷史會在 resume 後對不上")
}

@Test("來源檔消失時它的 chunk 被作廢")
func deletedSourceIsInvalidated() throws {
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try writeSession(in: root, project: "proj-one", file: "a.jsonl",
        lines: [turnLine(uuid: "aaaaaaaa-0000-0000-0000-000000000001", session: sessionA,
                         role: "user", text: "甲檔的內容")])
    _ = try writeSession(in: root, project: "proj-one", file: "b.jsonl",
        lines: [turnLine(uuid: "aaaaaaaa-0000-0000-0000-000000000002", session: sessionA,
                         role: "user", text: "乙檔的內容")])
    let scanner = CorpusScanner(corpusRoot: root, anchorKey: .forTesting)
    let first = try scanner.scan()
    #expect(first.chunks.count == 2)

    try FileManager.default.removeItem(at: root.appendingPathComponent("proj-one/a.jsonl"))
    let second = try scanner.scan(previous: first.state)

    #expect(second.invalidatedSources.contains("proj-one/a.jsonl"),
            "消失的來源必須被作廢，否則增量索引會保留全量重建不會有的內容（不變式 2）")
    #expect(second.unreadableSources.isEmpty)
    #expect(!second.state.files.keys.contains("proj-one/a.jsonl"))
}

@Test("不完整的最後一行不推進 offset，下一輪補完後被索引")
func incompleteTrailingRecordIsRereadNextScan() throws {
    let root = try makeFixtureCorpus()
    defer { try? FileManager.default.removeItem(at: root) }
    let complete = turnLine(uuid: "aaaaaaaa-0000-0000-0000-000000000001", session: sessionA,
                            role: "user", text: "完整的第一則")
    let full = turnLine(uuid: "aaaaaaaa-0000-0000-0000-000000000002", session: sessionA,
                        role: "user", text: "後來才寫完的第二則")
    // 模擬「正在被 append」：第二行只寫了一半，且沒有結尾換行。
    let url = root.appendingPathComponent("proj-one/s.jsonl")
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (complete + "\n" + String(full.prefix(full.count / 2))).write(
        to: url, atomically: true, encoding: .utf8)

    let scanner = CorpusScanner(corpusRoot: root, anchorKey: .forTesting)
    let first = try scanner.scan()
    #expect(first.chunks.count == 1, "只有完整的那一則被索引")
    #expect(first.skipped.incompleteTrailingRecord == 1, "半行要單獨記帳，不可混進 malformed")
    #expect(first.skipped.unparseableLine == 0, "並行寫入不是語料損壞")

    // 補完檔案後再掃：那一則必須被索引到。
    try (complete + "\n" + full + "\n").write(to: url, atomically: true, encoding: .utf8)
    let second = try scanner.scan(previous: first.state)
    #expect(second.chunks.contains { $0.uuid == "aaaaaaaa-0000-0000-0000-000000000002" },
            "半行補完後必須被索引 —— 先前它會永久消失且無錯誤訊息")
}

// MARK: - #26：目錄層失敗不得被轉成「沒有東西」

@Test("語料根列不出來時拋錯，不是回報零個 project")
func anUnlistableCorpusRootThrows() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-scan-\(UUID().uuidString)")
    let corpus = base.appendingPathComponent("corpus")
    try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: corpus.path)
        try? FileManager.default.removeItem(at: base)
    }
    // 先放一個 project，讓「零個」與「讀不到」在結果上有差別。
    let proj = corpus.appendingPathComponent("proj-one")
    try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: proj.appendingPathComponent("s.jsonl"))

    // 拿掉讀取權限 → contentsOfDirectory 失敗。
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: corpus.path)

    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    // 先前這裡是 `(try? …) ?? []`——失敗變成「零個 project」，而零個 project 會讓
    // `scan` 把**整份索引**作廢並回報成功。
    #expect(throws: CorpusScanner.ScanError.corpusRootUnreadable(path: corpus.path)) {
        _ = try scanner.scan(previous: ScanState())
    }
}

@Test("列不出內容的 project，其既有來源被當成讀不到而非消失")
func anUnlistableProjectProtectsItsPriorSources() throws {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-scan-\(UUID().uuidString)")
    let corpus = base.appendingPathComponent("corpus")
    let proj = corpus.appendingPathComponent("proj-one")
    try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: proj.path)
        try? FileManager.default.removeItem(at: base)
    }
    let line = #"{"uuid":"00000000-aaaa-bbbb-cccc-dddddddddddd","sessionId":"11111111-2222-3333-4444-555555555555","timestamp":"2026-08-17T06:00:00Z","type":"user","message":{"role":"user","content":"記憶策略的內容夠長可以切"}}"#
    try Data((line + "\n").utf8).write(to: proj.appendingPathComponent("s.jsonl"))

    let scanner = CorpusScanner(corpusRoot: corpus, anchorKey: .forTesting)
    let first = try scanner.scan(previous: ScanState())
    #expect(!first.chunks.isEmpty, "前提：第一輪要真的讀到東西")
    let knownKeys = Set(first.state.files.keys)
    #expect(!knownKeys.isEmpty)

    // 拿掉 project 的讀取權限 → enumerator 回 nil。
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: proj.path)

    let second = try scanner.scan(previous: first.state)

    // **核心**：先前是 `else { continue }`——那個 project 一個檔都沒被看到，於是
    // 下一段的「上一輪有、這一輪沒看到 → 消失」把它全部作廢，而命令回報成功。
    #expect(
        second.invalidatedSources.isEmpty,
        "列不出目錄被當成消失——一次權限錯誤會清空該 project 的索引，而且看起來是成功的")
    #expect(
        knownKeys.isSubset(of: second.unreadableSources),
        "讀不到的來源必須被說出來，不能只是不作廢就算了")
    // 狀態要保留，否則下一輪它們仍會被當成新檔案整份重解。
    #expect(knownKeys.isSubset(of: Set(second.state.files.keys)))
}
