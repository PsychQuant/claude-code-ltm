import Foundation
import Testing

/// #50：MCP stdout 關閉時具名結束，不 SIGABRT。
///
/// batch verify 四個 lens 都把這個機制標成「沒有測試扛」，並援引「驅動不了的
/// 機制要刪掉」——**DA 用 pipe harness 證偽了那個處方**：機制可以驅動（HEAD
/// exit 3 + 具名訊息；legacy 形式 SIGABRT −6），只是沒人寫。規則的前件是
/// **cannot** be driven，不是 is not driven——兩者在這裡分岔。這條就是那個 driver。
@Test("MCP stdout 被關掉時具名結束而不是 SIGABRT")
func mcpExitsNamedWhenStdoutCloses() throws {
    let binary = try ltmExecutableForMCP()
    let corpus = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-mcp-epipe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: corpus) }
    try FileManager.default.createDirectory(
        at: corpus.appendingPathComponent("corpus/proj-a"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: corpus.appendingPathComponent("derived"), withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = binary
    process.arguments = ["mcp"]
    var environment = ProcessInfo.processInfo.environment
    environment["LTM_CORPUS_ROOT"] = corpus.appendingPathComponent("corpus").path
    environment["LTM_DERIVED_ROOT"] = corpus.appendingPathComponent("derived").path
    environment["LTM_ANCHOR_KEY"] = String(repeating: "ab", count: 32)
    process.environment = environment

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    // **測試 host 的 SIGPIPE 是 SIG_DFL**（三方各自實測 `sigaction` raw=0，#57
    // verify）。server 退出後對它 stdin 的任何 write 會發 SIGPIPE 殺掉整個
    // 測試行程——`try?` 擋不住訊號（第一版就是這樣：負載下 5/270 整輪靜默死，
    // exit 141）。`F_SETNOSIGPIPE` 把這個 fd 的失敗轉成可接的 EPIPE。
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

    // 送 initialize 讓 server 產生一則回應，然後關掉**本測試持有的** stdout
    // 讀端——當 pipe 已沒有任何其他讀者時，server 之後的 write 才是 EPIPE
    // （這兩件事不同：本地 `close()` 返回 ≠ kernel 端讀者計數歸零，見下）。
    try stdin.fileHandleForWriting.write(
        contentsOf: Data((#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n").utf8))
    _ = try? stdout.fileHandleForReading.read(upToCount: 1)  // 等第一則回應開始
    try stdout.fileHandleForReading.close()

    // **持續送請求直到 server 退出，不是只送一則**（#57）。
    //
    // 只送一則時全套件約 1–3% 紅（filtered 單跑 0/40）。server 端追蹤實測：
    // 那一則的回應**寫成功**、接著正常 EOF、exit 0——寫入嚴格晚於本地 close
    // 卻成功，所以那一瞬 pipe 的讀端仍被某個東西持有；連送 5 則時 6 次寫入全部
    // 成功，持有者活了 ≥4.5 ms（這是**下界**，上界未知）。**持有者是誰，沒有
    // 查出來。** 逐一探測而未獲支持的候選：外部行程繼承（CLOEXEC 後同率）、
    // fork（atfork 零觸發）、Foundation read／close 路徑（raw read 同率；探針
    // 600 輪零）、dispatch 讀源（repo 零命中）、XNU spawn fd 表複製窗口（風暴
    // 10 萬次 spawn 含大映像，零）、並發 `readDataToEndOfFile`（3,744 輪零）。
    // 零命中支持的是「在該探針設定下未重現」，不是邏輯上的排除。verify DA 另提
    // 第八候選（本行程以別的 fd 號持有）：30 次全套零別名但無 flake 取樣，未決。
    // 數字與命令在 `docs/measurements/2026-09-02-mcp-epipe-flake.md`。
    //
    // 測試因此改成不依賴機制的形狀：斷言**stdout 一旦沒有讀者，server 就具名
    // 退出**——每 5 ms 送一則、最多 2 s。2 s 是經驗上限（同 suite 200 次全綠），
    // 不是由已知機制導出的安全界線。補寫用 `try?`：server 退出後的 EPIPE 是
    // 預期（上面已把 SIGPIPE 轉成 EPIPE，否則 `try?` 什麼都擋不住）。
    let deadline = Date().addingTimeInterval(2)
    var requestID = 2
    while process.isRunning && Date() < deadline {
        try? stdin.fileHandleForWriting.write(
            contentsOf: Data(
                (#"{"jsonrpc":"2.0","id":"# + "\(requestID)" + #","method":"tools/list"}"# + "\n").utf8))
        requestID += 1
        usleep(5_000)
    }
    try? stdin.fileHandleForWriting.close()

    // **有界等待，deadline 到就親手結束子行程。** 若持有者不排水且活得夠久，
    // stdout pipe（65,504 B）在約 98 則回應後填滿、server 卡在 `write(2)`、不再
    // 讀 stdin、永遠看不到 EOF——`waitUntilExit()` 會無限等（verify 用 dup()
    // 探針重現：stdin 關後 10 s 仍活）。**不用 `.timeLimit`**：它對卡在 C call
    // 的同步 body 只記 issue、不解除阻塞（DA 實測 60 s 記錄後 body 跑滿 150 s；
    // repo 內三條既有測試的同一宣稱另開 issue 追）。
    let hardDeadline = Date().addingTimeInterval(10)
    while process.isRunning && Date() < hardDeadline { usleep(10_000) }
    if process.isRunning {
        process.terminate()
        usleep(200_000)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    let err = String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    // SIGABRT 是 legacy 形式的死法（uncatchable ObjC exception）。
    #expect(process.terminationReason == .exit, "必須是正常 exit，不是訊號；stderr：\(err)")
    #expect(process.terminationStatus == 3, "具名結束碼，實得 \(process.terminationStatus)")
    #expect(err.contains("MCP server 結束"), "stderr 要有具名訊息，實得：\(err)")
}

/// #50 的第二個建議：**會變紅的檢查**，擋住第七個 legacy 站點。
///
/// 界定用**謂詞**不用目錄（DA 抓到：`scripts/measure-retrieval` 也有一個 legacy
/// write，但那個 target 沒裝 `SIG_IGN`，行程死於 SIGPIPE（−13）而到不了 ObjC
/// exception——把它改成 contentsOf 修不了任何東西。這條檢查的射程因此是：
/// **與 `signal(SIGPIPE, SIG_IGN)` 同一個行程的 code**，即 `Sources/` 底下全部
/// 模組（它們都連進 `ltm` 執行檔，SIG_IGN 在 `Sources/ltm/main.swift`）。
@Test("Sources/ 不得再出現 legacy 的 FileHandle.standard*.write(_:)")
func noLegacyStandardStreamWritesInSources() throws {
    var offenders: [String] = []
    let root = try repositoryRootForMCP()
    let sources = root.appendingPathComponent("Sources")
    let walker = try #require(
        FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
    for case let url as URL in walker {
        guard url.pathExtension == "swift" else { continue }
        let lines = (try String(contentsOf: url, encoding: .utf8))
            .components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//") else { continue }
            guard line.contains("FileHandle.standard") else { continue }
            // legacy 形式是 `.write(` 而引數**不是** `contentsOf:`。跨行呼叫時
            // `contentsOf:` 在下一行——把下一行接起來看。
            guard let range = line.range(of: ".write(") else { continue }
            let after = String(line[range.upperBound...])
                + (index + 1 < lines.count ? lines[index + 1] : "")
            if !after.trimmingCharacters(in: .whitespaces).hasPrefix("contentsOf") {
                offenders.append("\(url.lastPathComponent):\(index + 1) \(line.prefix(70))")
            }
        }
    }
    #expect(
        offenders.isEmpty,
        """
        legacy 的 FileHandle.standard*.write(_:) 在 EPIPE 時丟 ObjC exception，\
        Swift 接不住，行程 SIGABRT（#50）。改用 try? …write(contentsOf:)：
        \(offenders.joined(separator: "\n"))
        """)
}

private func ltmExecutableForMCP(file: StaticString = #filePath) throws -> URL {
    // 與 CLICommandTests 的 ltmExecutable 同一個推導：repo root 下的 .build。
    let root = try repositoryRootForMCP(file: file)
    for configuration in ["debug", "release"] {
        let candidate = root.appendingPathComponent(".build/\(configuration)/ltm")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    struct BinaryNotBuilt: Error {}
    throw BinaryNotBuilt()
}

private func repositoryRootForMCP(file: StaticString = #filePath) throws -> URL {
    var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Package.swift").path)
        {
            return directory
        }
        directory = directory.deletingLastPathComponent()
    }
    struct RootNotFound: Error {}
    throw RootNotFound()
}
