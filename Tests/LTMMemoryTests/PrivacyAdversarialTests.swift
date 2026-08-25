import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

// #1 verify 2026-08-11（devils-advocate + codex）：原本的隱私測試只證明了
// 「我挑的那幾個 fixture 字串沒出現在輸出裡」，那跟「沒有原文」是兩回事。
// DA 用公開 API 把整段語料原文寫進 canonical 檔並通過了既有測試。
//
// 這一檔改成**對抗式**：逐一嘗試把自由文字塞進每一個可序列化的識別碼欄位，
// 斷言建構或解碼失敗。測試的形狀從「搜尋輸出」換成「攻擊輸入」。

private let 原文 = "這是一段不該進入 canonical 層的第三方逐字內容"

@Test func identifierValidatorRejectsFreeText() {
    #expect(throws: OpaqueIdentifier.ValidationError.self) {
        try OpaqueIdentifier.validate(原文)
    }
    #expect(throws: OpaqueIdentifier.ValidationError.empty) {
        try OpaqueIdentifier.validate("")
    }
    #expect(throws: OpaqueIdentifier.ValidationError.self) {
        try OpaqueIdentifier.validate(String(repeating: "a", count: 65))
    }
    #expect(throws: OpaqueIdentifier.ValidationError.self) {
        try OpaqueIdentifier.validate("has space")
    }
    // 合法的識別碼形狀仍然通過。
    #expect(throws: Never.self) { try OpaqueIdentifier.validate("build-2026-08-11") }
    #expect(throws: Never.self) { try OpaqueIdentifier.validate("human-like") }
}

@Test func generationAndPolicyIdentifiersRejectFreeTextFromForeignData() {
    #expect(throws: OpaqueIdentifier.ValidationError.self) {
        _ = try GenerationID(validating: 原文)
    }
    #expect(throws: OpaqueIdentifier.ValidationError.self) {
        _ = try RankingPolicyID(validating: 原文)
    }
}

/// 形狀合法的雜湊。用它當基準，才能讓「解碼失敗」歸因到我要測的那個欄位，
/// 而不是被別的欄位形狀先擋下來。
///
/// #1 verify R2（devils-advocate）指出：先前這幾條測試用 `"hex":"00"`，於是
/// 它們 throw 的原因其實是雜湊形狀不合法，**與它們宣稱要驗的自由文字無關**。
/// 測試名字比證據強，第二次犯同一類錯。
private let 合法雜湊 = String(repeating: "ab", count: 32)

@Test func decodingAnEventWhoseIdentifiersCarryFreeTextFails() {
    // 外來寫入者（或被竄改的備份）把原文塞進識別碼欄位。必須在解碼邊界被擋下，
    // 而不是原樣讀回來繼續流通。
    func hostile(generation: String) -> Data {
        Data("""
            {"kind":"opened","anchor":{"source":"s","turnID":"t1",
            "contentHash":{"hex":"\(合法雜湊)"},"span":[0,1]},
            "timestamp":0,"generation":"\(generation)","policy":"archival"}
            """.utf8)
    }

    // 先確認基準可解——否則下面的 throw 可能只是形狀問題。
    #expect(throws: Never.self) { _ = try JSONDecoder().decode(Event.self, from: hostile(generation: "build-1")) }
    // 只換掉 generation，其餘完全相同 → 失敗必然歸因於它。
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Event.self, from: hostile(generation: 原文)) }
}

@Test func decodingAnAnchorWhoseSourceCarriesFreeTextFails() {
    func hostile(source: String) -> Data {
        Data("""
            {"source":"\(source)","turnID":"t1",
            "contentHash":{"hex":"\(合法雜湊)"},"span":[0,1]}
            """.utf8)
    }

    #expect(throws: Never.self) { _ = try JSONDecoder().decode(Anchor.self, from: hostile(source: "fixture-a")) }
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Anchor.self, from: hostile(source: 原文)) }
}

