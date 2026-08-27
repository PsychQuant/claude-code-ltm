import Foundation

/// 一個**已經開啟的 fd** 指向的東西，是不是「我們自己的、只有一個名字的一般檔案」。
///
/// ## 為什麼住在 `LTMCore`
///
/// 索引層與記憶層各自有一份會**截短或覆寫**檔案的路徑，而兩層都需要同一組檢查。
/// 先前只有索引層有（`LTMIndex` 的 `verifyExclusivelyOurs`），記憶層被一句
/// 「它有自己的守衛與自己的威脅模型（#40）」排除在外——**那句話是我寫的，而且
/// 沒有量過**（#44 R9 verify，security lens 與 devil's advocate 各自實測）：
///
/// ```
/// $ ln <corpus>/proj-x/session-1.jsonl <memroot>/memory/events.jsonl
/// $ ltm memory --prune --force
///   ✓ 已備份原檔：events.jsonl.bak-5CADB437
///   ✓ 保留 0 筆可用紀錄，丟掉 40 筆
/// BEFORE size=12510 nlink=2 ino=610865743
/// AFTER  size=0     nlink=2 ino=610865743      ← 同一個 inode，語料歸零
/// ```
///
/// **違反不變式 1，而且印的是「✓」。** 而第二個傷害更難看：那份備份把語料的
/// 逐字內容原封不動寫進 `~/.claude-ltm/memory/`——CLAUDE.md 對記憶層的硬約束
/// 逐字寫著「如此它**即使被備份或同步**也不含第三方逐字內容」，而這條路徑一次
/// 就打穿它，打穿的方式正好是「備份」。使用者是照著 CLI 自己印的指示走到那裡的。
///
/// ## 為什麼 #40 的排除不成立
///
/// #40 接受 hardlink 的理由是**成本**：它是純路徑判定，手上沒有 fd，要擋得列舉
/// 語料樹內所有 inode。而 `pruneUnusable` **已經拿到 fd 而且已經在 `fstat` 它**
/// ——它只查了 `S_IFREG`，缺的就是下面這兩行。
///
/// 這個論證不是新的：它逐字寫在 `LTMIndex` 那份檢查的文件裡，是我五輪前為了
/// 補索引層那一半而寫的。**我寫下了那個論證，然後用被它推翻的理由排除了記憶層。**
///
/// ## 誠實邊界
///
/// 消除的是「路徑在檢查與開檔之間被換掉」那一類（fd 已綁定 inode）。**不**消除
/// 「inode 的 link count 在 `fstat` 之後改變」——`st_nlink` 是可變狀態，這裡沒有
/// 機制凍結它。那一條在 #40 的模型下是被接受的限度。
public enum ExclusiveFile {
    public struct Rejection: Error, Sendable, Equatable {
        public let path: String
        public let reason: String
        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// 三個條件，各自擋不同的東西：
    ///   `S_IFREG`  —— 不是 FIFO／device／socket
    ///   `st_nlink` —— 沒有第二個名字指向同一個 inode（hard link）
    ///   `st_uid`   —— 是我們建的
    public static func verify(descriptor: Int32, path: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw Rejection(path: path, reason: "fstat 失敗：\(String(cString: strerror(errno)))")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw Rejection(path: path, reason: "它不是一般檔案")
        }
        guard info.st_nlink == 1 else {
            throw Rejection(
                path: path, reason: "有 \(info.st_nlink) 個名字指向同一個檔案（hard link）")
        }
        guard info.st_uid == getuid() else {
            throw Rejection(
                path: path, reason: "擁有者是 uid \(info.st_uid)，不是你（uid \(getuid())）")
        }
    }
}
