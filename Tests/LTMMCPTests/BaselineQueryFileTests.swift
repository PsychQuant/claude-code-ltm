import Foundation
import Testing

/// #63：基準查詢集是一份**資料檔**，它的契約是「不被儀器自己污染」——這條測試釘的是契約
/// 的可機械檢查部分：檔頭寫明三件事、條數夠、不含已退役（已被量測命令污染）的三條、
/// 量測腳本可執行且**輸出裡沒有查詢文字**。
///
/// 三條退役查詢以字面寫在這裡是刻意的：它們已經在語料裡（#63 的 root cause），再多出現
/// 一次不改變什麼；而新查詢**不**出現在任何測試或訊息裡——測試只讀檔、只斷言性質。
private func repoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
}

private let retired = ["tokenizer 討論", "flock inode 鎖", "資格考"]

@Test("baseline-queries.txt：檔頭三件事、≥6 條、不含退役三查詢、無空查詢")
func baselineQueryFileDocumentsItsContractAndRetiresThePollutedTrio() throws {
    let url = repoRoot().appendingPathComponent("scripts/baseline-queries.txt")
    let text = try String(contentsOf: url, encoding: .utf8)
    let header = text.split(separator: "\n").filter { $0.hasPrefix("#") }.joined(separator: "\n")
    for phrase in ["列舉", "會漏", "不得在 Claude Code session 內顯示", "只印編號"] {
        #expect(header.contains(phrase), Comment(rawValue: "檔頭缺：\(phrase)"))
    }
    let queries = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    #expect(queries.count >= 6, "基準查詢至少 6 條，得 \(queries.count)")
    #expect(Set(queries).count == queries.count, "查詢重複")
    for q in queries {
        for r in retired {
            #expect(!q.contains(r), Comment(rawValue: "退役查詢不得回到基準集：\(r)"))
        }
    }
}

@Test("measure-baseline.sh：可執行，stdout 只有 `#N <ms> clean|dirty|error(rc)`，不含查詢文字；dirty 判準會動")
func measureBaselinePrintsOnlyIndicesAndVerdicts() throws {
    let root = repoRoot()
    let script = root.appendingPathComponent("scripts/measure-baseline.sh")
    let attrs = try FileManager.default.attributesOfItem(atPath: script.path)
    #expect(((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0, "腳本沒有執行位元")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-baseline-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // 兩條合成查詢（不碰真檔——真檔的內容不得進任何輸出）：第 1 條乾淨、第 2 條回一個工具殘影。
    let queries = dir.appendingPathComponent("q.txt")
    try "# header\nZQXJ-CLEAN-ONE\nZQXJ-DIRTY-TWO\n".write(to: queries, atomically: true, encoding: .utf8)
    let stub = dir.appendingPathComponent("ltm")
    try """
    #!/bin/bash
    q="${@: -1}"
    if [ "$q" = "ZQXJ-DIRTY-TWO" ]; then
      printf '[{"snippet":"⟨tool Bash command=for q in x⟩","uuid":"u"}]\\n'
    else
      printf '[{"snippet":"一段實質內容","uuid":"u"}]\\n'
    fi
    """.write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

    let process = Process()
    process.executableURL = script
    process.arguments = ["3"]
    var env = ProcessInfo.processInfo.environment
    env["LTM_BIN"] = stub.path
    env["LTM_BASELINE_QUERIES"] = queries.path
    process.environment = env
    let out = Pipe(), err = Pipe()
    process.standardOutput = out; process.standardError = err
    try process.run(); process.waitUntilExit()
    let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0, Comment(rawValue: "rc=\(process.terminationStatus) err=\(stderr)"))
    let lines = stdout.split(separator: "\n").map(String.init)
    #expect(lines.count == 2, Comment(rawValue: stdout))
    #expect(lines.allSatisfy { $0.range(of: #"^#[0-9]+ [0-9]+ms (clean|dirty|error\([0-9]+\))$"#, options: .regularExpression) != nil }, Comment(rawValue: stdout))
    #expect(lines.first?.hasSuffix("clean") == true && lines.last?.hasSuffix("dirty") == true, Comment(rawValue: stdout))
    // 查詢文字與 snippet 都不得出現在任何輸出。
    #expect(!(stdout + stderr).contains("ZQXJ") && !(stdout + stderr).contains("實質內容"))
}
