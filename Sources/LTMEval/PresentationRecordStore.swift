import Foundation
import LTMCore
import LTMMemory

/// 交錯呈現紀錄的存放介面。
///
/// 與 `EventStore` 一樣**只有 append 與全讀**，沒有更新或刪除單筆。理由也一樣：
/// 一次呈現發生過就是發生過，事後修改單筆紀錄等於改寫歷史。
///
/// ## 它為什麼可以進 canonical 層
///
/// CLAUDE.md 的記憶層硬約束是「只存指標、統計、與封閉集合的類別標籤」。
/// `PresentationRecord` 的每個欄位都落在裡面：`id`／`generation` 是識別碼，
/// `queryClass` 是封閉五值標籤，`strategyA`／`strategyB` 是策略識別碼，
/// `attribution` 是 anchor 加策略識別碼，`startingSide` 是二值，
/// `isNullComparison` 是布林。**沒有 query 原文**——它在
/// `InterleavingHarness.present` 裡被算成 label 之後就丟掉了。
///
/// 落地的 bytes 由 `CanonicalCoding.decodeCanonicalLine` 逐字比對把關，與事件
/// 檔同一條規則：解碼後重新編碼必須與原始 bytes 相同，否則當作損壞。
public protocol PresentationRecordStore: Sendable {
    /// 附加一筆呈現紀錄。無法持久化時必須拋出。
    func append(_ record: PresentationRecord) throws
    /// 讀回全部紀錄，維持寫入順序。
    func allRecords() throws -> [PresentationRecord]
}

/// JSON Lines 的呈現紀錄存放。
///
/// 路徑守衛、原子 append、受檢讀取全部委派給 `CanonicalStore`——那是
/// `FileEventStore` 走的同一條路徑。**這裡刻意沒有第二份實作**：兩份 append
/// 就是兩份會漂移的規格，而漂移的方向是新的那份少了其中一條保護。
public struct FilePresentationRecordStore: PresentationRecordStore {
    public let url: URL

    public init(url: URL) throws {
        self.url = try CanonicalStore.validatedPath(url)
    }

    /// 每次呼叫新建 encoder——理由見 `FileEventStore.encoder`（跨呼叫共享的
    /// reference type 會讓 `Sendable` 變成假的）。
    private var encoder: JSONEncoder { CanonicalCoding.encoder }

    public func append(_ record: PresentationRecord) throws {
        let line: Data
        do {
            line = try encoder.encode(record) + Data("\n".utf8)
        } catch {
            throw EventStoreError.appendFailed(path: url.path, underlying: "\(error)")
        }
        try CanonicalStore.appendLine(line, to: url)
    }

    /// 全部紀錄，維持寫入順序。
    ///
    /// **fail-loud**：解不開的行一律具名拋出，與事件檔同一條紀律。呈現紀錄是
    /// 計分的分母來源，靜默跳過一筆會讓「這份報告用了多少次呈現」少算而報告
    /// 照常產出——那正是 `SkippedEvents` 存在要防的那種安靜。
    public func allRecords() throws -> [PresentationRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let bytes: Data
        do {
            bytes = try CanonicalStore.readRegularFile(at: url)
        } catch {
            throw EventStoreError.readFailed(path: url.path, underlying: "\(error)")
        }
        var result: [PresentationRecord] = []
        // 不略過空行——行號要對得上檔案，理由見 `FileEventStore.allEvents`。
        for (index, line) in String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        {
            if line.isEmpty { continue }
            do {
                result.append(
                    try CanonicalCoding.decodeCanonicalLine(
                        PresentationRecord.self, from: Data(line.utf8)))
            } catch {
                throw EventStoreError.corruptRecord(path: url.path, lineNumber: index + 1)
            }
        }
        return result
    }

    /// 檔案的原始 bytes。給「落地的 bytes 不得含任何原文」那條測試用——
    /// 斷言要下在真正落地的 bytes 上，不是下在某個重新編碼過的複本上。
    public func serializedBytes() throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        return try CanonicalStore.readRegularFile(at: url)
    }
}
