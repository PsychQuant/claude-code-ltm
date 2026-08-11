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
    /// 指定的路徑落在唯讀語料內。
    case pathInsideReadOnlyCorpus(path: String)
}

/// 唯讀語料的根。任何寫入路徑都不得落在它底下。
///
/// 不變式 1 說「`~/.claude/projects/` 唯讀，出現任何寫入路徑就是 bug」。#1 的
/// verify 指出：在 `FileEventStore(url:)` 吃任意 URL 的情況下，那個寫入路徑
/// **就是公開 API 的一部分**，不是呼叫端紀律問題。所以把檢查放進建構子。
public enum CorpusLocation {
    public static var readOnlyRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
    }

    /// 解析 symlink 之後判斷是否落在語料根底下。
    ///
    /// 一定要先 resolve：表面路徑在 `~/.claude-ltm/` 但實際是指向語料的 symlink
    /// 時，只比字串會穿透。父目錄不存在時退回逐層往上找已存在的祖先來解析。
    public static func isInsideReadOnlyCorpus(_ url: URL) -> Bool {
        let root = readOnlyRoot.resolvingSymlinksInPath().standardizedFileURL
        var probe = url.standardizedFileURL
        // 目標檔案通常還不存在，resolvingSymlinksInPath 對不存在的路徑不解析，
        // 所以從最近的存在祖先開始解析，再把剩下的元件接回去。
        var trailing: [String] = []
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            trailing.append(probe.lastPathComponent)
            probe = probe.deletingLastPathComponent()
        }
        var resolved = probe.resolvingSymlinksInPath().standardizedFileURL
        for component in trailing.reversed() {
            resolved = resolved.appendingPathComponent(component)
        }

        let rootComponents = root.pathComponents
        let targetComponents = resolved.standardizedFileURL.pathComponents
        guard targetComponents.count >= rootComponents.count else { return false }
        return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
    }
}

/// JSON Lines 檔案實作。
///
/// 一行一筆、只 append：這個格式讓 append-only 成為檔案層的事實，而不只是
/// API 層的約定。
public struct FileEventStore: EventStore {
    public let url: URL

    /// 建構即檢查路徑。落在唯讀語料內 → throw，不給呼叫端「先建起來再說」的機會。
    public init(url: URL) throws {
        guard !CorpusLocation.isInsideReadOnlyCorpus(url) else {
            throw EventStoreError.pathInsideReadOnlyCorpus(path: url.path)
        }
        self.url = url
    }

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

        // `seekToEnd` + `write` 是兩個 syscall，中間可被其他行程插入 → 互相覆寫
        // canonical history（#1 verify）。改用 O_APPEND：核心保證「移到檔尾」與
        // 「寫入」對一般檔案是原子的，多行程並行 append 因此安全。
        // 權限 0o600：記憶層是本專案唯一必須備份的資料，不該是 world-readable。
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw EventStoreError.appendFailed(
                path: url.path, underlying: "open 失敗：errno \(errno)（目錄可寫嗎？）")
        }
        defer { close(fd) }

        var remaining = line[...]
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else {
                throw EventStoreError.appendFailed(
                    path: url.path, underlying: "write 失敗：errno \(errno)")
            }
            remaining = remaining.dropFirst(written)
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
