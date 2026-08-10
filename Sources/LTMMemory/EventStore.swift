import Foundation
import LTMCore

/// canonical 使用歷史的存放介面。
///
/// 只有 append 與 range read。**刻意沒有** update／delete 單筆事件的操作：
/// 記憶層記的是「發生過什麼」，事後修改單筆紀錄等於改寫歷史，而不是修正
/// 一個可重算的衍生值。
public protocol EventStore: Sendable {
    /// 附加一筆事件。無法持久化時必須拋出——記憶層與索引不同，掉了就回不來。
    func append(_ event: Event) throws
    /// 讀取 `[from, to)` 區間內的事件，維持寫入順序。
    func events(from: Date, to: Date) throws -> [Event]
}

public enum EventStoreError: Error, Sendable {
    case appendFailed(path: String, underlying: String)
    case readFailed(path: String, underlying: String)
    /// 解不開的紀錄一律外顯。靜默跳過會讓「外來寫入者塞了本 schema 不認得的
    /// 東西」看起來像「那天沒有事件」。
    case corruptRecord(path: String, lineNumber: Int)
}

/// JSON Lines 檔案實作。
///
/// 一行一筆、只 append：這個格式讓 append-only 成為檔案層的事實，而不只是
/// API 層的約定。
public struct FileEventStore: EventStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public func append(_ event: Event) throws {
        let line: Data
        do {
            line = try Self.encoder.encode(event) + Data("\n".utf8)
        } catch {
            throw EventStoreError.appendFailed(path: url.path, underlying: "\(error)")
        }

        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: line) else {
                    throw EventStoreError.appendFailed(
                        path: url.path, underlying: "無法建立檔案（目錄可寫嗎？）")
                }
                return
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch let error as EventStoreError {
            throw error
        } catch {
            throw EventStoreError.appendFailed(path: url.path, underlying: "\(error)")
        }
    }

    public func events(from: Date, to: Date) throws -> [Event] {
        try allEvents().filter { $0.timestamp >= from && $0.timestamp < to }
    }

    /// 全部事件，維持寫入順序。
    public func allEvents() throws -> [Event] {
        let bytes: Data
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            bytes = try Data(contentsOf: url)
        } catch {
            throw EventStoreError.readFailed(path: url.path, underlying: "\(error)")
        }

        let decoder = JSONDecoder()
        var result: [Event] = []
        for (index, line) in String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).enumerated()
        {
            do {
                result.append(try decoder.decode(Event.self, from: Data(line.utf8)))
            } catch {
                throw EventStoreError.corruptRecord(path: url.path, lineNumber: index + 1)
            }
        }
        return result
    }

    /// 檔案的原始 bytes。給「序列化輸出不得含任何原文」那條測試用——
    /// 斷言要下在真正落地的 bytes 上，不是下在某個重新編碼過的複本上。
    public func serializedBytes() throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw EventStoreError.readFailed(path: url.path, underlying: "\(error)")
        }
    }
}