@Test func contentHashRejectsFreeTextAtBothConstructionAndDecoding() {
    // R1 的加固逐一列舉了六個識別碼型別，**漏了這一個**——而它在每一筆 Event 裡。
    #expect(throws: ContentHash.ValidationError.self) { try ContentHash.validate(原文) }
    #expect(throws: ContentHash.ValidationError.wrongLength(2)) { try ContentHash.validate("00") }
    #expect(throws: ContentHash.ValidationError.self) { try ContentHash.validate(合法雜湊.uppercased()) }
    #expect(throws: Never.self) { try ContentHash.validate(合法雜湊) }

    // 解碼邊界同樣要擋——先前 Anchor.init(from:) 驗了 source/turnID 卻直接 decode 雜湊。
    let hostile = Data("""
        {"source":"s","turnID":"t1","contentHash":{"hex":"\(原文)"},
        "span":[0,1]}
        """.utf8)
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Anchor.self, from: hostile) }
}

@Test func anEmptySpanCannotBeDecodedBecauseItBindsToNothing() {
    // #1 verify R3：`span: [3,3]` 的 anchor 雜湊是 `sha256("")`，於是它對**任何**
    // 一段第三方文字都 resolve 成功——`memory-events` spec 的「Altered source
    // text dereferences as orphaned」對空 span 完全不成立。一筆這樣的紀錄等於
    // 一個萬用 anchor。
    //
    // span 是會被原樣序列化的欄位，所以它跟識別碼一樣需要形狀約束。R3 指出
    // 我把「每個被原樣序列化的欄位」這個判準縮成了「字串欄位」，缺口正好落在
    // 縮掉的地方。
    func anchorJSON(span: String) -> Data {
        Data("""
            {"source":"s","turnID":"t1","contentHash":{"hex":"\(合法雜湊)"},"span":\(span)}
            """.utf8)
    }

    #expect(throws: Never.self) { _ = try JSONDecoder().decode(Anchor.self, from: anchorJSON(span: "[0,1]")) }
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Anchor.self, from: anchorJSON(span: "[3,3]")) }
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Anchor.self, from: anchorJSON(span: "[-2,1]")) }
}

@Test func aRecordCarryingAnUndeclaredFieldIsRejected() {
    // #1 verify R4：Swift 的 `JSONDecoder` **預設忽略未知欄位**。所以一行只要
    // 帶齊合法欄位、再多掛一個 `"query": "第三方未發表原文"`，就會解碼成功、
    // 被讀取端視為正常紀錄——而 events.jsonl 的**實際 bytes** 永久保留那段原文。
    //
    // 這是「每個會被原樣序列化的欄位都要有形狀約束」這條判準的結構性缺口：
    // 未知欄位根本不是欄位。隱私硬約束的標的是**落地的 bytes**，不是 decode
    // 之後的 Swift 值，所以判準要再往前推一步。
    func record(extra: String) -> Data {
        Data("""
            {"kind":"opened","anchor":{"source":"s","turnID":"t1",
            "contentHash":{"hex":"\(合法雜湊)"},"span":[0,1]},
            "timestamp":0,"generation":"build-1","policy":"archival"\(extra)}
            """.utf8)
    }

    #expect(throws: Never.self) { _ = try JSONDecoder().decode(Event.self, from: record(extra: "")) }
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(Event.self, from: record(extra: ",\"query\":\"\(原文)\""))
    }
}

/// JSON 樹上的一個位置。用 enum 而不是 `[String]`，因為路徑要能穿過陣列。
///
/// #1 verify R5：上一版的走訪器 `switch` 只列了 `[String: Any]` 與 `String` 兩種，
/// 陣列落進 `default` 被吞掉。也就是說那條自稱「取代逐欄位列舉」的測試，只是把
/// **欄位列舉換成了容器種類列舉**——而漏掉的那一種正好是當時唯一活著的外洩管道
/// （`span: [Int]`）。判準是「每個會被原樣序列化的**東西**」，不是「每個字串葉節點」。
private enum JSONStep: Equatable { case key(String), index(Int) }

private func objectNodes(_ value: Any, at path: [JSONStep] = []) -> [[JSONStep]] {
    switch value {
    case let object as [String: Any]:
        return [path]
            + object.keys.sorted().flatMap { objectNodes(object[$0]!, at: path + [.key($0)]) }
    case let array as [Any]:
        return array.enumerated().flatMap { objectNodes($1, at: path + [.index($0)]) }
    default:
        return []
    }
}

