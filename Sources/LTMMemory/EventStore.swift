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
/// 語料圍籬的**實作**：預設根，加上呼叫端知道而 library 層不知道的實際根。
///
/// 判定本身住在 `CorpusLocation.isInside(_:root:)`，這裡只做「檢查哪些根」。
/// 兩者分開的理由是 #27：`FileEventStore` 先前直接呼叫固定預設根的版本，於是
/// `LTM_CORPUS_ROOT` 指到別處時，守衛檢查的是**錯的樹**——而放行的方向正是
/// 危險的那一邊（事件寫進唯讀語料）。
///
/// **預設根永遠檢查，額外根是加上去的**，不是取代。覆寫語料根不該放寬任何守衛。
public struct CorpusPolicy: CorpusContainmentPolicy {
    private let additionalRoots: [URL]

    public init(corpusRoots: [URL] = []) {
        self.additionalRoots = corpusRoots
    }

    public func isInsideReadOnlyCorpus(_ url: URL) -> Bool {
        if CorpusLocation.isInsideReadOnlyCorpus(url) { return true }
        return additionalRoots.contains { CorpusLocation.isInside(url, root: $0) }
    }
}

public enum CorpusLocation {
    /// 預設語料根。
    ///
    /// **認得 `CLAUDE_CONFIG_DIR`**（#20 item 5）。先前寫死 `$HOME/.claude`，
    /// 所以使用者搬過設定目錄之後，守衛看的是一個空目錄——「不得寫進語料」
    /// 這條保護整條靜默失效，而失效的方向是放行。
    ///
    /// 這是**預設值**，不是唯一的根：語料根還可以被 facade 覆寫（`CorpusPolicy`
    /// 的額外根，#27）。兩者都要檢查。
    public static var readOnlyRoot: URL {
        readOnlyRoot(
            configDirectory: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
            home: NSHomeDirectory())
    }

