import Foundation
import Testing

@testable import LTMCore
@testable import LTMIndex
@testable import LTMMemory
@testable import LTMService
@testable import ltm

// CLI 的行為測試走**真的執行檔**，而不是直接呼叫 facade：要驗的正是 adapter
// 這一層（旗標解析、範圍解析、結束碼、輸出格式）。直接呼叫 facade 會把 adapter
// 整個跳過，那樣的測試在 adapter 壞掉時仍然全綠。

/// 跑一次 `ltm`，回傳 (結束碼, stdout, stderr)。
@discardableResult
private func runCLI(_ arguments: [String], environment extra: [String: String]) throws -> (
    code: Int32, out: String, err: String
) {
    let binary = try ltmExecutable()
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    // **測試 harness 自己注入 anchor 密鑰**（#12）。
    //
    // 沒有這一行，每個 `swift test` 都會讓 `ltm` 去碰 Keychain，而 swift-testing
    // 的 exit test 會 re-exec 測試 binary——那個 subprocess 沒有登入鑰匙圈
    // session，macOS 因此彈出「找不到鑰匙圈」對話框並把測試卡住（實測一條等了
    // 116 秒）。放在這裡而不是要求操作者設環境變數：一個「你得先設某個變數才
    // 跑得動」的測試套件，遲早會有人在沒設的情況下看到那個對話框。
    //
    // 這**不是** opt-out：注入的是一把真的密鑰，只是來源不同。
    environment["LTM_ANCHOR_KEY"] = String(repeating: "2a", count: 32)
    for (key, value) in extra { environment[key] = value }
    process.environment = environment
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(data: outData, encoding: .utf8) ?? "",
        String(data: errData, encoding: .utf8) ?? ""
    )
}

/// `ltm` 執行檔的位置。
///
/// 從 `#filePath` 往上找 repo 根再進 `.build/`，**不用 `Bundle.allBundles`**：
/// 在 swift-testing 底下那個清單裡沒有 xctest bundle，於是它會回退到
/// toolchain 目錄，測試就變成「找不到執行檔」而不是在測 CLI。
private func ltmExecutable(file: StaticString = #filePath) throws -> URL {
    var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path)
        {
            for configuration in ["debug", "release"] {
                let candidate = directory.appendingPathComponent(".build/\(configuration)/ltm")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            throw CLINotBuilt()
        }
        directory = directory.deletingLastPathComponent()
    }
    throw CLINotBuilt()
}

private struct CLINotBuilt: Error {}

/// 一個含合成語料的臨時工作區。
private struct CLIWorkspace {
    let base: URL
    var corpus: URL { base.appendingPathComponent("corpus") }
    var derived: URL { base.appendingPathComponent("derived") }
    var memory: URL { base.appendingPathComponent("mem") }
    var eventsFile: URL { memory.appendingPathComponent("memory/events.jsonl") }

    var environment: [String: String] {
        [
            "LTM_CORPUS_ROOT": corpus.path,
            "LTM_DERIVED_ROOT": derived.path,
            "LTM_MEMORY_ROOT": memory.path,
            // **HOME 也要隔離**。三個 LTM_* 變數若因為改名或打錯而失效，程式會
            // 回退到 `NSHomeDirectory()` —— 也就是使用者真實的 `~/.claude/projects`
            // 與 `~/.claude-ltm/`。那時測試會安靜地讀寫真實資料，而且看起來是綠的。
            "HOME": base.path,
        ]
    }