private func arrayNodes(_ value: Any, at path: [JSONStep] = []) -> [[JSONStep]] {
    switch value {
    case let object as [String: Any]:
        return object.keys.sorted().flatMap { arrayNodes(object[$0]!, at: path + [.key($0)]) }
    case let array as [Any]:
        return [path] + array.enumerated().flatMap { arrayNodes($1, at: path + [.index($0)]) }
    default:
        return []
    }
}

private func stringLeaves(_ value: Any, at path: [JSONStep] = []) -> [[JSONStep]] {
    switch value {
    case let object as [String: Any]:
        return object.keys.sorted().flatMap { stringLeaves(object[$0]!, at: path + [.key($0)]) }
    case let array as [Any]:
        return array.enumerated().flatMap { stringLeaves($1, at: path + [.index($0)]) }
    case is String:
        return [path]
    default:
        return []
    }
}

/// 在 `path` 指到的節點上動手腳。`mutate` 收到該節點、回傳改過的版本。
private func mutating(_ value: Any, at path: [JSONStep], _ mutate: (Any) -> Any) -> Any {
    guard let step = path.first else { return mutate(value) }
    let rest = Array(path.dropFirst())
    switch step {
    case .key(let k):
        guard var object = value as? [String: Any], let child = object[k] else { return value }
        object[k] = mutating(child, at: rest, mutate)
        return object
    case .index(let i):
        guard var array = value as? [Any], array.indices.contains(i) else { return value }
        array[i] = mutating(array[i], at: rest, mutate)
        return array
    }
}

@Test func everyStringFieldInAnEncodedEventRejectsFreeText() throws {
    // **這一條取代逐欄位列舉。**（#1 verify R4）
    //
    // 前幾條測試各自攻擊一個具名欄位——generation、source、contentHash——而
    // R4 指出 `policy` 與 `turnID` 的解碼邊界從來沒被碰過。那不是漏了兩條
    // 測試，是測試的**形狀**錯了：判準是「每個會被原樣序列化的欄位都要有形狀
    // 約束」，而逐一列舉欄位的測試只能證明我想得到的那些。
    // CLAUDE.md 自己那句「列舉會漏，判準不會」在這裡第三次適用。
    //
    // 所以欄位清單改成從**編碼輸出**導出：把一筆填滿的 Event 編碼、走訪 JSON
    // 樹上每一個字串葉節點、逐一換成原文、斷言解碼失敗。新增一個字串欄位而
    // 忘了給它形狀約束，這條會自己變紅——不需要有人想起來補測試。
    let anchor = Anchor(
        source: "fixture-a",
        turn: Turn(id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 1), text: "合成文字"),
        span: 0..<4)
    let event = Event.pin(
        anchor: anchor, at: Date(timeIntervalSince1970: 12_345),
        generation: GenerationID("build-1"), policy: RankingPolicyID("human-like"),
        presentation: .random())

    let encoded = try JSONEncoder().encode(event)
    let tree = try JSONSerialization.jsonObject(with: encoded)
    let paths = stringLeaves(tree)

    // 先確認真的走訪到了東西——空清單會讓整條測試 vacuously pass。
    #expect(paths.count >= 6, "只找到 \(paths.count) 個字串欄位，走訪可能壞了")

    for path in paths {
        let mutated = mutating(tree, at: path) { _ in 原文 }
        let data = try JSONSerialization.data(withJSONObject: mutated)
        #expect(throws: (any Error).self, "\(path) 收下了原文") {
            _ = try JSONDecoder().decode(Event.self, from: data)
        }
    }
}

@Test func eventSurvivesAJSONRoundTripWithEveryFieldPopulated() throws {
    // `CodingKeys` 現在是顯式宣告的（`rejectUnknownKeys` 需要 `allCases`），
    // 而顯式清單會漂移：新增屬性卻忘了加 case，編碼會**安靜地**少一個欄位。
    // 這條把每個欄位都填滿再 round-trip，讓那種漏掉變成紅燈而不是靜默資料遺失。
    let anchor = Anchor(
        source: "fixture-a",
        turn: Turn(id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 1), text: "合成文字內容"),
        span: 0..<4)
    let original = Event.pin(
        anchor: anchor, at: Date(timeIntervalSince1970: 12_345),
        generation: GenerationID("build-1"), policy: RankingPolicyID("human-like"),
        presentation: .random())

    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Event.self, from: encoded)

    #expect(decoded == original)
    #expect(decoded.noteRef != nil)
    #expect(decoded.presentation != nil)
}