    /// 上面那個的**純函式版本**，環境由呼叫端給。
    ///
    /// 分出來是為了讓測試不必動 `CLAUDE_CONFIG_DIR`（#20 item 5 的測試原本會改
    /// 它）。那個環境變數是 **process 全域**的，而 swift-testing 預設平行跑，
    /// 所以一個改它的測試會讓**任何同時在讀 `readOnlyRoot` 的測試**看到被搬走
    /// 的根——實測：`multiHopDanglingSymlinkChainIsFollowedToTheEnd` 三次跑紅
    /// 一次。
    ///
    /// **偶爾成功的測試比偶爾失敗的更糟**（`CLAUDE.md`），而這裡兩者都會發生：
    /// 受害者偶爾紅，而改環境的那條在別人沒同時跑時偶爾綠得毫無根據。
    static func readOnlyRoot(configDirectory: String?, home: String) -> URL {
        let base =
            configDirectory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: home).appendingPathComponent(".claude")
        return base.appendingPathComponent("projects")
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
    /// append 路徑，**追蹤於 #40**。**在那之前，這條守衛防的是意外，不是攻擊者。**
    ///
    /// （這裡先前寫「追蹤於 #14」，而 #14 是 seam 的兩條 SHALL NOT，全文沒有
    /// `openat`、沒有 TOCTOU、沒有 append 路徑——**那個限度因此有兩個月沒有任何
    /// issue 在追**。由 `#27` 的診斷核對指標時發現。）
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
    /// **擋住這件事的介面改動已經做了**（#27，已 close）：`FileEventStore.init`
    /// 收 `CorpusContainmentPolicy`，而 `readOnlyRoot` 也認得 `CLAUDE_CONFIG_DIR`
    /// （#20 item 5）——所以兩條路都通了，一條是注入圍籬、一條是把預設根本身
    /// 指到合成樹。
    ///
    /// **但那九條測試還沒搬**，而現在沒有 issue 在要求搬它們。留這句話是為了
    /// 不讓下一個讀者以為「介面通了」等於「測試已經不碰真實語料了」——兩者
    /// 差一次沒人排程的工作。第二條路另有一個要注意的地方：`CLAUDE_CONFIG_DIR`
    /// 是 process 全域的，而測試預設平行跑，所以那樣改要配 `.serialized`。
    ///
    /// （這裡先前寫「追蹤於 #14」，而 #14 不涵蓋語料根注入。指標指錯了 issue。）
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
    /// - Parameters:
    ///   - symlinkHops: symlink 展開的次數。`SYMLOOP_MAX` 量級的預算。
    ///   - ancestorSteps: 往上遞推不存在父層的次數。**與 symlink 預算分開計**
    ///     （#20 item 7）：先前兩者共用一個 40，於是一條夠深的路徑可能在還沒
    ///     遇到任何 symlink 迴圈前就耗盡預算。
    ///
    /// 預算耗盡回 `nil` 而不是回原路徑（#20 item 7）。耗盡的意思是**解析不出來**，
    /// 而呼叫端對 `nil` 的姿態是 fail-closed（當成在語料內、拒絕寫入）。先前回
    /// 原路徑讓那條分支永遠不會執行——註解宣稱的 fail-closed 姿態沒有執行點，
    /// 是死碼。
    static func fullyResolve(
        _ path: String, symlinkHops: Int = 0, ancestorSteps: Int = 0
    ) -> String? {
        guard symlinkHops < 40 else { return nil }  // SYMLOOP_MAX 量級；迴圈時停手
        guard ancestorSteps < 256 else { return nil }  // 路徑深度上限，與上面獨立
        let absolute =
            path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        let url = URL(fileURLWithPath: absolute)
        let parent = url.deletingLastPathComponent().path
        let base = url.lastPathComponent

        // 父目錄必須解析成 kernel 真正會走到的目錄。它若不存在，往上遞推。
        guard let realParent = Self.realpath(parent) else {
            guard parent != "/" , parent != absolute else { return absolute }
            guard
                let resolvedParent = Self.fullyResolve(
                    parent, symlinkHops: symlinkHops, ancestorSteps: ancestorSteps + 1)
            else { return nil }
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
            return Self.fullyResolve(
                next, symlinkHops: symlinkHops + 1, ancestorSteps: ancestorSteps)
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
    /// 守衛的**實作**在 `CanonicalStore.validatedPath`：同一條規則現在有兩個
    /// 存放檔要遵守（events 與 presentations），複製一份就是複製一份會漂移的規格。
    /// - Parameter policy: 語料圍籬。**預設只認預設語料根**，與 #27 之前的行為
    ///   相同；知道實際語料根的呼叫端（facade、CLI）必須傳一個涵蓋它的 policy，
    ///   否則守衛檢查的是錯的樹。
    ///
    ///   預設值刻意保留：`FileEventStore` 是公開 API，而「不傳就沒有保護」比
    ///   「不傳就用預設根」更糟。預設值給的是**下界**，不是完整保護。
    public init(url: URL, policy: any CorpusContainmentPolicy = CorpusPolicy()) throws {
        self.url = try CanonicalStore.validatedPath(url, policy: policy)
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
        // 原子 append 的全部機制（O_APPEND、flock 涵蓋整個 write 迴圈、殘行封口、
        // F_FULLFSYNC、目錄 fsync、權限收緊）住在 `CanonicalStore.appendLine`。
        try CanonicalStore.appendLine(line, to: url)
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
    /// - Returns: 保留筆數、丟掉的行號，以及**這次修剪建立的備份**（沒有東西可丟
    ///   時為 `nil`——沒有覆寫就沒有需要保險的窗口）。
    ///
    /// ## 備份是這個方法的責任，不是呼叫端的（#31）
    ///
    /// 先前備份寫在 `ltm memory` 裡，而這裡只有一則「呼叫端必須先備份」的註解。
    /// **一條叫呼叫端別走某條路的註解，遠弱於把那條路拆掉**：任何繞過 CLI 直接
    /// 呼叫的路徑（含日後的 MCP server）都沒有保險，而就地覆寫的崩潰窗口對它們
    /// 一樣存在。
    ///
    /// 備份在**獨占鎖內、用剛讀到的那份 bytes** 寫出，所以「備份 == 即將被覆寫的
    /// 內容」是由構造保證的，不是靠兩次讀取碰巧一致——先前的 `copyItem` 是另一次
    /// 獨立讀取，中間可以有 append。
    ///
    /// 備份未確認落地就**中止修剪**（原檔一個 byte 都沒動）。記憶層是本 repo 唯一
    /// 不可重建的資料，判準因此不是「崩潰機率多低」而是「崩潰之後還剩什麼」。
    public func pruneUnusable() throws -> (
        kept: Int, corruptLines: [Int], supersededLines: [Int], backup: URL?
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (0, [], [], nil) }
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
        guard !corrupt.isEmpty || !superseded.isEmpty else { return (kept.count, [], [], nil) }

        // ── 備份，並且確認它真的在磁碟上，才動原檔 ──
        let backup = url.appendingPathExtension(
            "bak-\(UUID().uuidString.prefix(8))")
        let backupFD = open(backup.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard backupFD >= 0 else {
            throw EventStoreError.appendFailed(
                path: backup.path, underlying: "無法建立備份：errno \(errno)（未修剪）")
        }
        do {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(backupFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else {
                        throw EventStoreError.appendFailed(
                            path: backup.path, underlying: "備份寫入失敗：errno \(errno)（未修剪）")
                    }
                }
            }
            try CanonicalStore.syncToDevice(fd: backupFD, path: backup.path)
        } catch {
            close(backupFD)
            try? FileManager.default.removeItem(at: backup)
            throw error
        }
        close(backupFD)
        // 目錄項也要落盤，否則備份可能「內容在、名字不在」——正好是它要防的窗口。
        try CanonicalStore.fsyncDirectory(of: backup)

        // **讀回來比對。** `write` 回傳成功不等於磁碟上的內容等於我們手上的；
        // 而備份是就地覆寫的唯一保險，一份沒被確認過的保險等於沒有保險。
        let readback = try CanonicalStore.readRegularFile(at: backup)
        guard readback == bytes else {
            try? FileManager.default.removeItem(at: backup)
            throw EventStoreError.appendFailed(
                path: backup.path,
                underlying: "備份內容與原檔不符（\(readback.count) vs \(bytes.count) bytes）——未修剪")
        }

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
        // 與 `append` 走同一個 helper（#31 附帶發現）：先前這裡是純 `fsync`，
        // 而 append 用 `F_FULLFSYNC`——同一份持久性規格的兩個實作，弱的那個
        // 剛好在唯一會覆寫既有資料的路徑上。
        try CanonicalStore.syncToDevice(fd: fd, path: url.path)
        return (kept.count, corrupt, superseded, backup)
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
    /// **預設 fail-loud**（`skippingUnusable: false`）：解不開的紀錄一律外顯，
    /// 因為靜默跳過會讓「外來寫入者塞了本 schema 不認得的東西」看起來像
    /// 「那天沒有事件」——記憶層是不可重建的資料，安靜地少讀幾筆比讀不出來更糟。
    ///
    /// 但那個預設有個代價，#1 verify R3 指出來了：一次半途中斷的 append 留下
    /// 一行壞資料，**整份 canonical store 從此讀不出來**。所以另外提供
    /// `skippingUnusable: true`——它不會被排序或計分路徑呼叫，只給修復情境用：
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
            // **取不到就照讀，但「照讀」之前會等**（#20 item 8 更正）：
            // `readRegularFile` 的共享鎖是非阻塞加有界重試，最多約 2 秒
            // （200 次 × 10ms）。先前這裡寫「不引入新的阻塞點」，而那個迴圈
            // 本身就是一個——註解描述的是一個沒有實作的版本。
            //
            // 為什麼是有界而不是無限：讀取沒有正確性風險（最壞是看到半行並
            // 回報損壞），所以等到天荒地老換不到任何保證；而完全不等會讓
            // 「一次進行中的 append 被讀成損壞」重新變成常態。有界重試買的是
            // 前者的機率下降，代價是一個具名的、有上限的延遲。
            //
            // **從這個 fd 讀，不要另開一次路徑**（#1 verify R7 的 CRITICAL）。
            // R6 開了一個 `O_NONBLOCK` 的 fd、在它上面取鎖，然後用
            // `Data(contentsOf: url)` **重新開啟**——新的 descriptor 既不保證
            // 非阻塞、也沒經過 `S_IFREG` 檢查。對 FIFO 而言那是無限阻塞：
            // 與同一輪為 `append` 修掉的 non-termination 是同一個 failure class
            // 的另一側，而那兩條 FIFO 測試只測了 `append`。
            bytes = try CanonicalStore.readRegularFile(at: url)
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


    /// 檔案的原始 bytes。給「序列化輸出不得含任何原文」那條測試用——
    /// 斷言要下在真正落地的 bytes 上，不是下在某個重新編碼過的複本上。
    public func serializedBytes() throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else { return Data() }
        // 走與 `allEvents` 同一條受檢查的讀取路徑——先前它直接
        // `Data(contentsOf:)`，連鎖都沒取，對 FIFO 同樣會阻塞（#1 verify R7）。
        return try CanonicalStore.readRegularFile(at: url)
    }
}