    static func make(project: String = "proj-demo", texts: [String]) throws -> CLIWorkspace {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltm-cli-\(UUID().uuidString)")
        let workspace = CLIWorkspace(base: base)
        let projectDir = workspace.corpus.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let lines = texts.enumerated().map { offset, text -> String in
            let object: [String: Any] = [
                "type": offset.isMultiple(of: 2) ? "user" : "assistant",
                "uuid": String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", offset),
                "sessionId": "11111111-2222-3333-4444-555555555555",
                "timestamp": "2026-08-17T06:00:00.000Z",
                "message": ["role": "user", "content": text],
            ]
            return String(
                data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: projectDir.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        return workspace
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    /// 一個含 session resume 複製的語料：`shared` 那則 turn 同時存在於兩份檔案，
    /// **uuid、內容、時間戳完全相同**（resume 複製不改這些），只有 `sessionId` 不同；
    /// `uniqueToA` 只存在於第一份檔案。
    ///
    /// 時間戳刻意相同——那正是 #25 的情形：時間戳比較永遠平手，先前實際由檔名
    /// 字典序決定回報哪一個 session。
    static func makeWithResumeDuplicate(
        project: String = "proj-demo", shared: String, uniqueToA: String,
        sessionA: String, sessionB: String
    ) throws -> CLIWorkspace {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ltm-cli-\(UUID().uuidString)")
        let workspace = CLIWorkspace(base: base)
        let projectDir = workspace.corpus.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        func line(uuid: String, session: String, text: String) -> String {
            let object: [String: Any] = [
                "type": "user",
                "uuid": uuid,
                "sessionId": session,
                "timestamp": "2026-08-17T06:00:00.000Z",
                "message": ["role": "user", "content": text],
            ]
            return String(
                data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }

        let sharedUUID = "11111111-aaaa-bbbb-cccc-dddddddddddd"
        let uniqueUUID = "22222222-aaaa-bbbb-cccc-dddddddddddd"

        // 檔名刻意讓 s-A 字典序在前，好讓「代表值 = 字典序第一個」可被斷言。
        try ([
            line(uuid: sharedUUID, session: sessionA, text: shared),
            line(uuid: uniqueUUID, session: sessionA, text: uniqueToA),
        ].joined(separator: "\n") + "\n").write(
            to: projectDir.appendingPathComponent("s-A.jsonl"), atomically: true, encoding: .utf8)

        try (line(uuid: sharedUUID, session: sessionB, text: shared) + "\n").write(
            to: projectDir.appendingPathComponent("s-B.jsonl"), atomically: true, encoding: .utf8)

        return workspace
    }
}

@Test("ltm build 建出索引並回報統計，語料保持不變")
func buildSucceedsAndLeavesCorpusUntouched() throws {
    let workspace = try CLIWorkspace.make(texts: ["記憶策略的內容", "檢索量測的內容"])
    defer { workspace.cleanup() }
    let sessionFile = workspace.corpus.appendingPathComponent("proj-demo/s.jsonl")
    let before = try Data(contentsOf: sessionFile)

    let result = try runCLI(["build"], environment: workspace.environment)

    #expect(result.code == 0, "build 失敗，stderr 見測試輸出")
    if result.code != 0 { Issue.record("build stderr: \(result.err)") }
    #expect(result.out.contains("索引完成"))
    #expect(try Data(contentsOf: sessionFile) == before, "建置不得改動語料")
    #expect(
        FileManager.default.fileExists(
            atPath: workspace.derived.appendingPathComponent("index.sqlite3").path))
}

@Test("索引不存在時 ltm query 非零結束，且訊息指名 ltm build")
func queryWithoutIndexNamesBuild() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容"])
    defer { workspace.cleanup() }

    let result = try runCLI(
        ["query", "內容", "--all-projects"], environment: workspace.environment)

    #expect(result.code != 0)
    #expect(result.err.contains("ltm build"), "失敗訊息必須指名補救命令")
}

@Test("無法決定範圍時要求明示，不擴大成全語料")
func ambiguousScopeRefusesInsteadOfWidening() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    // 測試行程的工作目錄對應不到語料裡的任何 project，所以範圍無法推定。
    let result = try runCLI(["query", "內容"], environment: workspace.environment)

    #expect(result.code == LTMCommandLine.ExitCode.scopeError.rawValue)
    #expect(result.err.contains("--project"))
    #expect(result.err.contains("--all-projects"))
    #expect(result.out.isEmpty, "拒絕的查詢不得同時輸出結果")
}

@Test("--json 輸出每筆都帶齊四欄指標")
func jsonOutputIsMachineComplete() throws {
    let workspace = try CLIWorkspace.make(
        texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let result = try runCLI(
        ["query", "記憶策略", "--all-projects", "--json"], environment: workspace.environment)

    #expect(result.code == 0)
    if result.code != 0 { Issue.record("stderr: \(result.err)") }
    let parsed = try JSONSerialization.jsonObject(with: Data(result.out.utf8))
    guard let objects = parsed as? [[String: Any]] else {
        Issue.record("--json 的輸出必須是 JSON 陣列")
        return
    }
    #expect(!objects.isEmpty)
    for object in objects {
        // `sessionId` 不在此列：指標的 session 分量是集合 `sessions`（#25）。
        for field in ["project", "uuid", "timestamp"] {
            let value = object[field] as? String
            #expect(value?.isEmpty == false, "\(field) 缺漏——不變式 3 要求每筆都帶指標")
        }
        #expect(object["snippet"] is String)
        #expect(object["score"] is Double)
        #expect(object["band"] is Int)
    }
}

@Test("--json 的 sessions 陣列：多來源列出全部，單一來源也照樣輸出一個元素")
func jsonCarriesSessionsArrayForBothSingleAndMultiSourceHits() throws {
    let sessionA = "aaaaaaaa-1111-2222-3333-444444444444"
    let sessionB = "bbbbbbbb-1111-2222-3333-444444444444"
    let workspace = try CLIWorkspace.makeWithResumeDuplicate(
        shared: "被 resume 複製的共用內容", uniqueToA: "只在一份檔案裡的內容",
        sessionA: sessionA, sessionB: sessionB)
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let result = try runCLI(
        ["query", "內容", "--all-projects", "--json"], environment: workspace.environment)
    #expect(result.code == 0)
    if result.code != 0 { Issue.record("stderr: \(result.err)") }

    let objects =
        try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [[String: Any]] ?? []
    #expect(objects.count == 2, "共用那則去重後是一筆，加上獨有的那則，共兩筆")

    for object in objects {
        let snippet = object["snippet"] as? String ?? ""
        let sessions = object["sessions"] as? [String] ?? []

        #expect(!sessions.isEmpty, "每一筆都要有 sessions，單一來源也不例外")

        if snippet.contains("共用") {
            #expect(
                sessions.sorted() == [sessionA, sessionB].sorted(),
                "被兩份檔持有的 turn 要回報兩個 session，實得 \(sessions)")
        } else {
            #expect(sessions == [sessionA], "只被一份檔持有的 turn 回報一個 session")
        }
    }
}

@Test("human 輸出：單一來源逐字不變，多來源用複數標籤列出全部 session")
func humanOutputNamesEverySourceOnlyWhenThereIsMoreThanOne() throws {
    let sessionA = "aaaaaaaa-1111-2222-3333-444444444444"
    let sessionB = "bbbbbbbb-1111-2222-3333-444444444444"
    let workspace = try CLIWorkspace.makeWithResumeDuplicate(
        shared: "被 resume 複製的共用內容", uniqueToA: "只在一份檔案裡的內容",
        sessionA: sessionA, sessionB: sessionB)
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let result = try runCLI(
        ["query", "內容", "--all-projects"], environment: workspace.environment)
    #expect(result.code == 0)
    if result.code != 0 { Issue.record("stderr: \(result.err)") }

    // 單一來源那一筆：既有的單數形式逐字不變。
    #expect(
        result.out.contains("↳ session \(sessionA)  turn"),
        "只被一份檔持有的那一筆，指標行應維持既有的單數形式")
    // 多來源那一筆：複數標籤 + 兩個 session 都在。
    #expect(
        result.out.contains("↳ sessions "),
        "被兩份檔持有的那一筆，指標行應改用複數標籤")
    #expect(
        result.out.contains(sessionB),
        "第二個來源的 session 必須出現在輸出裡——先前它被字典序挑選丟掉了")
}

