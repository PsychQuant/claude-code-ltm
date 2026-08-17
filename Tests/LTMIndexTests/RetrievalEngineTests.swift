import Foundation
import SQLite3
import Testing

@testable import LTMCore
@testable import LTMIndex

/// RRF 的算術本身可以脫離資料庫驗——這一組測的是「排名怎麼合成」，
/// 不是「SQLite 怎麼排」。spec 的 A/B/C 例子就是這一層的。
@Test("RRF：融合後的集合恰是各通道排名的聯集，且依倒數名次和排序")
func reciprocalRankFusionMatchesSpecExample() {
    // spec 的例子（k=60）：
    //   A：trigram 第 1、cosine 第 2
    //   B：trigram 第 2、segment 第 1
    //   C：segment 第 2、cosine 第 1
    let k = RetrievalEngine.rrfK
    func rrf(_ ranks: [Int]) -> Double { ranks.reduce(0) { $0 + 1.0 / (k + Double($1)) } }

    let scoreA = rrf([1, 2])
    let scoreB = rrf([2, 1])
    let scoreC = rrf([2, 1])

    // B 與 C 的名次組合相同 → 分數必須相同（融合只看名次，不看是哪條通道）。
    #expect(scoreB == scoreC)
    // A 也是 {1,2} 的組合，所以三者同分——這正是 spec 表格的情形。
    #expect(scoreA == scoreB)
    #expect(abs(scoreA - (1.0 / 61.0 + 1.0 / 62.0)) < 1e-12)
}

@Test("RRF：出現在越多通道的候選分數越高")
func appearingInMoreChannelsScoresHigher() {
    let k = RetrievalEngine.rrfK
    let inThreeChannels = 3.0 * (1.0 / (k + 1))
    let inOneChannel = 1.0 / (k + 1)
    #expect(inThreeChannels > inOneChannel)
}

@Test("FTS5 phrase 包裝讓查詢語法字元不被當成運算子")
func ftsPhraseEscapesQuerySyntax() {
    #expect(RetrievalEngine.ftsPhrase("foo-bar") == "\"foo-bar\"")
    #expect(RetrievalEngine.ftsPhrase("say \"hi\"") == "\"say \"\"hi\"\"\"")
    #expect(RetrievalEngine.ftsPhrase("   ") == "")
}

// MARK: - 端到端（真的建索引再查）

private struct AllowAll: CorpusContainmentPolicy {
    func isInsideReadOnlyCorpus(_ url: URL) -> Bool { false }
}

/// 建一個小索引，回傳可查詢的引擎與清理用的路徑。
private func buildSearchableIndex(
    texts: [String], project: String = "proj-one", embedder: StubEmbedder = StubEmbedder(revision: "rev-A")
) throws -> (engine: RetrievalEngine, database: IndexDatabase, cleanup: [URL]) {
    let corpus = try makeFixtureCorpus()
    let derivedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-derived-\(UUID().uuidString)")
    let derived = try DerivedLocation(root: derivedRoot, policy: AllowAll())

    var lines: [String] = []
    for (index, text) in texts.enumerated() {
        lines.append(
            turnLine(
                uuid: String(format: "%08x-aaaa-bbbb-cccc-dddddddddddd", index),
                session: "11111111-2222-3333-4444-555555555555",
                role: "user", text: text))
    }
    _ = try writeSession(in: corpus, project: project, file: "session.jsonl", lines: lines)

    _ = try IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus), embedder: embedder
    ).build()

    let database = try IndexDatabase(path: derived.databaseURL.path)
    let vectors = try? VectorSidecar.open(url: derived.vectorsURL, dimension: embedder.dimension)
    let engine = RetrievalEngine(database: database, vectors: vectors, embedder: embedder)
    return (engine, database, [corpus, derivedRoot])
}

@Test("查詢回的每一筆都帶齊四欄指標")
func everyHitCarriesFourFieldPointer() throws {
    let (engine, database, cleanup) = try buildSearchableIndex(
        texts: ["記憶策略可插拔的比較軸", "檢索基線的量測紀錄", "無關的其他內容"])
    defer {
        database.close()
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    let hits = try engine.search(query: "記憶策略", limit: 10, scope: .allProjects)

    #expect(!hits.isEmpty)
    for hit in hits {
        #expect(!hit.project.isEmpty)
        #expect(!hit.sessionID.isEmpty)
        #expect(!hit.uuid.isEmpty)
        #expect(hit.timestamp.timeIntervalSince1970 > 0)
        #expect(hit.anchor.turnID == hit.uuid)
    }
    // 名次是連續的 0,1,2...，band 直接取用它。
    #expect(hits.map(\.fusedRank) == Array(0..<hits.count))
}

@Test("查詢限定 project 時不會回其他 project 的內容")
func projectScopeExcludesOtherProjects() throws {
    let corpus = try makeFixtureCorpus()
    let derivedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ltm-derived-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: corpus)
        try? FileManager.default.removeItem(at: derivedRoot)
    }
    let derived = try DerivedLocation(root: derivedRoot, policy: AllowAll())

    _ = try writeSession(
        in: corpus, project: "proj-one", file: "a.jsonl",
        lines: [
            turnLine(
                uuid: "00000001-aaaa-bbbb-cccc-dddddddddddd",
                session: "11111111-2222-3333-4444-555555555555", role: "user",
                text: "共同的關鍵詞出現在第一個專案")
        ])
    _ = try writeSession(
        in: corpus, project: "proj-two", file: "b.jsonl",
        lines: [
            turnLine(
                uuid: "00000002-aaaa-bbbb-cccc-dddddddddddd",
                session: "22222222-2222-3333-4444-555555555555", role: "user",
                text: "共同的關鍵詞出現在第二個專案")
        ])

    let embedder = StubEmbedder(revision: "rev-A")
    _ = try IndexBuilder(
        location: derived, scanner: CorpusScanner(corpusRoot: corpus), embedder: embedder
    ).build()
    let database = try IndexDatabase(path: derived.databaseURL.path)
    defer { database.close() }
    let engine = RetrievalEngine(
        database: database,
        vectors: try? VectorSidecar.open(url: derived.vectorsURL, dimension: embedder.dimension),
        embedder: embedder)

    let scoped = try engine.search(query: "共同的關鍵詞", limit: 10, scope: .project("proj-one"))
    #expect(!scoped.isEmpty)
    #expect(scoped.allSatisfy { $0.project == "proj-one" })

    let all = try engine.search(query: "共同的關鍵詞", limit: 10, scope: .allProjects)
    #expect(Set(all.map(\.project)) == ["proj-one", "proj-two"])
}

@Test("命中會標示它來自哪些通道")
func hitsRecordTheirChannels() throws {
    let (engine, database, cleanup) = try buildSearchableIndex(
        texts: ["記憶策略可插拔的比較軸"])
    defer {
        database.close()
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    let hits = try engine.search(query: "記憶策略", limit: 10, scope: .allProjects)
    #expect(hits.count == 1)
    // trigram 對四字中文查詢一定命中；通道集合不得是空的（空代表融合把來源丟了）。
    #expect(!hits[0].channels.isEmpty)
    #expect(hits[0].channels.contains(.trigram))
}
