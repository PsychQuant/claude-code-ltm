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

    /// 判斷路徑是否落在語料根底下，**逐層解析 symlink**。
    ///
    /// #1 verify R2（logic + security 兩個 lens 各自重現）：先前的實作是
    /// 「`standardizedFileURL` → 從最近的存在祖先 resolve → 把剩下的元件接回去」。
    /// 兩個破口：
    ///
    /// 1. **`standardizedFileURL` 會先把 `..` 做字面消解**，而 `..` 在 symlink
    ///    之後的語意是「解析後那個目錄的父層」，不是字面上的前一段。於是
    ///    `<tmp>/link/../projects/p/s.jsonl`（link → `~/.claude`）被字面消成
    ///    `<tmp>/projects/...`，守衛判「在外面」，kernel 卻寫進語料裡。
    /// 2. 尾端元件整段不解析，所以**葉節點是 dangling symlink** 時也穿透。
    ///
    /// 改法：從根開始逐段拼接，每拼一段就 resolve 一次，`..` 在解析後的路徑上
    /// 才做消解。這與 kernel 實際走路徑的順序一致。
    ///
    /// **誠實邊界：這仍是 TOCTOU 的。** 檢查與開檔之間，任何一段都可能被換成
    /// symlink。真正的結構解是開檔時用 `O_NOFOLLOW` 逐段開（`openat` 走一遍），
    /// 那需要重寫 append 路徑，追蹤於 follow-up。這裡擋的是誤用與既存的錯誤
    /// 佈局，不是有能力在窗口內競態的攻擊者。
    public static func isInsideReadOnlyCorpus(_ url: URL) -> Bool {
        let root = URL(fileURLWithPath: readOnlyRoot.path).resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents

        var resolved = URL(fileURLWithPath: "/")
        for component in url.pathComponents.dropFirst() {
            if component == "." { continue }
            if component == ".." {
                // 在**已解析**的路徑上往上一層，而不是在字面路徑上。
                resolved = resolved.deletingLastPathComponent()
                continue
            }
            resolved = resolved.appendingPathComponent(component)
            // 逐段解析：存在且是 symlink 時展開，不存在就原樣留著（尾端常見）。
            if FileManager.default.fileExists(atPath: resolved.path) {
                resolved = resolved.resolvingSymlinksInPath()
            } else {
                resolved = Self.followDanglingChain(from: resolved)
            }
        }

        let target = resolved.standardizedFileURL.pathComponents
        guard target.count >= root.count else { return false }
        return Array(target.prefix(root.count)) == root
    }

    /// 沿著 dangling symlink 鏈一路解析到不再是 symlink 為止。
    ///
    /// `destinationOfSymbolicLink` 只回**直接目標**，而 `standardizedFileURL`
    /// 只做字面消解、不再解 symlink。R2 修好了單層 dangling 的穿透，但
    /// `A → B → <corpus>/x.jsonl`（整鏈 dangling）在守衛眼中只看到 `A → B`
    /// 就停了——#1 verify R3 實測穿透，且 `open(O_WRONLY|O_APPEND|O_CREAT)`
    /// 會沿鏈把檔案建在最終目標，也就是語料裡。
    ///
    /// 上限取 `SYMLOOP_MAX`（POSIX 保證至少 8；這裡取 40 與多數 kernel 一致），
    /// 到頂就停在當下位置——寧可把它當成「還在鏈上」保守判斷，也不要無限迴圈。
    private static func followDanglingChain(from start: URL) -> URL {
        var current = start
        for _ in 0..<40 {
            guard
                let target = try? FileManager.default.destinationOfSymbolicLink(
                    atPath: current.path)
            else { return current }
            current =
                target.hasPrefix("/")
                ? URL(fileURLWithPath: target).standardizedFileURL
                : current.deletingLastPathComponent().appendingPathComponent(target)
                    .standardizedFileURL
            // 中途若接到一個真的存在的節點，交回一般路徑解析。
            if FileManager.default.fileExists(atPath: current.path) {
                return current.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        return current
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

    /// 每次呼叫新建 encoder。
    ///
    /// 先前是 `private static let`——跨呼叫共享的 reference type，而
    /// `EventStore: Sendable` 等於承諾可以並行呼叫。`JSONEncoder` 在此沒有任何
    /// 序列化保護，那個 `Sendable` 是假的（#1 verify R3）。新建一個 encoder 的
    /// 成本遠低於「canonical 歷史被兩個執行緒寫壞」的成本。
    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public func append(_ event: Event) throws {
        let line: Data
        do {
            line = try encoder.encode(event) + Data("\n".utf8)
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
        // durability：回傳成功必須代表**已落盤**。protocol 的註解寫「無法持久化時
        // 必須拋出——記憶層與索引不同，掉了就回不來」，但先前只涵蓋 `write` 失敗，
        // 不涵蓋「還在 page cache、斷電就沒了」（#1 verify R3）。
        // fsync 失敗同樣要拋——那正是「寫不進去」的一種。
        defer { close(fd) }

        try Self.enforceOwnerOnlyRegularFile(fd: fd, path: url.path)

        // #1 verify R2（logic lens）：先前的迴圈把任何 `write` 失敗直接拋出，
        // 於是「已寫了一半再失敗」會在檔尾留下**半行 JSON**。因為讀取端對解不開
        // 的行是 fail-loud（這是刻意的），那半行會讓**整個 canonical store 從此
        // 讀不出來**——一次暫時性的錯誤變成永久性的損壞。EINTR 更是被當成致命錯，
        // 而它只是「被訊號打斷，請重試」。
        //
        // 兩層處理：EINTR / EAGAIN 重試；真的中斷在半路時，補一個換行把殘行封口。
        //
        // **封口本身不足以讓損壞侷限在那一筆**（#1 verify R3 指出 R2 的註解在這裡
        // 過度宣稱）：讀取端對解不開的行是 fail-loud，所以檔案裡有一行壞掉，
        // 整份就讀不出來。封口只是讓壞的範圍停在一行、不吃掉下一筆。真正讓
        // 「損壞侷限」成立的是讀取端的 `allEvents(skippingCorrupt:)`——見該方法。
        var remaining = line[...]
        var wroteAnything = false
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                let failure = errno
                if wroteAnything { Self.terminatePartialLine(fd) }
                throw EventStoreError.appendFailed(
                    path: url.path,
                    underlying: "write 失敗：errno \(failure)"
                        + (wroteAnything ? "（已寫入部分位元組，已補換行封口）" : ""))
            }
            if written == 0 {
                if wroteAnything { Self.terminatePartialLine(fd) }
                throw EventStoreError.appendFailed(path: url.path, underlying: "write 回傳 0")
            }
            wroteAnything = true
            remaining = remaining.dropFirst(written)
        }

        guard fsync(fd) == 0 else {
            throw EventStoreError.appendFailed(
                path: url.path, underlying: "fsync 失敗：errno \(errno)（資料可能未落盤）")
        }
    }

    /// 確認開到的是一般檔案，且權限收到 owner-only。
    ///
    /// `open(..., O_CREAT, 0o600)` 的 mode **只在真正新建檔案時生效**（#1 verify
    /// R3）。既有的 `events.jsonl`——舊版建立、備份還原、或不同 umask 產生的——
    /// 會維持它原本的 mode，於是同機其他使用者讀得到全部 anchor 與互動歷史。
    /// 現有測試只驗證新建的檔案，抓不到升級／還原情境。
    ///
    /// 一併拒絕非一般檔案：canonical store 指向 FIFO 或裝置節點時，`append`
    /// 的語意完全不是「附加一筆歷史」。
    private static func enforceOwnerOnlyRegularFile(fd: Int32, path: String) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw EventStoreError.appendFailed(
                path: path, underlying: "fstat 失敗：errno \(errno)")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw EventStoreError.appendFailed(
                path: path, underlying: "不是一般檔案（mode \(String(info.st_mode, radix: 8))）")
        }
        let permissions = info.st_mode & 0o777
        guard permissions & 0o077 != 0 else { return }  // 已經是 owner-only
        guard fchmod(fd, 0o600) == 0 else {
            throw EventStoreError.appendFailed(
                path: path,
                underlying: "既有檔案為 \(String(permissions, radix: 8))，收緊權限失敗：errno \(errno)")
        }
    }

    /// 盡力把殘行封口。這裡刻意忽略錯誤：已經在錯誤路徑上，再拋一次只會蓋掉
    /// 原始原因，而封口失敗的後果不會比不封口更糟。
    private static func terminatePartialLine(_ fd: Int32) {
        var newline: UInt8 = 0x0A
        _ = withUnsafeBytes(of: &newline) { write(fd, $0.baseAddress, 1) }
    }

    public func events(from: Date, to: Date) throws -> [Event] {
        try allEvents().filter { $0.timestamp >= from && $0.timestamp < to }
    }

    /// 全部事件，維持寫入順序。
    public func allEvents() throws -> [Event] {
        try allEvents(skippingCorrupt: false).events
    }

    /// 讀取全部事件，可選擇是否跳過壞行。
    ///
    /// **預設 fail-loud**（`skippingCorrupt: false`）：解不開的紀錄一律外顯，
    /// 因為靜默跳過會讓「外來寫入者塞了本 schema 不認得的東西」看起來像
    /// 「那天沒有事件」——記憶層是不可重建的資料，安靜地少讀幾筆比讀不出來更糟。
    ///
    /// 但那個預設有個代價，#1 verify R3 指出來了：一次半途中斷的 append 留下
    /// 一行壞資料，**整份 canonical store 從此讀不出來**。所以另外提供
    /// `skippingCorrupt: true`——它不會被排序或計分路徑呼叫，只給修復情境用：
    /// 讀得回來的部分先救出來，同時**明確回報跳過了哪幾行**，讓「損壞侷限在
    /// 那一筆」成為可觀察的事實而不是註解裡的宣稱。
    public func allEvents(skippingCorrupt: Bool) throws -> (events: [Event], corruptLines: [Int]) {
        let bytes: Data
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return ([], []) }
            bytes = try Data(contentsOf: url)
        } catch {
            throw EventStoreError.readFailed(path: url.path, underlying: "\(error)")
        }

        let decoder = JSONDecoder()
        var result: [Event] = []
        var corrupt: [Int] = []
        for (index, line) in String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).enumerated()
        {
            do {
                result.append(try decoder.decode(Event.self, from: Data(line.utf8)))
            } catch {
                guard skippingCorrupt else {
                    throw EventStoreError.corruptRecord(path: url.path, lineNumber: index + 1)
                }
                corrupt.append(index + 1)
            }
        }
        return (result, corrupt)
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