@Test("--json --record 時輸出每筆帶 presentation 欄位；不 --record 時不帶")
func jsonOutputExposesPresentationOnlyWhenRecording() throws {
    let workspace = try CLIWorkspace.make(
        texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let recorded = try runCLI(
        ["query", "記憶策略", "--all-projects", "--json", "--record"],
        environment: workspace.environment)
    #expect(recorded.code == 0)
    if recorded.code != 0 { Issue.record("stderr: \(recorded.err)") }
    let recordedObjects =
        try JSONSerialization.jsonObject(with: Data(recorded.out.utf8)) as? [[String: Any]]
    #expect(!(recordedObjects ?? []).isEmpty)
    for object in recordedObjects ?? [] {
        let value = object["presentation"] as? String
        #expect(value?.isEmpty == false, "--record 時每筆物件都應帶非空 presentation 欄位")
    }

    let notRecorded = try runCLI(
        ["query", "記憶策略", "--all-projects", "--json"], environment: workspace.environment)
    #expect(notRecorded.code == 0)
    let notRecordedObjects =
        try JSONSerialization.jsonObject(with: Data(notRecorded.out.utf8)) as? [[String: Any]]
    #expect(!(notRecordedObjects ?? []).isEmpty)
    for object in notRecordedObjects ?? [] {
        #expect(object["presentation"] == nil, "不 --record 時輸出物件不該帶 presentation 欄位")
    }
}

@Test("預設不寫事件；--record 才寫，且每筆命中一則 shown")
func eventRecordingIsOptIn() throws {
    let workspace = try CLIWorkspace.make(
        texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    // 預設：事件檔完全不該出現。
    _ = try runCLI(["query", "內容", "--all-projects"], environment: workspace.environment)
    #expect(
        !FileManager.default.fileExists(atPath: workspace.eventsFile.path),
        "預設查詢不得寫使用歷史——開發與檢查用的查詢會污染策略比較的依據")

    // --record：命中幾筆就寫幾筆。
    let recorded = try runCLI(
        ["query", "內容", "--all-projects", "--record", "--json"],
        environment: workspace.environment)
    #expect(recorded.code == 0)
    if recorded.code != 0 { Issue.record("stderr: \(recorded.err)") }
    let hits = (try JSONSerialization.jsonObject(with: Data(recorded.out.utf8)) as? [[String: Any]])?
        .count ?? 0
    #expect(hits > 0)
    let lines = try String(contentsOf: workspace.eventsFile, encoding: .utf8)
        .split(separator: "\n").filter { !$0.isEmpty }
    #expect(lines.count == hits, "shown 事件數必須等於呈現的命中數")
}

@Test("寫下的事件只含指標與類別，不含語料原文，也不含查詢原文")
func recordedEventsContainNoCorpusText() throws {
    let secret = "這段文字不應該出現在事件檔裡"
    // 查詢用的字串必須**單獨**斷言。先前只斷言完整的 secret，而實際下的查詢是它的
    // 子字串——真的洩漏 query 原文時，斷言的 needle 比洩漏的內容長，抓不到。
    let queryText = "不應該出現"
    let workspace = try CLIWorkspace.make(texts: [secret])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)
    _ = try runCLI(
        ["query", queryText, "--all-projects", "--record"], environment: workspace.environment)

    let raw = try String(contentsOf: workspace.eventsFile, encoding: .utf8)
    #expect(!raw.contains(secret), "事件檔含語料原文 —— 違反記憶層的硬約束")
    #expect(!raw.contains(queryText), "事件檔含查詢原文 —— 同一條硬約束的另一半")
    #expect(raw.contains("shown"))
    // 帶得動的只有 anchor（指標 + 內容雜湊）與類別標籤。
    #expect(raw.contains("contentHash"))
}