@Test func noteAndPresentationReferencesCannotExpressFreeTextAtAll() throws {
    // 這兩個型別的 storage 是 UUID——沒有任何 initializer 收得下字串，
    // 所以「塞原文」在型別層不可表達，不需要驗證邏輯。
    let ref = NoteReference.random()
    #expect(UUID(uuidString: ref.description) != nil)

    // 解碼路徑同樣只接受 UUID 形狀。
    let hostile = "\"\(原文)\""
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(NoteReference.self, from: Data(hostile.utf8))
    }
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(PresentationID.self, from: Data(hostile.utf8))
    }
}

@Test func serializedStoreContainsNoNonAsciiAtAll() throws {
    // 比「搜尋已知 fixture 字串」強的斷言：canonical 檔的每一個 byte 都必須是
    // ASCII。第三方逐字內容在本專案的語料裡幾乎必然含 CJK，所以這條把「原文
    // 外洩」從「我有沒有想到要搜這個字串」變成一個結構性質。
    //
    // 誠實邊界：它擋不掉純 ASCII 的英文原文。真正的結構解是識別碼字元集 +
    // UUID storage（上面幾條測的就是那個）；這條是額外的一層。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-privacy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = try FileEventStore(url: dir.appendingPathComponent("events.jsonl"))

    let anchor = Anchor(
        source: "fixture-a",
        turn: Turn(id: "t1", role: "user", timestamp: Date(), text: 原文),
        span: 0..<8)
    try store.append(
        .interaction(
            .cited, anchor: anchor, at: Date(),
            generation: GenerationID("build-1"), policy: RankingPolicyID("human-like")))
    try store.append(
        .pin(
            anchor: anchor, at: Date(),
            generation: GenerationID("build-1"), policy: RankingPolicyID("human-like")))

    let bytes = try store.serializedBytes()
    let nonASCII = bytes.filter { $0 > 0x7F }
    #expect(nonASCII.isEmpty, "canonical 檔出現 \(nonASCII.count) 個非 ASCII byte")
}

// MARK: - 判準在 bytes 層（#1 verify R5 的 CRITICAL）

/// 造一筆合法事件的 canonical bytes。
private func canonicalLine() throws -> Data {
    let anchor = Anchor(
        // 必須是**當前定址規則**的形狀（32 個小寫 hex）。不是的話，讀取路徑會把
        // 這一行當成舊規則紀錄跳過——於是這個「合法事件」的對照組會變成讀不回來
        // 的東西，而依賴它的每一條測試都改成在證明別的事。
        source: ProjectFingerprint.of("fixture-a"),
        turn: Turn(id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 1), text: "合成文字"),
        span: 0..<4)
    let event = Event.interaction(
        .shown, anchor: anchor, at: Date(timeIntervalSince1970: 12_345),
        generation: GenerationID("build-1"), policy: RankingPolicyID("archival"))
    return try CanonicalCoding.encoder.encode(event)
}

@Test func canonicalBytesRoundTripForAWellFormedLine() throws {
    // 對照組。沒有這條，下面每一條「拒絕」都可能只是因為基準本身就不合法。
    let line = try canonicalLine()
    #expect(throws: Never.self) {
        _ = try CanonicalCoding.decodeCanonicalLine(Event.self, from: line)
    }
}

@Test func theJSONSerializationRenderIsItselfCanonical() throws {
    // **反同義反覆的對照。** 下面兩條注入測試用 `JSONSerialization` 重新產出
    // bytes；如果那個 renderer 的輸出本來就與 `CanonicalCoding.encoder` 不同
    // （數字格式、跳脫規則），注入測試會因為**格式差異**而通過，與注入無關。
    // 這條先證明未經修改的重新產出仍然是 canonical 的。
    let line = try canonicalLine()
    let tree = try JSONSerialization.jsonObject(with: line)
    let rerendered = try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys])
    #expect(throws: Never.self, "renderer 本身就不 canonical，注入測試會是同義反覆") {
        _ = try CanonicalCoding.decodeCanonicalLine(Event.self, from: rerendered)
    }
}

