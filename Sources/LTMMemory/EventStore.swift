import Foundation
import LTMCore

/// canonical 使用歷史的存放介面。
///
/// 只有 append 與 range read。**刻意沒有** update／delete 單筆事件的操作：
/// 記憶層記的是「發生過什麼」，事後修改單筆紀錄等於改寫歷史，而不是修正
/// 一個可重算的衍生值。
///
/// **這個 protocol 沒有例外；具體實作有一個，而它刻意不在這裡。**
/// `FileEventStore.pruneUnusable()` 會移除**讀不回來**的紀錄（解不開的、舊定址
/// 規則寫的）。它不在 protocol 上，因為那不是「存放介面」的能力而是修復工具的
/// 能力——寫在這裡會讓每一個 `EventStore` 的使用者都拿得到一個刪除操作，而
/// 「誰能刪」正是這條 requirement 要限制的東西。邊界寫在
/// `memory-events` spec 的 MODIFIED requirement 裡：只能刪讀不回來的、不得接受
/// 呼叫端指定哪一筆、鎖內完成、不得換 inode。
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
    /// 紀錄的 anchor source 是被取代的規則產生的。
    ///
    /// **具名拒絕，不重新詮釋**：指紋不帶產生它的規則，把舊值拿去跟新規則比對，
    /// 要嘛解析到錯的 turn、要嘛報成 orphan，而兩者都與正確行為分不出來。
    case supersededAnchorRule(path: String, lineNumbers: [Int])
    /// 存放目錄是 group／other 可寫且沒有 sticky bit。
    ///
    /// 檔案本身 0o600 在這種目錄裡保護不了什麼：別人換掉整個檔案即可。
    case insecureDirectory(path: String)
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
    /// **身分比對用 `(st_dev, st_ino)`，不是路徑元件**（#1 verify R5）。
    ///
    /// 路徑元件比對假設「同一個目錄只有一條絕對路徑」，而 macOS 上那是假的：
    /// firmlink 讓 `~/.claude/projects` 與
    /// `/System/Volumes/Data/Users/…/.claude/projects` 是**同一個 inode 的兩條
    /// 穩定路徑**，且 `realpath(3)` 不會把後者正規化掉。R5 實測：守衛對後者
    /// 判「在語料外」，建構子照收，而寫進去的檔案出現在 `~/.claude/projects/`
    /// ——不變式 1 被違反且沒有任何錯誤。
    ///
    /// 這不是 hardlink 也不是 TOCTOU，所以先前那段誠實邊界的封閉列舉**漏了它**
    /// ——而且漏掉的案例逐字否證它自己的第一個 bullet（「擋得住直接指進語料的
    /// 路徑」）。改用 inode 身分之後，「同一個目錄的另一條路徑」這整類一次擋掉，
    /// 不論它是 firmlink、bind mount 還是我還沒遇過的機制。
    ///
    /// **誠實邊界（縮小後）：**
    ///
    /// - **擋得住**：任何解析後落在語料樹內的路徑，不論用哪條路徑抵達；`..`
    ///   穿過 symlink；單層與多層 dangling symlink 鏈；相對路徑。
    /// - **擋不住指向語料檔的 hardlink。** 它的父目錄在語料樹外，往上走永遠碰
    ///   不到語料根；而 hardlink 與原檔在檔案系統層無法區分。要擋得列舉語料樹
    ///   內所有 inode，成本與收益不成比例。
    /// - **擋不住 TOCTOU。** 檢查與開檔之間任何一段都可能被換掉。
    /// - **語料根不存在時退回元件比對**：沒有 inode 可比。此時它只擋字面前綴。
    ///
    /// 後兩者的結構解是 `openat` + `O_NOFOLLOW` 逐段開 + `fstat`，需要重寫
    /// append 路徑，追蹤於 #14。**在那之前，這條守衛防的是意外，不是攻擊者。**
    public static func isInsideReadOnlyCorpus(_ url: URL) -> Bool {
        isInside(url, root: readOnlyRoot)
    }

    /// 同上，但語料根可指定。
    ///
    /// 存在的理由是測試（#1 verify R5）：一條守衛測試因為依賴真實語料樹當下的
    /// 內容而退化成恆真斷言，可注入的根讓它能在合成樹上寫成無條件斷言。
    ///
    /// **目前只有兩條測試用合成根**（#1 verify R6 更正了這裡先前寫的「行為測試
    /// 全部在合成樹上跑」）。其餘九條仍以真實 `~/.claude/projects` 為標的——
    /// 它們只做路徑判斷與 symlink 佈局，不寫入語料，但確實碰真實路徑。
    /// 要全部搬到合成樹，`FileEventStore.init` 也得能收語料根（目前它直接用
    /// `CorpusLocation.readOnlyRoot`），那是介面改動，追蹤於 #14。
    /// 公開可見（原為 internal）：`LTMService.MemoryCorpusPolicy` 需要對**當下實際
    /// 使用的**語料根做同一份判定。複製這段邏輯是不可接受的替代方案——它被
    /// symlink、`..`、dangling link、firmlink 各咬過一次，兩份實作必然漂移，
    /// 而漂移的方向是「放行了不該放行的路徑」且不報錯。
    public static func isInside(_ url: URL, root: URL) -> Bool {
        // 解析不出來 → **當成在裡面**（fail closed）。不變式 1 的方向是
        // 「不確定就不要寫」，而不是「不確定就放行」。
        guard let resolved = Self.fullyResolve(url.path) else { return true }

        if let rootID = Self.identity(root.path) {
            // 從解析後的目標往上走：任何一層與語料根同 inode 就是在裡面。
            // 目標檔案通常還不存在（append 會建它），所以第一次 stat 失敗是正常的，
            // 迴圈自然往上走到最近的存在祖先。
            var current = URL(fileURLWithPath: resolved)
            var depth = 0
            while depth < 256 {
                if let id = Self.identity(current.path), id == rootID { return true }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
                depth += 1
            }
        }

        // 語料根不存在（或走到根都沒對上）→ 元件比對當第二層。
        // 用元件而非字串前綴：`/a/bc` 不該被 `/a/b` 判成在內。
        let rootPath = Self.realpath(root.path) ?? root.path
        let rootParts = URL(fileURLWithPath: rootPath).pathComponents
        let targetParts = URL(fileURLWithPath: resolved).pathComponents
        guard targetParts.count >= rootParts.count else { return false }
        return Array(targetParts.prefix(rootParts.count)) == rootParts
    }

    /// 檔案系統身分。`nil` 代表這條路徑目前不存在。
    static func identity(_ path: String) -> (dev: dev_t, ino: ino_t)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }

    /// 把路徑解析成 kernel 實際會走到的最終位置。
    ///
    /// **不再用字串模擬 kernel 的路徑解析。** 這條前後改了四次（R2 修 `..`、
    /// R3 修單層 dangling、R4 修多層鏈），每一次都是「補上我這次想到的 symlink
    /// 擺法」，而每一次 verify 都找到新的擺法——R4 一口氣量到四種穿透，包括
    /// 「dangling 目標的父層是 symlink」與「目標裡含 `..`」。根因是同一個：
    /// **用字串近似一個由 kernel 定義的操作，近似永遠會漏。**
    ///
    /// 改法是把解析交給 `realpath(3)`——它就是 kernel 的解析器。因為目標檔案
    /// 通常還不存在（append 會建它），所以拆成兩段：父目錄交給 realpath 完整
    /// 解析，最後一段自己處理 symlink（含 dangling，遞迴且有上限）。
    static func fullyResolve(_ path: String, depth: Int = 0) -> String? {
        guard depth < 40 else { return path }  // SYMLOOP_MAX 量級；迴圈時停手
        let absolute =
            path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        let url = URL(fileURLWithPath: absolute)
        let parent = url.deletingLastPathComponent().path
        let base = url.lastPathComponent

        // 父目錄必須解析成 kernel 真正會走到的目錄。它若不存在，往上遞推。
        guard let realParent = Self.realpath(parent) else {
            guard parent != "/" , parent != absolute else { return absolute }
            guard let resolvedParent = Self.fullyResolve(parent, depth: depth + 1) else { return nil }
            return resolvedParent + "/" + base
        }

        let candidate = realParent == "/" ? "/" + base : realParent + "/" + base

        // 最後一段自己看：它可能是 symlink（含 dangling），而 realpath 對不存在
        // 的路徑不作用。
        var info = stat()
        if lstat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK,
            let target = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate)
        {
            let next = target.hasPrefix("/") ? target : realParent + "/" + target
            return Self.fullyResolve(next, depth: depth + 1)
        }
        return candidate
    }

    private static func realpath(_ path: String) -> String? {
        guard let c = Darwin.realpath(path, nil) else { return nil }
        defer { free(c) }
        return String(cString: c)
    }

}