@Test("未知選項不被忽略，而是回報並以 usage error 結束")
func unknownOptionIsReported() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容"])
    defer { workspace.cleanup() }

    let result = try runCLI(
        ["query", "內容", "--jsno", "--all-projects"], environment: workspace.environment)

    #expect(result.code == LTMCommandLine.ExitCode.usageError.rawValue)
    #expect(result.err.contains("jsno"), "打錯的旗標必須被指名，否則使用者以為它生效了")
}

@Test("--strategy 不帶 --record 時仍讀得到歷史，且不寫入任何事件")
func strategyReadsHistoryWithoutRecording() throws {
    let workspace = try CLIWorkspace.make(texts: [
        "記憶策略的內容", "檢索量測的內容", "第三段內容", "第四段內容",
    ])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    // 先用 --record 造出歷史，再確認不帶 --record 的查詢讀得到它。
    _ = try runCLI(["query", "內容", "--all-projects", "--record"], environment: workspace.environment)
    #expect(FileManager.default.fileExists(atPath: workspace.eventsFile.path))
    let before = try Data(contentsOf: workspace.eventsFile)

    let result = try runCLI(
        ["query", "內容", "--all-projects", "--strategy", "human-like"],
        environment: workspace.environment)

    #expect(result.code == 0)
    if result.code != 0 { Issue.record("stderr: \(result.err)") }
    #expect(result.out.contains("human-like"), "輸出應報出實際套用的策略")
    // 關鍵：沒帶 --record 就不該寫入任何事件（讀歷史 ≠ 寫歷史）。
    #expect(try Data(contentsOf: workspace.eventsFile) == before,
            "--strategy 不該順帶寫事件；讀與寫是兩件事")
}