@Test func everyObjectNodeRejectsAnInjectedUnknownKey() throws {
    // **判準形狀的注入測試。** 上一版只在頂層物件尾巴掛一個 `"query"`，於是
    // R5 從巢狀 `anchor` / `contentHash` 走進來（實測解碼成功、原文落進
    // events.jsonl）。節點清單改成從編碼輸出走訪出來——包含陣列裡的物件。
    let line = try canonicalLine()
    let tree = try JSONSerialization.jsonObject(with: line)
    let nodes = objectNodes(tree)
    #expect(nodes.count >= 3, "只找到 \(nodes.count) 個物件節點，走訪可能壞了")

    for node in nodes {
        let mutated = mutating(tree, at: node) { value in
            var object = value as! [String: Any]
            object["leak"] = 原文
            return object
        }
        let data = try JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys])
        #expect(throws: (any Error).self, "物件節點 \(node) 收下了未宣告的鍵") {
            _ = try CanonicalCoding.decodeCanonicalLine(Event.self, from: data)
        }
    }
}

@Test func everyArrayNodeRejectsAnInjectedExtraElement() throws {
    // R5 的第二條路徑：`"span":[2,6,"…原文…"]` 解碼成功，因為 `Range<Int>` 的
    // `init(from:)` 在 **Swift stdlib**、decode 兩個 Bound 之後不檢查 `isAtEnd`。
    // 「給巢狀物件補未知鍵檢查」這個處方對它完全無效——那是 DA 推翻另外兩個
    // lens 的地方。
    let line = try canonicalLine()
    let tree = try JSONSerialization.jsonObject(with: line)
    let nodes = arrayNodes(tree)
    #expect(!nodes.isEmpty, "沒找到任何陣列節點，走訪可能壞了")

    for node in nodes {
        let mutated = mutating(tree, at: node) { value in
            var array = value as! [Any]
            array.append(原文)
            return array
        }
        let data = try JSONSerialization.data(withJSONObject: mutated, options: [.sortedKeys])
        #expect(throws: (any Error).self, "陣列節點 \(node) 收下了多餘元素") {
            _ = try CanonicalCoding.decodeCanonicalLine(Event.self, from: data)
        }
    }
}

@Test func aDuplicatedKeyCarryingFreeTextIsRejected() throws {
    // R5 的第三條路徑。`"policy":"archival","policy":"…原文…"` 解碼成功
    // （swift-foundation 取第一個），re-encode 與原本**逐字相同**，所以未知鍵
    // 檢查在結構上看不見它——鍵就在 `CodingKeys.allCases` 裡。
    // 只有 bytes 比對抓得到：原始 bytes 比 canonical 形式多了一段。
    let line = String(decoding: try canonicalLine(), as: UTF8.self)
    let duplicated = line.replacingOccurrences(
        of: "\"policy\":\"archival\"",
        with: "\"policy\":\"archival\",\"policy\":\"\(原文)\"")
    #expect(duplicated != line, "替換沒生效，測試會 vacuously pass")

    #expect(throws: (any Error).self) {
        _ = try CanonicalCoding.decodeCanonicalLine(Event.self, from: Data(duplicated.utf8))
    }
}

@Test func aUnicodeEscapedPayloadIsRejectedEvenThoughItDecodesToTheSameValue() throws {
    // 第四條：`\uXXXX` 逃脫。解碼後的 Swift 值完全合法，但**檔案裡的 bytes**
    // 與 canonical 形式不同——而隱私硬約束的標的是落地的 bytes。
    // 這條是我沒有列舉到、判準卻自動涵蓋的那一種，留著當判準有效的證據。
    let line = String(decoding: try canonicalLine(), as: UTF8.self)
    let escaped = line.replacingOccurrences(of: "\"archival\"", with: "\"\\u0061rchival\"")
    #expect(escaped != line)

    #expect(throws: (any Error).self) {
        _ = try CanonicalCoding.decodeCanonicalLine(Event.self, from: Data(escaped.utf8))
    }
}

