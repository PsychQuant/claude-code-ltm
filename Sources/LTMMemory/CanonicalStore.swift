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
    public static func validatedPath(
        _ url: URL, policy: any CorpusContainmentPolicy = CorpusPolicy()
    ) throws -> URL {
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
        // **經 policy 而不是直接呼叫預設根版本**（#27）：語料根可被覆寫，而
        // library 層不知道它被覆寫到哪。
        guard !policy.isInsideReadOnlyCorpus(absolute) else {
            throw EventStoreError.pathInsideReadOnlyCorpus(path: absolute.path)
        }
        // **檔案 0o600 擋不住一個誰都能寫的目錄**（#1 verify R5）。權限檢查
        // 先前只在 `append` 裡、只看檔案本身；而在 group/other 可寫的目錄裡，
        // 任何人都能把那個檔案換掉、rename 掉、或先建一個自己的版本。
        // 記憶層是本專案唯一必須備份的資料，這個檢查值得在建構時就做。
        //
        // sticky bit 例外：`/tmp` 是 1777，而 sticky 讓非擁有者無法 unlink 或
        // rename 別人的**既有**檔案。
        //
        // **它擋的只有這個**（#20 item 4 更正了先前寫在這裡的理由）。sticky
        // **不擋建立**，而 `open` 目前沒有 `O_NOFOLLOW`——所以在檔案還不存在時，
        // 別人仍然可以先放一個 symlink 到那個位置。上面的擁有者檢查涵蓋了
        // 大部分情形（別人擁有的目錄一律拒絕），剩下的 TOCTOU 窗口追蹤於 #40：
        // **在那之前，這條守衛防的是意外，不是攻擊者。**
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
        // **`stat` 失敗要拒絕，不是跳過**（#20 item 4）。先前是
        // `if stat(...) == 0 { … }`，於是 stat 失敗時整段檢查被略過而路徑照樣
        // 放行——一個「查不到就當作安全」的守衛，方向錯得跟沒有守衛一樣。
        var info = stat()
        guard stat(parent, &info) == 0 else {
            throw EventStoreError.insecureDirectory(path: parent)
        }

        // **目錄必須是自己的**（#20 item 4）。先前只看寫入位元：一個
        // 0755、但屬於別人的目錄會通過，而那個人隨時能換掉整條路徑。
        guard info.st_uid == getuid() else {
            throw EventStoreError.insecureDirectory(path: parent)
        }

        let worldOrGroupWritable = (info.st_mode & (S_IWGRP | S_IWOTH)) != 0
        let sticky = (info.st_mode & S_ISVTX) != 0
        guard !worldOrGroupWritable || sticky else {
            throw EventStoreError.insecureDirectory(path: parent)
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
        // `O_NOFOLLOW` 與下面的 `ExclusiveFile.verify` 是同一件事的兩半。
        //
        // `O_APPEND` 不截短，所以這裡的傷害比 `pruneUnusable` 小——但把事件行
        // append 進一個 hard link 成語料檔的 `events.jsonl` **仍然是寫進語料**
        // （不變式 1），而且那些行會混進第三方的逐字內容裡。#44 R9 verify 量到的
        // 是 prune 那一條，這一條是同族、同一個修法。
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NONBLOCK | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw EventStoreError.appendFailed(
                path: url.path, underlying: "open 失敗：errno \(errno)（目錄可寫嗎？）")
        }
        do { try ExclusiveFile.verify(descriptor: fd, path: url.path) } catch {
            close(fd)
            let rejection = error as? ExclusiveFile.Rejection
            throw EventStoreError.appendFailed(
                path: url.path,
                underlying: (rejection?.reason ?? "\(error)")
                    + "——記憶層只寫我們自己的檔案")
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
        //
        // ## 逾時後**失敗**，而讀取端逾時後**照讀**——不對稱是刻意的（#42）
        //
        // 判準只有一句：**沒拿到鎖就繼續，代價是什麼？**
        //
        // | | 沒拿到鎖仍繼續 | 所以 |
        // |---|---|---|
        // | 讀取 | 可能讀到進行中 append 的半行，把一筆好紀錄回報成損壞 | 診斷噪音，不丟資料 → 照讀 |
        // | 寫入 | 與另一個寫入者的多次 `write` 交錯，**真的弄壞** canonical 檔 | 不可接受 → 必須不繼續 |
        //
        // 寫入端既然不能繼續，剩下的選擇只有「永遠等」與「失敗」。永遠等就是
        // 重新引入 non-termination，而本 repo 已經被那個類別咬過三次（交錯迴圈、
        // NaN 迴圈、FIFO open）。所以是失敗。
        //
        // **失敗是看得見的**：錯誤一路傳到呼叫端，而目前兩個寫入端都是使用者
        // 自己下的 CLI 命令（`ltm query --record`、`ltm mark`）——重送機制就是
        // 那個人。這一點會隨著出現非互動的寫入端而改變，屆時要重新決定；
        // **不要把「有人會看到錯誤」當成一條永久成立的性質。**
        //
        // 讀取端的逾時另有一件事值得寫下來，因為它曾經是拒絕這個設計的理由：
        // 「修復工具照著 `corruptLines` 去刪，刪掉的是一筆好紀錄」。那條路徑
        // **已經結構性關掉**——`pruneUnusable` 自己開 fd、取**阻塞的** `LOCK_EX`、
        // 在那把鎖之下重新計算它要丟哪幾行，從不消費這裡的讀取結果。會刪東西的
        // 那條路徑不吃可能被撕裂的讀。
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
        //
        // **只有能力不足才退回**（#20 item 2）。先前是「任何 errno 都退回」，
        // 於是 `EIO` 這種真正的 IO 錯誤也走同一條路：裝置根本沒把資料寫下去，
        // 而我們用一個較弱的 `fsync` 蓋過它、回報成功。退回的理由是「這個平台
        // 做不到更強的保證」，不是「這次寫入失敗了」——兩者混在一起，後者就
        // 永遠不會被看見。
        try syncToDevice(fd: fd, path: url.path)

        // **新建檔案時，目錄項本身也要落盤。** 只 fsync 檔案而不 fsync 目錄，
        // 斷電後可能出現「檔案內容在、但目錄裡沒有這個名字」。成本是一次
        // syscall，且只在這條路徑上。
        try fsyncDirectory(of: url)
    }

    /// 把一個 fd 的內容真正推到裝置上。
    ///
    /// **一個寫者**（#31）：`appendLine` 與 `FileEventStore.pruneUnusable` 先前各有
    /// 一份，而 prune 那份是純 `fsync`——同一份持久性規格的兩個實作，其中一個弱。
    static func syncToDevice(fd: Int32, path: String) throws {
        // `F_FULLFSYNC` 在某些檔案系統／掛載上回 ENOTSUP，那時退回 `fsync`
        // ——那是平台能力的限制，不是我們的錯誤，但要退得明白而不是靜默。
        //
        // **只有能力不足才退回**（#20 item 2）。先前是「任何 errno 都退回」，
        // 於是 `EIO` 這種真正的 IO 錯誤也走同一條路：裝置根本沒把資料寫下去，
        // 而我們用一個較弱的 `fsync` 蓋過它、回報成功。
        guard fcntl(fd, F_FULLFSYNC) != 0 else { return }
        let fullsyncErrno = errno
        switch fullsyncErrno {
        case ENOTSUP, EINVAL, EOPNOTSUPP:
            guard fsync(fd) == 0 else {
                throw EventStoreError.appendFailed(
                    path: path, underlying: "fsync 失敗：errno \(errno)（資料可能未落盤）")
            }
        default:
            throw EventStoreError.appendFailed(
                path: path,
                underlying: "F_FULLFSYNC 失敗：errno \(fullsyncErrno)（資料可能未落盤）")
        }
    }

    /// 讓一個檔案的**目錄項**落盤。
    ///
    /// 只 fsync 檔案不 fsync 目錄，斷電後可能出現「檔案內容在、但目錄裡沒有這個
    /// 名字」。對備份檔而言那正好是它要防的那個窗口（#31）。
    static func fsyncDirectory(of url: URL) throws {
        // **解析後的父層，不是字面的**（#20 item 3）。葉節點是 symlink 時，
        // 字面父層是「連結所在的目錄」，而目錄項實際建立在**目標所在的目錄**。
        // 同一個檔案裡的權限檢查早就改用 `fullyResolve` 了，這裡落後約 140 行
        // ——literal-vs-resolved 是這個檔案已經被咬過一次的同一個 bug。
        let resolvedFile = CorpusLocation.fullyResolve(url.path) ?? url.path
        let dirPath = URL(fileURLWithPath: resolvedFile).deletingLastPathComponent().path
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

        // **逾時後照讀**（#42）。與 `appendLine` 的「逾時後失敗」不對稱，理由寫在
        // 那裡：讀取沒拿到鎖仍繼續的代價只是「可能把一筆好紀錄回報成損壞」，
        // 而寫入的代價是真的弄壞檔案。有界等待買的是前者的機率下降；完全不等
        // 會讓它變成常態，等到天荒地老則換不到任何額外保證。
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
