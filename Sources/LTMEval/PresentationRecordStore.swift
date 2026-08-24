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
    /// **fail-loud**：解不開的行、以及舊定址規則寫的行，一律具名拋出——與事件檔
    /// 同一條紀律。呈現紀錄是計分的分母來源，靜默跳過一筆會讓「這份報告用了多少次
    /// 呈現」少算而報告照常產出——那正是 `SkippedEvents` 存在要防的那種安靜。
    ///
    /// 修復情境用 `allRecords(skippingUnusable: true)`（#36 階段 2）。
    public func allRecords() throws -> [PresentationRecord] {
        let result = try allRecords(skippingUnusable: false)
        guard result.supersededLines.isEmpty else {
            throw EventStoreError.supersededAnchorRule(
                path: url.path, lineNumbers: result.supersededLines)
        }
        return result.records
    }

    /// 讀取全部紀錄，可選擇是否跳過壞行。
    ///
    /// ## 為什麼這個逃生口必須存在（#36 D2）
    ///
    /// 事件檔早就有它（`FileEventStore.allEvents(skippingUnusable:)`，理由寫在那裡：
    /// 一次半途中斷的 append 留下一行壞資料，**整份 canonical store 從此讀不出來**）。
    /// 呈現紀錄走的是**同一個** `CanonicalStore.appendLine`、同一種中斷風險，卻沒有
    /// 對應的逃生口——那個不對稱是 #33 verify 抓到的，而 code 註解當時已經宣稱兩者
    /// 「同一條紀律」。
    ///
    /// ## 為什麼沒有對應的 `--prune`
    ///
    /// **刻意的。** `ltm memory --prune` 的名字與說明是「丟掉讀不回來的紀錄」，而在
    /// 它**主要的**觸發情境（定址規則換代，於是舊紀錄全部讀不回來）裡，它做的是
    /// 「清空整份歷史」——那條教訓記在 `CLAUDE.md`。再開一個同形狀的破壞性表面是
    /// 複製一個已知危險。**可復原性不需要用刪除達成**：讀得回來的部分救出來、
    /// 跳過的行號報出來，使用者自己決定怎麼處置那幾行。
    ///
    /// - Parameter skippingUnusable: `true` 時跳過**兩類**不可用的紀錄並回報行號：
    ///   解不開的（`corruptLines`）與舊定址規則寫的（`supersededLines`）。兩類分開
    ///   回報，因為處置不同——損壞的是壞資料，舊規則的是**好資料但指向已經不成立的
    ///   定址方式**。
    public func allRecords(skippingUnusable: Bool) throws
        -> (records: [PresentationRecord], corruptLines: [Int], supersededLines: [Int])
    {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], [], []) }
        let bytes: Data
        do {
            bytes = try CanonicalStore.readRegularFile(at: url)
        } catch {
            throw EventStoreError.readFailed(path: url.path, underlying: "\(error)")
        }
        var result: [PresentationRecord] = []
        var corrupt: [Int] = []
        var superseded: [Int] = []
        // 不略過空行——行號要對得上檔案，理由見 `FileEventStore.allEvents`。
        for (index, line) in String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        {
            if line.isEmpty { continue }
            do {
                let record = try CanonicalCoding.decodeCanonicalLine(
                    PresentationRecord.self, from: Data(line.utf8))
                // 舊規則的 anchor 一律具名拒絕，**而且用真實檔案行號**。
                //
                // 一筆紀錄帶多個 anchor（逐位置歸屬），**任何一個**是舊規則就整筆
                // 不可用：這筆紀錄的用途是把事件歸屬到位置，而歸屬需要每個 anchor
                // 都解析得回去。部分解析等於部分歸屬，而部分歸屬的分母是錯的。
                guard
                    record.attribution.allSatisfy({
                        ProjectFingerprint.hasCurrentRuleShape($0.anchor.source)
                    })
                else {
                    superseded.append(index + 1)
                    continue
                }
                result.append(record)
            } catch {
                guard skippingUnusable else {
                    throw EventStoreError.corruptRecord(path: url.path, lineNumber: index + 1)
                }
                corrupt.append(index + 1)
            }
        }
        return (result, corrupt, superseded)
    }

    /// 檔案的原始 bytes。給「落地的 bytes 不得含任何原文」那條測試用——
    /// 斷言要下在真正落地的 bytes 上，不是下在某個重新編碼過的複本上。
    public func serializedBytes() throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        return try CanonicalStore.readRegularFile(at: url)
    }
}