@Test func theStoreReadsSmuggledContentAsCorruptRatherThanHealthy() throws {
    // 端到端：這正是 R5 實測「1 healthy event，51 個非 ASCII byte 留在檔裡」
    // 的那條路徑。現在它必須是 corrupt。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-smuggle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("events.jsonl")

    let line = String(decoding: try canonicalLine(), as: UTF8.self)
    let smuggled = line.replacingOccurrences(
        of: "\"span\":[0,4]", with: "\"span\":[0,4],\"leak\":\"\(原文)\"")
    #expect(smuggled != line)
    try Data((smuggled + "\n").utf8).write(to: path)

    let store = try FileEventStore(url: path)
    #expect(throws: (any Error).self) { _ = try store.allEvents() }

    let salvaged = try store.allEvents(skippingUnusable: true)
    #expect(salvaged.events.isEmpty)
    #expect(salvaged.corruptLines == [1], "必須指名是哪一行，否則救不回來也修不掉")
}

// MARK: - decoder 層（bytes 之外的第二道，各自釘住）

// 為什麼需要這一組：`CanonicalCoding.decodeCanonicalLine` 是**store 的**讀取路徑，
// 但 `Event: Decodable` 是公開的，任何人都能直接 `JSONDecoder().decode`。A/B 實測
// 顯示：把 decoder 層整個拿掉，上面那組 bytes 測試仍然全綠——也就是說 decoder 層
// 當時沒有任何測試釘住，正是 R5 反覆抓到的那個形狀。這一組專走 plain decoder。

@Test func plainDecodingRejectsAnUnknownKeyInsideAnchor() throws {
    let line = String(decoding: try canonicalLine(), as: UTF8.self)
    let hostile = line.replacingOccurrences(
        of: "\"span\":[0,4]", with: "\"span\":[0,4],\"leak\":\"\(原文)\"")
    #expect(hostile != line)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(Event.self, from: Data(hostile.utf8))
    }
}

@Test func plainDecodingRejectsAnUnknownKeyInsideContentHash() throws {
    let line = String(decoding: try canonicalLine(), as: UTF8.self)
    // contentHash 物件的結尾：`"hex":"<64>"}`
    let hostile = line.replacingOccurrences(
        of: "\"contentHash\":{", with: "\"contentHash\":{\"leak\":\"\(原文)\",")
    #expect(hostile != line)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(Event.self, from: Data(hostile.utf8))
    }
}

@Test func plainDecodingRejectsAnExtraElementInTheSpanArray() throws {
    // `Range<Int>` 的 stdlib decoder 不檢查 `isAtEnd`，所以這條靠的是 `Anchor`
    // 自己讀 unkeyed 容器並要求長度恰為 2。
    let line = String(decoding: try canonicalLine(), as: UTF8.self)
    let hostile = line.replacingOccurrences(of: "\"span\":[0,4]", with: "\"span\":[0,4,\"\(原文)\"]")
    #expect(hostile != line)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(Event.self, from: Data(hostile.utf8))
    }
}

@Test func theErrorForAnUndeclaredKeyDoesNotEchoTheKeyName() throws {
    // R5（security lens）：未知鍵的錯誤訊息原本把攻擊者控制的鍵名原樣印出來
    // ——擋原文進 store 的機制，自己把原文帶進 log。
    //
    // **R6：上一版是同義反覆**——它手工建一個不含原文的 error 值，再斷言那個值
    // 不含原文。當然不含，原文從來沒進去過。要驗的是真的**用原文當鍵名**去觸發
    // 那條路徑，再看拋出來的錯誤長什麼樣。
    let line = String(decoding: try canonicalLine(), as: UTF8.self)
    let hostile = line.replacingOccurrences(
        of: "\"span\":[0,4]", with: "\"span\":[0,4],\"\(原文)\":1")
    #expect(hostile != line, "替換沒生效，測試會 vacuously pass")

    var description = ""
    do {
        _ = try JSONDecoder().decode(Event.self, from: Data(hostile.utf8))
    } catch {
        description = "\(error)"
    }
    #expect(!description.isEmpty, "必須真的拋出，否則下面的斷言是空的")
    #expect(!description.contains(原文), "錯誤訊息回顯了攻擊者控制的鍵名")
}


// MARK: - 反序 span 與空內容雜湊（#1 verify R6 的 CRITICAL）