/// JSON Lines 檔案實作。
///
/// 一行一筆、只 append：這個格式讓 append-only 成為檔案層的事實，而不只是
/// API 層的約定。
public struct FileEventStore: EventStore {
    public let url: URL

    /// 建構即檢查路徑。落在唯讀語料內 → throw，不給呼叫端「先建起來再說」的機會。
    ///
    /// 先正規化成絕對路徑再檢查：相對 URL 會讓守衛檢查的字串與 `open()` 實際
    /// 走的路徑**不是同一條**（守衛看 `pathComponents`，kernel 看 cwd + 相對路徑），
    /// 於是檢查通過而寫入落在別處（#1 verify R3）。
    public init(url: URL) throws {
        // **只補絕對路徑，不做正規化。** `standardizedFileURL` 會把 `..` 字面
        // 消解，而 `..` 在 symlink 之後的語意是「解析後那個目錄的父層」——
        // 用它等於重新引入 R2 修掉的那個穿透（我第一版就這樣寫，被
        // `dotDotThroughASymlinkCannotEscapeTheGuard` 當場抓到）。
        // `..` 交給守衛的逐段解析處理，那裡才處理得對。
        let absolutePath =
            url.path.hasPrefix("/")
            ? url.path
            : FileManager.default.currentDirectoryPath + "/" + url.path
        let absolute = URL(fileURLWithPath: absolutePath)
        guard !CorpusLocation.isInsideReadOnlyCorpus(absolute) else {
            throw EventStoreError.pathInsideReadOnlyCorpus(path: absolute.path)
        }
        // **檔案 0o600 擋不住一個誰都能寫的目錄**（#1 verify R5）。權限檢查
        // 先前只在 `append` 裡、只看檔案本身；而在 group/other 可寫的目錄裡，
        // 任何人都能把那個檔案換掉、rename 掉、或先建一個自己的版本。
        // 記憶層是本專案唯一必須備份的資料，這個檢查值得在建構時就做。
        //
        // sticky bit 例外：`/tmp` 是 1777，但 sticky 讓非擁有者無法 unlink
        // 別人的檔案，所以那個組合是可接受的。
        // **用解析後的路徑取父目錄。** 同一個 initializer 裡兩個檢查先前看的是
        // 不同的路徑：`isInsideReadOnlyCorpus` 走 `fullyResolve`（會解析最後一段
        // 的 symlink），而這裡用 `deletingLastPathComponent()`——純字面。於是
        // `~/ltm/events.jsonl` 是個指向 `/tmp/pub/events.jsonl` 的 symlink 時，
        // 檢查的是 0700 的 `~/ltm`，而 `open` 跟著連結寫進非 sticky 的
        // world-writable 目錄——正是這個檢查本輪要擋的組態（#1 verify R6）。
        let resolvedForPermissions =
            CorpusLocation.fullyResolve(absolute.path) ?? absolute.path
        let parent = URL(fileURLWithPath: resolvedForPermissions)
            .deletingLastPathComponent().path
        var info = stat()
        if stat(parent, &info) == 0 {
            let worldOrGroupWritable = (info.st_mode & (S_IWGRP | S_IWOTH)) != 0
            let sticky = (info.st_mode & S_ISVTX) != 0
            guard !worldOrGroupWritable || sticky else {
                throw EventStoreError.insecureDirectory(path: parent)
            }
        }
        self.url = absolute
    }

