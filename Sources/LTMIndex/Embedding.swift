import Foundation
import NaturalLanguage

/// 產生句向量的來源。
///
/// 抽成 protocol 有兩個理由，都不是「為了測試而抽象」：
///
/// 1. **revision 是索引作廢的判準**，所以它必須是這個介面的一等公民，而不是
///    某個實作的內部細節。索引存的是「哪一個 revision 算出來的向量」，查詢時
///    比對的也是它。
/// 2. `NLContextualEmbedding` 需要下載 model assets，沒有 assets 的機器（CI、
///    剛裝好的系統）拿不到向量。那條路徑必須能被明確地測到，而不是「在那台
///    機器上測試會失敗」。
public protocol EmbeddingProvider: Sendable {
    /// 這個 provider 目前的 revision。變了就代表舊向量不可再比。
    var revision: String { get }
    /// 向量維度。
    var dimension: Int { get }
    /// 一段文字的句向量。回 `nil` 代表這段文字產不出向量（例如全是標點）。
    func vector(for text: String) throws -> [Float]?
}

/// `NLContextualEmbedding` 的包裝。
///
/// **中文必須用這一個**：舊的 `NLEmbedding.sentenceEmbedding(for:)` 對
/// `.traditionalChinese` / `.simplifiedChinese` 回 `nil`——會靜默拿不到向量而
/// 不報錯（CLAUDE.md 的技術要點）。
public final class ContextualEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public enum EmbeddingError: Error, Sendable, Equatable {
        /// model assets 尚未下載。**不靜默降級**：沒有向量的檢索少一路通道，
        /// 而少一路的結果看起來完全正常。
        case assetsUnavailable(detail: String)
        case loadFailed(detail: String)
    }

    private let embedding: NLContextualEmbedding
    public let revision: String
    public let dimension: Int

    /// - Parameter script: 語料以哪個 script 為主。多語系語料用 `.latin` 之外的
    ///   模型仍可處理拉丁字，反之亦然——這個參數決定的是模型，不是過濾器。
    public init(script: NLScript = .simplifiedChinese) throws {
        guard let embedding = NLContextualEmbedding(script: script) else {
            throw EmbeddingError.loadFailed(detail: "NLContextualEmbedding(script: \(script)) 回 nil")
        }
        if !embedding.hasAvailableAssets {
            throw EmbeddingError.assetsUnavailable(
                detail: "script=\(script) 的 model assets 未就緒；需先讓系統下載完成")
        }
        do {
            try embedding.load()
        } catch {
            throw EmbeddingError.loadFailed(detail: String(describing: error))
        }
        self.embedding = embedding
        // revision 進索引，所以它要是穩定可比的字串。把模型識別一起寫進去：
        // 只記數字的話，換了 script 模型但 revision 編號碰巧相同就分不出來。
        //
        // **池化版本也要進去**（#5）。決定一個向量長什麼樣的不只是模型：
        // `vector(for:)` 對 token 向量做平均再正規化，而那段程式碼改了——換成
        // max-pooling、拿掉正規化、改 token 範圍——產出的向量與舊的**不在同一個
        // 空間**，可是模型識別與 revision 一個字都不會變。
        //
        // 於是舊向量與新向量混在同一個 `vectors.bin` 裡比距離，結果無意義**而且
        // 不報錯**——`CLAUDE.md` 記的那個坑，只是換了觸發原因（不是 macOS 更新，
        // 是我們自己改了程式碼）。改 `vector(for:)` 的人必須同時把這個常數 +1，
        // 而下面那則註解就在它旁邊。
        self.revision = "\(embedding.modelIdentifier)#\(embedding.revision)#pool\(Self.poolingVersion)"
        self.dimension = embedding.dimension
    }

    /// `vector(for:)` 的池化與正規化方式的版本。
    ///
    /// **改 `vector(for:)` 的語意就要 +1。** 它進 `revision`，而 `revision` 不符
    /// 會強制整份重建——那正是換代時該發生的事。不 +1 的後果不是錯誤訊息，是
    /// 兩代向量安靜地混在同一個空間裡。
    ///
    /// 1 = 對 token 向量取算術平均，再正規化成單位長度。
    static let poolingVersion = 1

    public func vector(for text: String) throws -> [Float]? {
        let result = try embedding.embeddingResult(for: text, language: nil)
        var sum = [Float](repeating: 0, count: dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for (index, value) in vector.enumerated() where index < sum.count {
                sum[index] += Float(value)
            }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        // 平均池化後正規化成單位長度：之後的相似度就是點積，不必每次算模長。
        var mean = sum.map { $0 / Float(count) }
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for index in mean.indices { mean[index] /= norm }
        return mean
    }
}

/// 向量的平坦側車檔。
///
/// 一個向量接一個向量的 `Float32`，沒有 header——維度與筆數記在索引的 `meta`
/// 表裡。分開存的理由是讀取方式不同：SQLite 走它自己的頁快取，而向量要的是
/// 一整塊連續記憶體給 Accelerate 掃。
///
/// 讀取用 mmap 而不是整份載入：語料成長時工作集跟著長，但真正被碰到的頁由
/// kernel 決定。**這不是效能宣稱**——沒有量測支撐的比較本 repo 不寫；這只是
/// 說明為什麼是 mmap 而不是 `Data(contentsOf:)`。
public struct VectorSidecar: Sendable {
    public let dimension: Int
    public let count: Int
    private let storage: Data

    public init(dimension: Int, count: Int, storage: Data) {
        self.dimension = dimension
        self.count = count
        self.storage = storage
    }

    /// 從檔案映射。
    public static func open(url: URL, dimension: Int) throws -> VectorSidecar {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let stride = dimension * MemoryLayout<Float>.size
        guard stride > 0 else { return VectorSidecar(dimension: dimension, count: 0, storage: Data()) }
        return VectorSidecar(dimension: dimension, count: data.count / stride, storage: data)
    }

    /// 第 `row` 個向量。越界回 `nil`（越界是呼叫端的錯，但在讀取路徑上不 trap）。
    public func vector(at row: Int) -> [Float]? {
        guard row >= 0, row < count else { return nil }
        let stride = dimension * MemoryLayout<Float>.size
        let start = row * stride
        return storage.withUnsafeBytes { raw -> [Float] in
            let base = raw.baseAddress!.advanced(by: start).assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: base, count: dimension))
        }
    }

    /// 把一批向量寫成側車檔的 bytes。
    public static func encode(_ vectors: [[Float]]) -> Data {
        var data = Data()
        data.reserveCapacity(vectors.reduce(0) { $0 + $1.count * MemoryLayout<Float>.size })
        for vector in vectors {
            vector.withUnsafeBufferPointer { buffer in
                data.append(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
            }
        }
        return data
    }
}
