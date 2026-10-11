import Foundation
import Testing

@testable import LTMMCP
import LTMIndex
import LTMService
import LTMCore

/// #71：MCP `ltm_query` 的查詢前併入有上限，沒併完要說出來。
///
/// 這組測試走工具本身（`RetrievalTool.make(...).run`），不只走 `render`：根因是工具呼叫 `service.query`
/// 時沒有傳上限，只測 render 的話，拿掉那個引數全套照樣綠。

/// 確定性的 stub embedder（FNV-1a；不用 `hashValue`——它每個 process 隨機種子化）。
private struct StubEmbedder: EmbeddingProvider {
    let revision = "stub-rev"
    let dimension = 4
    func vector(for text: String) throws -> [Float]? {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        let raw = (0..<4).map { Float((hash >> (UInt64($0) * 16)) & 0xffff) / 65_535 + 0.01 }
        let norm = raw.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return raw.map { $0 / norm }
    }
}

private struct AllowAll: CorpusContainmentPolicy {
    func isInsideReadOnlyCorpus(_ url: URL) -> Bool { false }
}

/// 每讀一次就前進 `step` 秒的時鐘。
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 1_760_000_000)
    private let step: TimeInterval
    init(step: TimeInterval) { self.step = step }
    func tick() -> Date {
        lock.lock()
        defer { lock.unlock() }
        now = now.addingTimeInterval(step)
        return now
    }
}

private struct Fixture {
    let base: URL
    let corpus: URL
    let derived: DerivedLocation

    static func make() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ltm-mcp-bound-\(UUID().uuidString)")
        let corpus = base.appendingPathComponent("corpus")
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        return Fixture(
            base: base, corpus: corpus,
            derived: try DerivedLocation(root: base.appendingPathComponent("derived"), policy: AllowAll()))
    }

    func write(file: String, first: Int, texts: [String]) throws {
        let dir = corpus.appendingPathComponent("proj-one")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = texts.enumerated().map { offset, text -> String in
            let object: [String: Any] = [
                "type": "user",
                "uuid": String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", first + offset),
                "sessionId": "11111111-2222-3333-4444-555555555555",
                "timestamp": "2026-08-17T06:00:00.000Z",
                "message": ["role": "user", "content": text],
            ]
            return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    func service(clock: SteppingClock? = nil) -> @Sendable () throws -> LTMService {
        let derived = derived, corpus = corpus
        let now: @Sendable () -> Date
        if let clock { now = { clock.tick() } } else { now = { Date() } }
        return {
            LTMService(
                location: derived, corpusRoot: corpus, embedder: StubEmbedder(), anchorKey: .forTesting,
                buildTuning: BuildTuning(), clock: now)
        }
    }

    /// 建好初始索引，再在語料裡加一批還沒併入的來源。
    func withBacklog() throws -> Fixture {
        try write(file: "s0.jsonl", first: 0, texts: ["第一段 記憶", "第二段 記憶", "第三段 記憶"])
        try service()().build()
        for index in 1...4 {
            try write(file: "s\(index).jsonl", first: index * 10, texts: ["新來源 \(index) 記憶", "新來源 \(index) 續 記憶"])
        }
        return self
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private func queryArguments() -> [String: Any] { ["query": "記憶", "all_projects": true] }

@Test("MCP 工具帶上限：大 backlog 在批次邊界停下、回應帶落後行（#71）")
func theToolBoundsItsPreQueryMerge() throws {
    let fixture = try Fixture.make().withBacklog()
    defer { fixture.cleanup() }
    // 步進時鐘每讀一次前進 1 秒、上限 1 秒：第一個批次邊界就已經過了期限。
    let tool = RetrievalTool.make(service: fixture.service(clock: SteppingClock(step: 1)), refreshBudget: 1)
    let text = try tool.run(queryArguments())
    let lagLine = try #require(
        text.split(separator: "\n").first { $0.contains("索引落後") }, "回應要帶落後行，實得：\(text)")
    let count = try #require(
        lagLine.firstMatch(of: /索引落後 (\d+) 個來源/).flatMap { Int($0.1) }, "落後行要帶來源數：\(lagLine)")
    #expect(count > 0)
}

@Test("MCP 工具的上限夠大時：沒有落後行，回應與不設上限的查詢相同（#71）")
func aRoomyBoundChangesNothing() throws {
    let roomy = try Fixture.make().withBacklog()
    defer { roomy.cleanup() }
    let reference = try Fixture.make().withBacklog()
    defer { reference.cleanup() }
    let bounded = try RetrievalTool.make(
        service: roomy.service(clock: SteppingClock(step: 1)), refreshBudget: 3_600
    ).run(queryArguments())
    let unbounded = RetrievalTool.render(
        try reference.service()().query(text: "記憶", limit: 10, scope: .allProjects))
    #expect(!bounded.contains("索引落後"), "實得：\(bounded)")
    #expect(bounded == unbounded)
}