    /// 每次呼叫新建 encoder。
    ///
    /// 先前是 `private static let`——跨呼叫共享的 reference type，而
    /// `EventStore: Sendable` 等於承諾可以並行呼叫。`JSONEncoder` 在此沒有任何
    /// 序列化保護，那個 `Sendable` 是假的（#1 verify R3）。新建一個 encoder 的
    /// 成本遠低於「canonical 歷史被兩個執行緒寫壞」的成本。
    /// 與讀取端的 bytes 比對**共用同一個**編碼器——那是比對能成立的前提。
    private var encoder: JSONEncoder { CanonicalCoding.encoder }

    public func append(_ event: Event) throws {
        let line: Data
        do {
            line = try encoder.encode(event) + Data("\n".utf8)
        } catch {
            throw EventStoreError.appendFailed(path: url.path, underlying: "\(error)")
        }

        // `seekToEnd` + `write` 是兩個 syscall，中間可被其他行程插入 → 互相覆寫
        // canonical history（#1 verify）。改用 O_APPEND：核心保證「移到檔尾」與
        // 「寫入」對一般檔案是原子的。
        //
        // **但那只保證單一 `write(2)`，不保證下面那個迴圈**（#1 verify R5，
        // codex 與 logic 各自指出）。一筆事件可能要多次 write 才寫完（short
        // write，或 `EINTR` 發生在部分傳輸之後——程式碼自己用 `wroteAnything`
        // 承認了這件事）。兩次 write 之間另一個行程 append 一整行，結果是
        // 第一行 = A 的前綴 + B 的整行、第二行 = A 的後綴，**兩筆都壞**。
        // 先前那句「多行程並行 append 因此安全」是過度宣稱。
        //
        // 修法是把整個 write 迴圈 + 封口 + fsync 包進 `flock(LOCK_EX)`。
        // 誠實邊界：`flock` 是**協同式**的——不用 flock 的寫入者不受它約束，
        // 而 NFS 上的行為依實作而異。它擋的是「本專案自己的多個行程」，
        // 不是任意寫入者。
        // 權限 0o600：記憶層是本專案唯一必須備份的資料，不該是 world-readable。
        // `O_NONBLOCK` 是為了讓下面的 `fstat` 檢查**真的有機會執行**。
        // #1 verify R4 的 CRITICAL：對一個沒有讀者的 FIFO，`open(O_WRONLY)`
        // 會永久阻塞——檢查寫在 open 之後，所以「一併拒絕非一般檔案」那句話
        // 對 FIFO 是假的，實際行為是掛住。
        //
        // 更難堪的是我**已經知道**這個阻塞行為：刪掉那條假測試時我親手寫下
        // 「FIFO 的 open(O_WRONLY) 無讀者時會阻塞」，卻只當成測試成本問題，
        // 沒認出它同時代表生產程式碼會掛住。non-termination 是 R1 與 R3 各抓過
        // 一次的 failure class，這是第三次。
        //
        // 對一般檔案 `O_NONBLOCK` 對讀寫語意無影響，所以不必事後清掉。
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK, 0o600)
        guard fd >= 0 else {
            throw EventStoreError.appendFailed(
                path: url.path, underlying: "open 失敗：errno \(errno)（目錄可寫嗎？）")
        }
        // durability：回傳成功必須代表**已落盤**。protocol 的註解寫「無法持久化時
        // 必須拋出——記憶層與索引不同，掉了就回不來」，但先前只涵蓋 `write` 失敗，
        // 不涵蓋「還在 page cache、斷電就沒了」（#1 verify R3）。
        // fsync 失敗同樣要拋——那正是「寫不進去」的一種。
        defer { close(fd) }

