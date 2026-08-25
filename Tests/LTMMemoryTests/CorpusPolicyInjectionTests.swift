import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

// #27：`FileEventStore` 的語料圍籬先前只認**固定預設根**，而語料根是可覆寫的
// （`LTM_CORPUS_ROOT`）。於是不經 facade 直接用 `LTMMemory`、且語料根被指到別處
// 時，守衛檢查的是錯的樹——實際語料底下的路徑會被放行。
//
// **放行的方向正是危險的那一邊**：不變式 1 說語料唯讀，任何寫入路徑都是 bug。
//
// 這兩條測試都在合成樹上跑，不碰真實 `~/.claude/projects`。那本身是 #27 想買到
// 的東西之一：先前守衛測試只能以真實語料為標的，而一條依賴真實樹當下內容的
// 斷言會退化成恆真。

@Test("語料根被覆寫時，圍籬認得那個根——事件檔不得建在它底下")
func injectedPolicyRejectsAPathInsideTheConfiguredCorpus() throws {
    let sandbox = try TemporaryTree()
    defer { sandbox.cleanup() }

    let corpusRoot = try sandbox.directory("corpus")
    let insideCorpus = corpusRoot.appendingPathComponent("some-project/events.jsonl")

    // 預設圍籬只認 `~/.claude/projects`，所以它對這條路徑**沒有意見**——
    // 這正是 #27 的病灶，也是為什麼預設值只是下界而不是保護。
    #expect(CorpusPolicy().isInsideReadOnlyCorpus(insideCorpus) == false)

    // 收到實際語料根的圍籬必須擋下來。
    let policy = CorpusPolicy(corpusRoots: [corpusRoot])
    #expect(policy.isInsideReadOnlyCorpus(insideCorpus))

    #expect(throws: EventStoreError.self) {
        _ = try FileEventStore(url: insideCorpus, policy: policy)
    }
}

@Test("覆寫語料根不會放寬預設根——兩個根都檢查")
func injectedPolicyStillEnforcesTheDefaultRoot() throws {
    let sandbox = try TemporaryTree()
    defer { sandbox.cleanup() }

    // 額外根與預設根無關。預設根底下的路徑仍然必須被擋——**額外根是加上去的，
    // 不是取代**。先前 facade 的那份實作是對的，錯的是 library 層沒有跟上；
    // 收斂成一份之後，這條性質對兩邊同時成立。
    let policy = CorpusPolicy(corpusRoots: [try sandbox.directory("elsewhere")])
    let insideDefault = CorpusLocation.readOnlyRoot.appendingPathComponent("p/events.jsonl")

    #expect(policy.isInsideReadOnlyCorpus(insideDefault))
}

// MARK: - 合成樹

private struct TemporaryTree {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ltm-corpus-policy-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