@Test("memory root 指進語料時拒絕，且語料下沒有任何目錄被建立")
func memoryRootInsideCorpusIsRefusedBeforeCreation() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)
    let before = try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path).sorted()

    var env = workspace.environment
    env["LTM_MEMORY_ROOT"] = workspace.corpus.path  // 指進正在被掃描的語料
    let result = try runCLI(["query", "內容", "--all-projects", "--record"], environment: env)

    #expect(result.code != 0)
    let after = try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path).sorted()
    #expect(after == before, "語料下多出了東西 —— 守衛跑在 mkdir 之後就等於沒守衛")
}

@Test("derived root 指進被覆寫的語料根時同樣被拒")
func derivedRootInsideOverriddenCorpusIsRefused() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容"])
    defer { workspace.cleanup() }
    var env = workspace.environment
    env["LTM_DERIVED_ROOT"] = workspace.corpus.appendingPathComponent("derived").path
    let before = try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path).sorted()

    let result = try runCLI(["build"], environment: env)

    #expect(result.code != 0, "守衛必須跟著**當下使用中的**語料根走，不是只看預設根")
    let after = try FileManager.default.subpathsOfDirectory(atPath: workspace.corpus.path).sorted()
    #expect(after == before, "語料下多出了索引產物")
}

@Test("--k 負值被拒且不 crash；非數值不靜默改用預設")
func invalidKIsRefused() throws {
    let workspace = try CLIWorkspace.make(texts: ["內容一", "內容二"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let negative = try runCLI(
        ["query", "內容", "--all-projects", "--k", "-1"], environment: workspace.environment)
    #expect(negative.code == LTMCommandLine.ExitCode.usageError.rawValue,
            "負值先前會以 stdlib precondition 中止行程")
    #expect(negative.err.contains("1000"), "訊息要指名接受範圍")

    let nonNumeric = try runCLI(
        ["query", "內容", "--all-projects", "--k", "abc"], environment: workspace.environment)
    #expect(nonNumeric.code == LTMCommandLine.ExitCode.usageError.rawValue)
    #expect(nonNumeric.out.isEmpty, "不得靜默改用預設然後回報成功")
}

@Test("--json 不得有把單一 session 稱作「這個」session 的欄位")
func jsonHasNoPrivilegedSingleSessionField() throws {
    // #25 選項 3：N 份 resume 複製是 N 個等價來源，沒有哪一個是「代表」。
    // 一個名為 `sessionId`（單數、定指）的欄位是對來源的假宣稱——它先前的值
    // 由 source_key 極值決定，而極值會隨新檔案出現而改變（實測見 CHANGELOG）。
    // 真相是集合，所以輸出只留集合。
    let workspace = try CLIWorkspace.makeWithResumeDuplicate(
        shared: "被 resume 複製的共用內容", uniqueToA: "只在一份檔案裡的內容",
        sessionA: "aaaaaaaa-1111-2222-3333-444444444444",
        sessionB: "bbbbbbbb-1111-2222-3333-444444444444")
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let result = try runCLI(
        ["query", "內容", "--all-projects", "--json"], environment: workspace.environment)
    #expect(result.code == 0)
    let objects =
        try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [[String: Any]] ?? []
    #expect(!objects.isEmpty)
    for object in objects {
        #expect(
            object["sessionId"] == nil,
            "不得有單數 sessionId 欄位——它宣稱某一個來源是「這個」來源，而 N 份 resume 複製之間沒有這種特權")
        #expect(object["sessions"] is [Any], "sessions 陣列才是導航資訊的本體")
    }
}