        // 跨行程互斥，涵蓋整個 write 迴圈。**非阻塞 + 有界重試**：
        // `LOCK_EX` 單獨使用會無限期停在 flock 裡，而那正是這個 change 已經
        // 撞過三次的 non-termination 類別（交錯迴圈、NaN 迴圈、FIFO open）
        // ——上一輪對 FIFO 的修法是給 `open` 加 `O_NONBLOCK`，而兩行之下新加的
        // 鎖又把它引回來，且註解寫著「取不到鎖就拋」這個 code 沒有的性質
        // （#1 verify R6）。
        //
        // 上限刻意小（約 2 秒）：append 是短操作，等超過這個量級代表對方卡住，
        // 而卡住時回一個錯誤遠好過跟著卡住。
        var lockAttempts = 0
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, lockAttempts < 200 else {
                throw EventStoreError.appendFailed(
                    path: url.path, underlying: "flock 失敗：errno \(errno)")
            }
            lockAttempts += 1
            usleep(10_000)  // 10ms
        }
        defer { flock(fd, LOCK_UN) }

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

        // **macOS 上 `fsync` 不保證裝置真的把資料寫下去**——它只把資料交給
        // 驅動器，斷電仍可能丟失。`F_FULLFSYNC` 才會要求裝置 flush 它自己的
        // 快取。protocol 的註解寫「回傳成功必須代表已落盤」，先前只有 `fsync`
        // 撐不起那句話（#1 verify R6）。
        //
        // `F_FULLFSYNC` 在某些檔案系統／掛載上回 ENOTSUP，那時退回 `fsync`
        // ——那是平台能力的限制，不是我們的錯誤，但要退得明白而不是靜默。
        if fcntl(fd, F_FULLFSYNC) != 0 {
            guard fsync(fd) == 0 else {
                throw EventStoreError.appendFailed(
                    path: url.path, underlying: "fsync 失敗：errno \(errno)（資料可能未落盤）")
            }
        }

        // **新建檔案時，目錄項本身也要落盤。** 只 fsync 檔案而不 fsync 目錄，
        // 斷電後可能出現「檔案內容在、但目錄裡沒有這個名字」。成本是一次
        // syscall，且只在這條路徑上。
        let dirPath = url.deletingLastPathComponent().path
        let dirFD = open(dirPath, O_RDONLY)
        if dirFD >= 0 {
            defer { close(dirFD) }
            _ = fsync(dirFD)
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
    /// 的語意完全不是「附加一筆歷史」。這條要成立，開檔必須帶 `O_NONBLOCK`
    /// ——否則對無讀者的 FIFO 會停在 `open` 而永遠走不到這裡（見呼叫端）。
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
    /// 丟掉**讀不回來**的紀錄，把其餘寫回去；回傳保留幾筆與丟掉哪幾行。
    ///
    /// ## 為什麼是「讀→篩→寫」一次做完，而不是收一份 `keeping` 清單
    ///
    /// 先前的簽章是 `rewrite(keeping: [Event])`，呼叫端先讀一次、篩完再交回來。
    /// 那有兩個問題，第二個是致命的：
    ///
    /// 1. **read-modify-write race**：讀取結束後共享鎖就放掉了，到寫回為止的任何
    ///    一筆 `append`（`ltm query --record`、Stage 2 的 MCP server）都會被丟掉。
    ///    #24 的整個目的就是讓多個 session 同時用它，所以這不是理論情形。
    /// 2. **它是「刪掉任意一筆事件」的公開 API**。`memory-events` 的既有
    ///    requirement 逐字寫「It SHALL NOT expose an operation that updates or
    ///    deletes an individual event」——`rewrite(keeping: events.filter { $0 != x })`
    ///    正是那個操作。
    ///
    /// 現在的形狀兩個問題一起消失：篩選規則寫死在**這裡**（只丟讀不回來的），
    /// 呼叫端無法指定丟哪一筆；而讀與寫在**同一個 fd 的同一段 `LOCK_EX` 內**完成，
    /// 中間沒有窗口。
    ///
    /// ## 為什麼不換 inode
    ///
    /// `flock` 綁在 inode 上。先前用 `write(to: temp)` + `replaceItemAt` 落地，
    /// 而那會換掉 inode——**實測**：另一個行程持有 `LOCK_EX` 時 replace 照樣成功，
    /// 接著那個持鎖者的 `write(2)` 落進已被 unlink 的舊 inode，資料沒有任何錯誤
    /// 地消失。所以這裡用 `ftruncate` + 就地覆寫。
    ///
    /// ## 代價，寫明
    ///
    /// 就地覆寫**不是原子的**：崩在 truncate 與 write 之間會留下半份檔案。這是
    /// 拿原子性換鎖的正確性，而崩潰窗口由呼叫端的備份覆蓋——`ltm memory --prune`
    /// 在呼叫這裡之前一定先備份。兩者相比，並發靜默丟資料比崩潰窗口糟得多：
    /// 前者無聲、日常可達，後者有備份且需要剛好崩在幾毫秒內。
    @discardableResult
    public func pruneUnusable() throws -> (kept: Int, corruptLines: [Int], supersededLines: [Int]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (0, [], []) }
        let fd = open(url.path, O_RDWR | O_NONBLOCK)
        guard fd >= 0 else {
            throw EventStoreError.readFailed(
                path: url.path, underlying: "open 失敗：errno \(errno)")
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw EventStoreError.readFailed(
                path: url.path, underlying: "不是一般檔案——拒絕而不是阻塞")
        }
        // **阻塞式 `LOCK_EX`**：這是使用者手動叫的維護命令，等一個進行中的 append
        // 結束是對的；`append` 用 `LOCK_NB` 是因為它在熱路徑上。
        guard flock(fd, LOCK_EX) == 0 else {
            throw EventStoreError.appendFailed(
                path: url.path, underlying: "取不到獨占鎖：errno \(errno)")
        }
        defer { flock(fd, LOCK_UN) }

        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { bytes.append(contentsOf: buffer[0..<n]) }
            else if n == 0 { break }
            else if errno == EINTR { continue }
            else {
                throw EventStoreError.readFailed(
                    path: url.path, underlying: "read 失敗：errno \(errno)")
            }
        }

        var kept: [Event] = []
        var corrupt: [Int] = []
        var superseded: [Int] = []
        for (index, line) in String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        {
            if line.isEmpty { continue }
            do {
                let event = try CanonicalCoding.decodeCanonicalLine(
                    Event.self, from: Data(line.utf8))
                guard ProjectFingerprint.hasCurrentRuleShape(event.anchor.source) else {
                    superseded.append(index + 1)
                    continue
                }
                kept.append(event)
            } catch {
                corrupt.append(index + 1)
            }
        }
        guard !corrupt.isEmpty || !superseded.isEmpty else { return (kept.count, [], []) }

        var payload = Data()
        for event in kept {
            payload.append(try encoder.encode(event))
            payload.append(Data("\n".utf8))
        }
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else {
            throw EventStoreError.appendFailed(
                path: url.path, underlying: "截斷失敗：errno \(errno)")
        }
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n }
                else if n < 0, errno == EINTR { continue }
                else {
                    throw EventStoreError.appendFailed(
                        path: url.path, underlying: "write 失敗：errno \(errno)")
                }
            }
        }
        guard fsync(fd) == 0 else {
            throw EventStoreError.appendFailed(
                path: url.path, underlying: "fsync 失敗：errno \(errno)")
        }
        return (kept.count, corrupt, superseded)
    }

    public func allEvents() throws -> [Event] {
        let result = try allEvents(skippingUnusable: false)
        guard result.supersededLines.isEmpty else {
            throw EventStoreError.supersededAnchorRule(
                path: url.path, lineNumbers: result.supersededLines)
        }
        return result.events
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
    /// - Parameter skippingUnusable: `true` 時跳過**兩類**不可用的紀錄並回報行號：
    ///   解不開的（`corruptLines`）與舊定址規則寫的（`supersededLines`）。
    ///
    ///   兩類分開回報，因為處置不同：損壞的那幾行是壞資料，舊規則的那幾行是**好
    ///   資料但指向已經不成立的定址方式**——後者的內容仍然是真的，只是解析不回去。
    ///
    ///   參數先前叫 `skippingCorrupt`，而舊規則紀錄並不損壞。一個名字說「跳過損壞」
    ///   卻也跳過沒壞的東西，是這個 repo 反覆踩到的名實不符。
    public func allEvents(skippingUnusable: Bool) throws
        -> (events: [Event], corruptLines: [Int], supersededLines: [Int])
    {
        let bytes: Data
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return ([], [], []) }
            // **讀取要取共享鎖。** 寫入端用 `flock` 協調，而讀取端先前完全不參與，
            // 於是一次進行中的 append（多次 write 之間）會被讀成損壞——修復工具
            // 照著 `corruptLines` 去刪，刪掉的是一筆好紀錄（#1 verify R6）。
            //
            // 取不到就照讀：讀取沒有正確性風險（最壞是看到半行並回報損壞，
            // 與先前行為相同），為它引入一個新的阻塞點不划算。
            //
            // **從這個 fd 讀，不要另開一次路徑**（#1 verify R7 的 CRITICAL）。
            // R6 開了一個 `O_NONBLOCK` 的 fd、在它上面取鎖，然後用
            // `Data(contentsOf: url)` **重新開啟**——新的 descriptor 既不保證
            // 非阻塞、也沒經過 `S_IFREG` 檢查。對 FIFO 而言那是無限阻塞：
            // 與同一輪為 `append` 修掉的 non-termination 是同一個 failure class
            // 的另一側，而那兩條 FIFO 測試只測了 `append`。
            bytes = try Self.readRegularFile(at: url)
        } catch {
            throw EventStoreError.readFailed(path: url.path, underlying: "\(error)")
        }

        var result: [Event] = []
        var corrupt: [Int] = []
        var superseded: [Int] = []
        // **不略過空行**（#1 verify R5）。舊版用 `omittingEmptySubsequences: true`，
        // 於是 `corruptLines` 回報的是「第幾個非空行」而不是「檔案第幾行」——
        // 每一個空行都會讓後面的行號往前偏。這個方法存在的全部理由是修復情境
        // （doc 逐字寫「明確回報跳過了哪幾行」），而照著偏掉的行號去編輯檔案
        // 會刪錯紀錄。空行是可達的：`terminatePartialLine` 在錯誤路徑會補一個
        // 裸 `\n`，而本 store 也從未宣稱自己是唯一的寫入者。
        for (index, line) in String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        {
            // 空行不是紀錄也不是損壞——它不解碼、也不計入 corruptLines，
            // 但**佔一個行號**，這才是行號有意義的前提。
            if line.isEmpty { continue }
            do {
                // **bytes 逐字比對**，不是單純解碼（#1 verify R5 的 CRITICAL）。
                // 解碼會靜默丟掉 JSON 文法允許而 schema 沒定義的東西——巢狀未知鍵、
                // 陣列多餘元素、重複鍵、`\uXXXX` 逃脫——而那些東西**留在檔案裡**。
                // 隱私硬約束的標的是落地的 bytes，所以檢查也必須在 bytes 上。
                let event = try CanonicalCoding.decodeCanonicalLine(
                    Event.self, from: Data(line.utf8))
                // 舊規則的 anchor 一律具名拒絕，**而且用真實檔案行號**。
                //
                // 這條檢查先前在 `allEvents()` 對解碼後的陣列做 `enumerated()`，
                // 於是回報的是「第幾筆事件」而不是「檔案第幾行」——每一個空行都讓
                // 後面的行號往前偏。同一個偏移在 `corruptLines` 上已經被修過一次
                // （#1 verify R5），而使用者拿到行號的唯一用途就是去編輯那個檔案。
                //
                // 放在讀取而不是寫入：寫入端產生的一定是當前規則，會出現舊值的只有
                // 「這個檔案是改規則之前寫的」。
                guard ProjectFingerprint.hasCurrentRuleShape(event.anchor.source) else {
                    superseded.append(index + 1)
                    continue
                }
                result.append(event)
            } catch {
                guard skippingUnusable else {
                    throw EventStoreError.corruptRecord(path: url.path, lineNumber: index + 1)
                }
                corrupt.append(index + 1)
            }
        }
        // 舊規則的紀錄**兩條讀取路徑都不會原樣交出去**。
        //
        // spec 的條款主語是 reading 而不是某一個方法，而「原樣交給呼叫端拿去對現行
        // 規則解析」正是它逐字禁止的 reinterpretation。修復路徑跳過它們並回報行號，
        // 嚴格路徑由呼叫端 `allEvents()` 具名拋錯——兩者都不重新詮釋。
        return (result, corrupt, superseded)
    }

    /// 開啟、驗形、上共享鎖、從**同一個 fd** 讀完。
    ///
    /// 三件事必須在同一個 descriptor 上完成，否則檢查與讀取看的是不同的東西：
    /// `O_NONBLOCK` 讓 FIFO 的 open 立刻失敗而不是掛住、`fstat` 確認是一般檔案、
    /// 共享鎖避免讀到進行中的 append 半行。
    static func readRegularFile(at url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            throw EventStoreError.readFailed(
                path: url.path, underlying: "open 失敗：errno \(errno)")
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw EventStoreError.readFailed(
                path: url.path, underlying: "不是一般檔案——拒絕讀取而不是阻塞")
        }

        var attempts = 0
        while flock(fd, LOCK_SH | LOCK_NB) != 0, errno == EWOULDBLOCK, attempts < 200 {
            attempts += 1
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }

        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                out.append(contentsOf: buffer[0..<n])
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw EventStoreError.readFailed(
                    path: url.path, underlying: "read 失敗：errno \(errno)")
            }
        }
        return out
    }

    /// 檔案的原始 bytes。給「序列化輸出不得含任何原文」那條測試用——
    /// 斷言要下在真正落地的 bytes 上，不是下在某個重新編碼過的複本上。
    public func serializedBytes() throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        // 走與 `allEvents` 同一條受檢查的讀取路徑——先前它直接
        // `Data(contentsOf:)`，連鎖都沒取，對 FIFO 同樣會阻塞（#1 verify R7）。
        return try Self.readRegularFile(at: url)
    }
}
