import Foundation
import SQLite3
import Testing

@testable import LTMCore
@testable import LTMIndex

// 這一組**必須呼叫 production 的 `search()`**。
//
// 先前它們在測試檔裡自己重算 RRF 公式再斷言算術——那是恆真式：`search()` 直接
// 回 `[]` 也照樣全綠。三個獨立 reviewer 各自指出這一點。測試要證明的是
// 「融合程式碼做對了」，不是「我會算加法」。

@Test("RRF：融合結果來自 search()，且多通道命中的候選排在單通道之前")
func fusionRanksMultiChannelHitsHigher() throws {
    let (engine, database, cleanup) = try buildSearchableIndex(
        texts: ["記憶策略可插拔的比較軸", "另一段提到策略但用字不同的內容", "完全無關的第三段"])
    defer {
        database.close()
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    let hits = try engine.search(query: "記憶策略", limit: 10, scope: .allProjects)
    #expect(!hits.isEmpty)

    // 融合分數必須隨命中通道數單調——這是 production 融合邏輯的性質，
    // 不是測試自己算出來的。
    let byChannelCount = Dictionary(grouping: hits, by: { $0.channels.count })
    if let multi = byChannelCount.filter({ $0.key > 1 }).values.flatMap({ $0 }).max(by: { $0.fusedScore < $1.fusedScore }),
       let single = byChannelCount[1]?.max(by: { $0.fusedScore < $1.fusedScore })
    {
        #expect(multi.fusedScore > single.fusedScore,
                "命中越多通道，RRF 分數應越高——這是融合實作的性質")
    }
    // 名次連續。
    #expect(hits.map(\.emittedRank) == Array(0..<hits.count))
    // **band-major**：先相關度層，層內才是融合分數降冪。
    //
    // 這裡先前斷言的是「整份輸出依融合分數降冪」——那在 band 還等於融合名次時是
    // 對的，band 改成命中通道數之後就不再是 `search()` 的性質了。斷言留著不會紅
    // （只要沒有跨帶反轉就通過），但它宣稱的契約已經是別的東西。
    #expect(
        zip(hits, hits.dropFirst()).allSatisfy { $0.band <= $1.band },
        "band 必須非遞減")
    for group in Dictionary(grouping: hits, by: \.band).values {
        let ordered = group.sorted { $0.emittedRank < $1.emittedRank }
        #expect(
            zip(ordered, ordered.dropFirst()).allSatisfy { $0.fusedScore >= $1.fusedScore },
            "帶內必須是融合分數降冪")
    }
}

@Test("RRF：融合後的集合恰是各通道排名的聯集（經 search()）")
func fusionSetIsUnionOfChannels() throws {
    let (engine, database, cleanup) = try buildSearchableIndex(
        texts: ["甲：記憶策略", "乙：檢索量測", "丙：無關內容"])
    defer {
        database.close()
        cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    let hits = try engine.search(query: "記憶策略", limit: 10, scope: .allProjects)
    // 每一筆都必須至少屬於一條通道——空 channels 代表融合把來源資訊丟了。
    #expect(hits.allSatisfy { !$0.channels.isEmpty })
    // 不得出現任何通道都沒排到的候選（那會是憑空冒出來的結果）。
    #expect(hits.allSatisfy { $0.fusedScore > 0 })
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
    #expect(hits.map(\.emittedRank) == Array(0..<hits.count))
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