@Test("新的 resume 複製出現時，既有記憶的來源資訊只會增加，不會改變既有的值")
func addingAResumeCopyOnlyGrowsTheSourceSet() throws {
    // 這是 #25 真正的病灶（實測 T0→T1→T2）：先前「挑極值」的做法讓一則**內容
    // 從未改變**的記憶，其指標因為**另一個檔案出現**而改變——那是位置定址，
    // 違反 ltm-analogy 的性質 1。集合只增不改，因為它不挑。
    let sessionM = "mmmmmmmm-1111-2222-3333-444444444444"
    let sessionS = "ssssssss-1111-2222-3333-444444444444"
    let sessionA = "aaaaaaaa-1111-2222-3333-444444444444"
    let shared = "被 resume 複製的共用內容"

    let workspace = try CLIWorkspace.makeWithResumeDuplicate(
        shared: shared, uniqueToA: "只在一份檔案裡的內容",
        sessionA: sessionM, sessionB: sessionS)
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    func sessionsForShared() throws -> Set<String> {
        let out = try runCLI(
            ["query", "內容", "--all-projects", "--json"], environment: workspace.environment).out
        let objects = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]] ?? []
        let hit = objects.first { ($0["snippet"] as? String ?? "").contains("共用") }
        return Set(hit?["sessions"] as? [String] ?? [])
    }

    let before = try sessionsForShared()
    #expect(before == [sessionM, sessionS])

    // 之後才出現一份字典序排在最前面的 resume 複製——先前這會讓回傳的指標
    // 從 m 翻成 a，即使那則記憶本身一個字都沒動。
    let dir = workspace.corpus.appendingPathComponent("proj-demo")
    let line = try #require(
        String(
            data: try JSONSerialization.data(withJSONObject: [
                "type": "user", "uuid": "11111111-aaaa-bbbb-cccc-dddddddddddd",
                "sessionId": sessionA, "timestamp": "2026-08-17T06:00:00.000Z",
                "message": ["role": "user", "content": shared],
            ]), encoding: .utf8))
    try (line + "\n").write(
        to: dir.appendingPathComponent("s-0.jsonl"), atomically: true, encoding: .utf8)
    _ = try runCLI(["build"], environment: workspace.environment)

    let after = try sessionsForShared()
    #expect(after == [sessionM, sessionS, sessionA], "新來源加入集合")
    #expect(before.isSubset(of: after), "既有的來源值一個都不能消失或被取代")
}

// MARK: - 比較模式（--compare）

extension CLIWorkspace {
    var recordsFile: URL { memory.appendingPathComponent("memory/presentations.jsonl") }
}

@Test("--compare 隱含 --record：不帶 --record 也照樣寫事件，兩個一起給行為相同")
func compareImpliesRecord() throws {
    let workspace = try CLIWorkspace.make(
        texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let compared = try runCLI(
        ["query", "內容", "--all-projects", "--compare", "--json"],
        environment: workspace.environment)
    #expect(compared.code == 0)
    if compared.code != 0 { Issue.record("stderr: \(compared.err)") }

    let hits =
        (try JSONSerialization.jsonObject(with: Data(compared.out.utf8)) as? [[String: Any]]) ?? []
    #expect(!hits.isEmpty)
    // 先斷言檔案存在：不存在時下面的讀取會以 NSCocoaError 拋出，那讓「沒寫事件」
    // 這個真正的失敗被包裝成一個看不出原因的錯誤。
    #expect(
        FileManager.default.fileExists(atPath: workspace.eventsFile.path),
        "--compare 必須寫事件檔")
    #expect(
        FileManager.default.fileExists(atPath: workspace.recordsFile.path),
        "--compare 必須寫呈現紀錄檔")
    let events = try String(contentsOf: workspace.eventsFile, encoding: .utf8)
        .split(separator: "\n").filter { !$0.isEmpty }
    #expect(events.count == hits.count, "--compare 不帶 --record 也必須寫事件")
    let records = try String(contentsOf: workspace.recordsFile, encoding: .utf8)
        .split(separator: "\n").filter { !$0.isEmpty }
    #expect(records.count == 1, "一次比較寫一筆呈現紀錄")

    // 兩個一起給 = 只給 --compare。再跑一次應該又各多一筆。
    let both = try runCLI(
        ["query", "內容", "--all-projects", "--compare", "--record", "--json"],
        environment: workspace.environment)
    #expect(both.code == 0)
    let recordsAfter = try String(contentsOf: workspace.recordsFile, encoding: .utf8)
        .split(separator: "\n").filter { !$0.isEmpty }
    #expect(recordsAfter.count == 2)
}

