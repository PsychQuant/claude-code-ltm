import Foundation
import LTMCore

/// canonical 存放檔的**共用機制**：路徑守衛、原子 append、受檢讀取。
///
/// ## 為什麼抽出來
///
/// 記憶層現在有兩個 canonical 存放檔：使用歷史（`events.jsonl`）與交錯呈現的
/// 紀錄（`presentations.jsonl`）。兩者的落地要求逐字相同——不得落在唯讀語料內、
/// 目錄不得 group／other 可寫（除非 sticky）、append 必須在 `flock` 內完成整個
/// write 迴圈、必須 `F_FULLFSYNC`、讀取必須在同一個 fd 上驗形加共享鎖。
///
/// 這些條款每一條都是某次 verify 抓出來的具體缺陷（行內註解逐一標了輪次）。
/// **把它們複製第二份，就是複製一份會漂移的規格**——而漂移的方向是「新的那份
/// 少了其中一條」，那正是 CLAUDE.md 記著的「同一件事有兩個寫者」。所以機制住在
/// 這裡，`FileEventStore` 與 `FilePresentationRecordStore` 都只是它的呼叫端。
///
/// ## 錯誤型別沿用 `EventStoreError`
///
/// 它的 case 描述的是**存放檔**的失敗（append 失敗、read 失敗、路徑落在語料內、
/// 目錄不安全），不是事件特有的失敗。換一個名字要動 CLI 與既有測試的每個
/// 比對點，而換來的只是名稱貼切——不划算。
public enum CanonicalStore {

    /// 驗證一條 canonical 存放路徑，回傳它的絕對形式。
    ///
    /// 呼叫端在**建構時**呼叫它：落在唯讀語料內 → throw，不給「先建起來再說」的機會。
    ///
    /// 先正規化成絕對路徑再檢查：相對 URL 會讓守衛檢查的字串與 `open()` 實際
    /// 走的路徑**不是同一條**（守衛看 `pathComponents`，kernel 看 cwd + 相對路徑），
    /// 於是檢查通過而寫入落在別處（#1 verify R3）。
    public static func validatedPath(_ url: URL) throws -> URL {
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
        return absolute
    }

    /// 把一行（已編碼、含結尾換行）原子地附加到存放檔。
    ///
    /// 編碼由呼叫端負責——這一層只認 bytes，因為它要保證的性質（原子性、
    /// 落盤、權限）與被寫的是哪一種紀錄無關。
    public static func appendLine(_ line: Data, to url: URL) throws {

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
        // 「損壞侷限」成立的是讀取端的 `allEvents(skippingUnusable:)`——見該方法。
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
    /// 開啟、驗形、上共享鎖、從**同一個 fd** 讀完。
    ///
    /// 三件事必須在同一個 descriptor 上完成，否則檢查與讀取看的是不同的東西：
    /// `O_NONBLOCK` 讓 FIFO 的 open 立刻失敗而不是掛住、`fstat` 確認是一般檔案、
    /// 共享鎖避免讀到進行中的 append 半行。
    public static func readRegularFile(at url: URL) throws -> Data {
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
}