@Test func anInvertedSpanIsReportedAsCorruptRatherThanAbortingTheProcess() throws {
    // R6：`lower..<upper` 在 `lower > upper` 時觸發 stdlib 的 precondition 並
    // **中止行程**，所以 `validate(span:)` 永遠看不到反序輸入——它要驗的值
    // 構造不出來。一行壞資料因此讓整份 canonical store 連 skippingCorrupt 都
    // 讀不回來。修法是在**還沒組成 Range 的整數**上驗。
    #expect(throws: Anchor.SpanValidationError.inverted(lower: 9, upper: 3)) {
        try Anchor.validate(lower: 9, upper: 3)
    }

    let line = String(decoding: try canonicalLine(), as: UTF8.self)
    let inverted = line.replacingOccurrences(of: "\"span\":[0,4]", with: "\"span\":[9,3]")
    #expect(inverted != line)
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(Event.self, from: Data(inverted.utf8))
    }
}

@Test func theRepairPathSurvivesAnInvertedSpanLine() throws {
    // 這條才是 CRITICAL 的核心：崩在**修復路徑**上。
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-inverted-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("events.jsonl")

    let good = String(decoding: try canonicalLine(), as: UTF8.self)
    let bad = good.replacingOccurrences(of: "\"span\":[0,4]", with: "\"span\":[9,3]")
    try Data((good + "\n" + bad + "\n").utf8).write(to: path)

    let store = try FileEventStore(url: path)
    let salvaged = try store.allEvents(skippingUnusable: true)
    #expect(salvaged.events.count == 1, "好的那一行必須救得回來")
    #expect(salvaged.corruptLines == [2])
}

@Test func theEmptyContentDigestCannotBeStoredByAnyPath() throws {
    // R3 用「span 不得為空」擋萬用 anchor、R4 補了漏掉的入口、R6 找到第三條
    // 路徑：**純空白的 span**——`normalize` 去掉空白之後仍是空字串，雜湊仍是
    // `sha256("")`，於是它對任何文字都 resolve 成功。
    //
    // 前兩次擋的是入口，這次擋的是**那個值本身**：任何路徑產出的
    // `sha256("")` 都不合法，包括我還沒想到的路徑。
    #expect(throws: ContentHash.ValidationError.emptyContentDigest) {
        try ContentHash.validate(ContentHash.emptyContentDigestHex)
    }
    #expect(Anchor.normalize("   ") == "", "前提：純空白正規化後是空字串")

    // 解碼邊界。
    //
    // **這一段先前沒有測到它宣稱的東西**（#22 item 9）：它把空摘要**前綴**到
    // 既有 hex 上，於是解出來是 128 字元，拋的是 `wrongLength(128)`——一條
    // 長度檢查，不是空摘要那條邊界。而斷言寫 `throws: (any Error).self`，對
    // 任何錯誤都成立，所以分辨不出這件事。測試名字比它的斷言強。
    //
    // 現在**整個換掉** hex 的值，讓解碼器真的看到 `sha256("")`，並斷言具體是
    // 哪一個錯誤。變異驗證：守衛改成拋 `wrongLength(999)` → 變紅。
    let line = String(decoding: try canonicalLine(), as: UTF8.self)
    let hostile = try #require(
        replacingHexValue(in: line, with: ContentHash.emptyContentDigestHex),
        "前提：canonical 行裡找得到一個 hex 欄位可以替換")
    #expect(throws: ContentHash.ValidationError.emptyContentDigest) {
        _ = try JSONDecoder().decode(Event.self, from: Data(hostile.utf8))
    }
}

/// 把 canonical 行裡 `"hex":"…"` 的**值整個**換掉，回 `nil` 表示找不到。
private func replacingHexValue(in line: String, with replacement: String) -> String? {
    guard let start = line.range(of: "\"hex\":\""),
        let end = line.range(of: "\"", range: start.upperBound..<line.endIndex)
    else { return nil }
    return line.replacingCharacters(in: start.upperBound..<end.lowerBound, with: replacement)
}

@Test func aWhitespaceOnlySpanCannotProduceAnAnchor() async {
    // 上一條的入口側：從 turn 造 anchor 時，純空白的 span 現在會被擋下來
    // （雜湊等於空內容摘要 → `ContentHash(hex:)` trap）。
    await #expect(processExitsWith: .failure) {
        let turn = Turn(
            id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 1),
            text: "abc   def")
        _ = Anchor(source: "s", turn: turn, span: 3..<6)  // 只涵蓋三個空白
    }
}