@Test("--compare 與 --strategy 互斥：具名失敗，且在跑任何查詢之前")
func compareAndStrategyConflict() throws {
    let workspace = try CLIWorkspace.make(texts: ["記憶策略可插拔", "檢索基線量測"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let result = try runCLI(
        ["query", "內容", "--all-projects", "--compare", "--strategy", "human-like"],
        environment: workspace.environment)
    #expect(result.code == LTMCommandLine.ExitCode.usageError.rawValue)
    #expect(result.err.contains("--compare"))
    #expect(result.err.contains("--strategy"))
    #expect(result.out.isEmpty, "衝突在查詢之前擋下，不得印出任何結果")
    #expect(
        !FileManager.default.fileExists(atPath: workspace.recordsFile.path),
        "被擋下的呼叫不得寫任何紀錄")
}

@Test("比較模式的人類可讀輸出不透露任何策略名字")
func comparisonOutputRevealsNoAttribution() throws {
    let workspace = try CLIWorkspace.make(
        texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let result = try runCLI(
        ["query", "內容", "--all-projects", "--compare"], environment: workspace.environment)
    #expect(result.code == 0)
    if result.code != 0 { Issue.record("stderr: \(result.err)") }
    #expect(!result.out.isEmpty)
    // 逐位置的歸屬是給計分讀的。看結果的人知道了就會影響他接下來點哪一筆，
    // 而那個點擊正是要拿來計分的東西。
    for name in StrategyRegistry.known {
        #expect(!result.out.contains(name), "輸出不得出現策略名字：\(name)")
    }
    // 紀錄裡當然有——歸屬存在，只是不呈現。
    let records = try String(contentsOf: workspace.recordsFile, encoding: .utf8)
    #expect(records.contains("archival") && records.contains("human-like"))
}

@Test("不帶 --compare 的查詢不寫呈現紀錄，輸出與改動前逐字相同")
func defaultQueryPathIsUnchangedByComparisonMode() throws {
    let workspace = try CLIWorkspace.make(
        texts: ["記憶策略可插拔", "檢索基線量測", "第三段內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    let plain = try runCLI(["query", "內容", "--all-projects"], environment: workspace.environment)
    #expect(plain.code == 0)
    #expect(
        !FileManager.default.fileExists(atPath: workspace.recordsFile.path),
        "預設路徑不得寫呈現紀錄")
    #expect(
        !FileManager.default.fileExists(atPath: workspace.eventsFile.path),
        "預設路徑不得寫事件——這是既有契約，比較模式不得改動它")
    // 既有的 footer 形狀（含策略名）在預設路徑上原封不動。
    #expect(plain.out.contains("— 策略 archival"))
}

@Test("--strategy 帶任意字串是 usage error，不是 crash")
func unknownStrategyNeverTrapsTheProcess() throws {
    let workspace = try CLIWorkspace.make(texts: ["記憶策略可插拔", "檢索基線量測"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    // #33 verify（security lens）：先前這些值會走到 `RankingPolicyID(_:)` 的
    // `preconditionFailure` → SIGTRAP，使用者拿到 exit 133 與 stack trace。
    // 只有「剛好落在 OpaqueIdentifier 字元集內」的錯字（`foo`）才走得到具名錯誤。
    for value in ["中文策略", "human like", "arch/ival", String(repeating: "a", count: 100), "foo"] {
        let result = try runCLI(
            ["query", "內容", "--all-projects", "--strategy", value],
            environment: workspace.environment)
        #expect(
            result.code == LTMCommandLine.ExitCode.usageError.rawValue,
            "--strategy '\(value)' 應該是 usage error（得到 exit \(result.code)）")
        #expect(result.err.contains("未知策略"), "錯誤訊息要指名這是未知策略")
        #expect(!result.err.contains("Fatal error"), "外來輸入不得讓行程 trap")
    }
}

// MARK: - #36 階段 4：測試品質

@Test("未知策略以 usageError（2）結束——釘住實際結束碼，不是斷言一個常數")
func anUnknownStrategyExitsWithUsageError() throws {
    let workspace = try CLIWorkspace.make(texts: ["記憶策略的內容", "檢索量測的內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    // #33 的 blocking 修正把這個情境的結束碼從 4（SIGTRAP 的 133 之後改成的
    // 一般錯誤）改成 2，而該 change 的 AC3 寫著「不帶旗標時 byte-identical」
    // ——字面上與這個改動衝突。改動本身是對的（trap → 具名錯誤），但**沒有任何
    // 東西釘住新值**，於是下一次誰動了錯誤分類就會再改一次而沒人發現。
    //
    // 斷言下在**跑出來的結束碼**上，不是 `ExitCode.usageError.rawValue == 2`
    // ——後者只驗了一個常數的字面值，連「這個錯誤走不走那條分支」都沒碰到。
    let result = try runCLI(
        ["query", "內容", "--all-projects", "--strategy", "no-such-strategy"],
        environment: workspace.environment)

    #expect(result.code == 2, "未知策略是使用錯誤（2），不是內部錯誤")
    #expect(result.err.contains("no-such-strategy"), "訊息要指名打錯的那個字")
    #expect(
        result.err.contains("archival") && result.err.contains("conservative"),
        "要列出可用策略，否則使用者不知道正確拼法")
}

// MARK: - #30：ltm memory 的兩條沒被守住的性質

/// 在事件檔裡塞一行壞資料，內容含一個**可辨識的哨兵字串**。
///
/// 哨兵是這兩條測試的核心：斷言不是「輸出看起來沒問題」，而是**那個字串一個字元都
/// 不得出現在輸出裡**。前者是印象，後者是可證偽的。
private func corruptEventsFile(_ workspace: CLIWorkspace, sentinel: String) throws {
    let dir = workspace.eventsFile.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let existing = (try? Data(contentsOf: workspace.eventsFile)) ?? Data()
    var bytes = existing
    bytes.append(Data("{\"kind\":\"shown\",\"secret\":\"\(sentinel)\",\"trunc\n".utf8))
    try bytes.write(to: workspace.eventsFile)
}

@Test("ltm memory 只印行號與計數，不印任何紀錄內容")
func memoryCommandPrintsLineNumbersNeverContent() throws {
    // 記憶層的硬約束是「不存原文」，而**那擋不住「印出原文」**——`ltm memory` 是
    // 唯一會逐行報出壞紀錄的介面，所以它是那條約束在 CLI 端的延伸。#30 指出它
    // 零覆蓋。
    let workspace = try CLIWorkspace.make(texts: ["記憶策略的內容", "檢索量測的內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)
    _ = try runCLI(["query", "內容", "--all-projects", "--record"], environment: workspace.environment)

    let sentinel = "SENTINEL-DO-NOT-PRINT-c7f3a91e"
    try corruptEventsFile(workspace, sentinel: sentinel)

    let result = try runCLI(["memory"], environment: workspace.environment)

    #expect(result.out.contains("行號"), "壞行必須被報出來——不報等於這個命令沒作用")
    #expect(
        !result.out.contains(sentinel) && !result.err.contains(sentinel),
        "紀錄內容外洩到輸出：『不存原文』擋不住『印出原文』")
}

@Test("整份歷史都讀不回來時，--prune 拒絕並要求 --force")
func pruningEverythingRequiresForce() throws {
    // 這條閘的理由很窄：anchor 定址規則換代之後，換代前寫的每一筆都是舊規則，所以
    // 「全部讀不回來」是**換代情境的預設情況**而不是邊角。使用者是照著一個說「丟掉
    // 讀不回來的那些」的錯誤訊息走到這裡的，而在這個情境下那句話**恰好等於**
    // 「清空整份歷史」。少了這道閘，照著指示走一次就沒了。
    let workspace = try CLIWorkspace.make(texts: ["內容"])
    defer { workspace.cleanup() }
    _ = try runCLI(["build"], environment: workspace.environment)

    // 事件檔**只有**壞行 —— 沒有任何可用紀錄。
    let dir = workspace.eventsFile.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("{\"kind\":\"shown\",\"trunc\n".utf8).write(to: workspace.eventsFile)
    let before = try Data(contentsOf: workspace.eventsFile)

    let refused = try runCLI(["memory", "--prune"], environment: workspace.environment)
    #expect(refused.code != 0, "一筆都不保留的修剪必須拒絕，不能靜默照做")
    #expect(refused.err.contains("--force"), "拒絕訊息要指名補救命令")
    #expect(
        try Data(contentsOf: workspace.eventsFile) == before,
        "被拒絕的路徑不得動到檔案")

    // 帶 --force 才放行。
    let allowed = try runCLI(["memory", "--prune", "--force"], environment: workspace.environment)
    #expect(allowed.code == 0)
    if allowed.code != 0 { Issue.record("stderr: \(allowed.err)") }
}
