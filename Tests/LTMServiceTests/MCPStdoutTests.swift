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

    // 送 initialize 讓 server 產生一則回應，然後**關掉 stdout 的讀端**——下一次
    // write 就是 EPIPE。
    stdin.fileHandleForWriting.write(
        Data((#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"# + "\n").utf8))
    _ = try? stdout.fileHandleForReading.read(upToCount: 1)  // 等第一則回應開始
    try stdout.fileHandleForReading.close()
    stdin.fileHandleForWriting.write(
        Data((#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"# + "\n").utf8))
    try? stdin.fileHandleForWriting.close()

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
