import Foundation
import LTMCore
import LTMMemory
import LTMService

/// `ltm memory` —— 記憶層事件檔的檢查與修剪。
///
/// ## 為什麼需要這個命令
///
/// 記憶層是本 repo **唯一不可重建**的資料（索引隨時可以 `ltm build --full` 重來，
/// 使用歷史不行）。而它有兩類「讀不回來」的紀錄：解不開的（一次半途中斷的 append
/// 就會產生），以及用**舊定址規則**寫的（anchor 的 source 從 sessionId 換成 project
/// 指紋那一次之後，換代前寫的每一筆都是）。
///
/// 兩者都會讓 `allEvents()` 具名拋錯——那是對的，安靜地少讀幾筆比讀不出來更糟。
/// 但先前那個錯誤**指名不出補救方式**，因為修復路徑只有測試在呼叫、沒有任何使用者
/// 可達的入口。一個必然觸發、又沒有出路的錯誤，實際效果等同「歷史從此鎖死」。
///
/// 所以這個命令存在的理由不是便利，是讓那句「失敗訊息要指名補救命令」有東西可以指。
enum MemoryCommand {
    static let usage = """
        用法：ltm memory [--prune] [--force]

        檢查記憶層事件檔，逐行報出讀不回來的紀錄：
          - 損壞：解不開的行（半途中斷的 append、外來寫入者）
          - 舊規則：用已被取代的 anchor 定址規則寫的行

        選項：
          --prune       把可用的紀錄寫回去，丟掉上面兩類。**先備份原檔**
          --force       允許「一筆都不保留」的修剪（整份歷史都讀不回來時才需要）
          -h, --help    顯示本說明

        不帶 --prune 時只讀不寫。
        """

    static func run(arguments raw: [String]) -> Int32 {
        let arguments = Arguments(raw, valueOptions: [])
        if arguments.has("help") || arguments.has("h") {
            print(usage)
            return LTMCommandLine.ExitCode.success.rawValue
        }
        // 未知選項一律拒絕。少了這道檢查，`--prune=true` 會被解析成 values 而不是
        // flags，於是 `has("prune")` 為假——**命令安靜地什麼都不做而回 0**。
        // 現在多了 `--force`，打錯字的代價從「沒修剪」變成「以為加了保護其實沒加」。
        let unknown = arguments.unknown(known: ["prune", "force", "help", "h"])
        guard unknown.isEmpty else {
            Output.error("✗ 未知選項：\(unknown.map { "--\($0)" }.joined(separator: ", "))\n\n\(usage)")
            return LTMCommandLine.ExitCode.usageError.rawValue
        }

        do {
            let root = try CommandSupport.validatedMemoryRoot()
            let url = root.appendingPathComponent("events.jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("（沒有事件檔：\(url.path)）")
                return LTMCommandLine.ExitCode.success.rawValue
            }
            let store = try FileEventStore(url: url, policy: CommandSupport.corpusPolicy())
            let result = try store.allEvents(skippingUnusable: true)

            print("事件檔：\(url.path)")
            print("  可用紀錄：\(result.events.count)")
            report("損壞", result.corruptLines)
            report("舊定址規則", result.supersededLines)

            let unusable = result.corruptLines.count + result.supersededLines.count
            guard unusable > 0 else {
                print("  ✓ 沒有讀不回來的紀錄")
                return LTMCommandLine.ExitCode.success.rawValue
            }
            guard arguments.has("prune") else {
                print("")
                if result.events.isEmpty {
                    // **不要說「保留其餘」——這裡沒有其餘。** 而這正是主要觸發情境：
                    // anchor 定址規則換代之後，換代前寫的每一筆都是舊規則，所以
                    // 「全部讀不回來」是預設情況而不是邊角。
                    print("這 \(unusable) 筆是**全部**的紀錄——修剪會讓事件檔變成空的。")
                    print("確定要這麼做的話跑 `ltm memory --prune --force`（會先備份原檔）。")
                } else {
                    print(
                        "要丟掉這 \(unusable) 筆、保留另外 \(result.events.count) 筆，"
                            + "跑 `ltm memory --prune`（會先備份原檔）。")
                }
                return LTMCommandLine.ExitCode.success.rawValue
            }

            // 「一筆都不保留」需要明示。記憶層是唯一不可重建的資料，而使用者是照著
            // 一個錯誤訊息的指示走到這裡的——那個訊息說的是「丟掉讀不回來的那些」，
            // 不是「清空歷史」。兩者在換代情境下**恰好是同一件事**，所以必須讓使用者
            // 看見這一點再決定。
            if result.events.isEmpty && !arguments.has("force") {
                Output.error(
                    """
                    ✗ 這會丟掉**全部** \(unusable) 筆紀錄，一筆都不保留——事件檔會變成空的。
                    記憶層是這裡唯一不可重建的資料，所以這一步要明示：
                        ltm memory --prune --force
                    （仍然會先備份原檔。）
                    """)
                return LTMCommandLine.ExitCode.usageError.rawValue
            }

            // **先備份再改**。這是 canonical 資料，而被丟掉的那幾筆裡，「舊規則」
            // 那一類的內容仍然是真的——只是指向一個已經不成立的定址方式。日後若
            // 有人寫得出遷移，備份是唯一還原得回來的東西。
            //
            // 備份也是就地覆寫的崩潰窗口的唯一保險：`pruneUnusable` 為了不換 inode
            // （換掉會讓 `append` 的 flock 失效）放棄了原子替換。
            let backup = url.appendingPathExtension(
                "bak-\(UUID().uuidString.prefix(8))-\(Int(Date().timeIntervalSince1970))")
            try FileManager.default.copyItem(at: url, to: backup)

            // **上面那次讀取的結果不拿來當寫入依據。** `pruneUnusable` 自己在
            // 獨占鎖內重讀一次——先前是「讀完、放鎖、再把讀到的寫回去」，中間任何
            // 一筆 append 都會被靜默丟掉。
            let pruned = try store.pruneUnusable()
            let dropped = pruned.corruptLines.count + pruned.supersededLines.count
            print("")
            print("  ✓ 已備份原檔：\(backup.lastPathComponent)")
            print("  ✓ 保留 \(pruned.kept) 筆可用紀錄，丟掉 \(dropped) 筆")
            if dropped != unusable {
                print("    （與上面的清單不同：修剪在獨占鎖內重讀了一次，期間檔案有變動）")
            }
            return LTMCommandLine.ExitCode.success.rawValue
        } catch LTMService.ServiceError.rootInsideCorpus(let path) {
            Output.error(
                """
                ✗ 這個路徑落在唯讀語料裡：\(path)
                語料是 source of truth，任何寫入都是 bug——而這條命令會寫（備份與改寫）。
                請把 LTM_MEMORY_ROOT 指到語料之外的位置。
                """)
            return LTMCommandLine.ExitCode.corpusError.rawValue
        } catch let error as EventStoreError {
            Output.error("✗ \(describe(error))")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        } catch {
            Output.error("✗ \(error)")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        }
    }

    private static func report(_ label: String, _ lines: [Int]) {
        guard !lines.isEmpty else { return }
        let shown = lines.prefix(20).map(String.init).joined(separator: ", ")
        let more = lines.count > 20 ? "…（共 \(lines.count) 行）" : ""
        print("  \(label)：\(lines.count) 筆，行號 \(shown)\(more)")
    }

    /// `EventStoreError` 的使用者可讀說明。**每一類都指名補救方式。**
    static func describe(_ error: EventStoreError) -> String {
        // **補救建議必須看檔案，不能一律說 `ltm memory --prune`**（#36 D2）。
        //
        // `EventStoreError` 是**兩個** canonical 存放共用的錯誤型別（見
        // `CanonicalStore` 的說明），而 `ltm memory --prune` 只處理 `events.jsonl`。
        // 對 `presentations.jsonl` 給那條建議，是叫使用者跑一個根本不看這個檔的
        // 命令——他跑完會看到「沒有東西要清」然後以為問題不存在。
        //
        // 呈現紀錄**刻意沒有** prune（理由見 `FilePresentationRecordStore`：
        // `--prune` 在它主要的觸發情境裡等於清空整份歷史）。它的補救是修復讀取
        // ＋ 使用者自己處置那幾行。
        func remedy(for path: String, plural: Bool) -> String {
            let it = plural ? "它們" : "它"
            guard (path as NSString).lastPathComponent == "presentations.jsonl" else {
                return "跑 `ltm memory` 看完整清單，或 `ltm memory --prune` 丟掉\(it)（會先備份）。"
            }
            return """
                這是**呈現紀錄**檔，`ltm memory --prune` 不處理它（那個命令只看 \
                `events.jsonl`）。
                呈現紀錄刻意沒有 prune——在定址規則換代這個主要情境裡，「丟掉讀不回來的」
                等於清空整份歷史。
                讀得回來的部分可以先救出來：`allRecords(skippingUnusable: true)` 會回傳
                其餘紀錄並列出跳過的行號；那幾行要不要刪、怎麼刪，由你決定。
                """
        }

        switch error {
        case .supersededAnchorRule(let path, let lineNumbers):
            return """
                記憶層有 \(lineNumbers.count) 筆用舊定址規則寫的紀錄，讀取被拒絕。
                檔案：\(path)
                行號：\(lineNumbers.prefix(20).map(String.init).joined(separator: ", "))\
                \(lineNumbers.count > 20 ? "…" : "")
                anchor 的 source 已從 sessionId 換成 project 指紋，舊值無法對現行規則
                解析——重新詮釋會指到錯的 turn 或誤報成 orphan，兩者與正確行為分不出來。
                \(remedy(for: path, plural: true))
                """
        case .corruptRecord(let path, let lineNumber):
            return """
                記憶層第 \(lineNumber) 行解不開：\(path)
                \(remedy(for: path, plural: false))
                """
        case .readFailed(let path, let underlying):
            return """
                讀不到記憶層事件檔：\(path)
                原因：\(underlying)
                確認檔案存在且可讀；若它不是一般檔案（symlink 到 FIFO 之類），
                把 LTM_MEMORY_ROOT 指到別處。
                """
        case .appendFailed(let path, let underlying):
            return """
                寫不進記憶層事件檔：\(path)
                原因：\(underlying)
                確認目錄可寫、磁碟有空間。**寫入失敗不會被吞掉**——記憶層掉了就回不來。
                """
        case .pathInsideReadOnlyCorpus(let path):
            return """
                這個路徑落在唯讀語料裡：\(path)
                語料是 source of truth，任何寫入都是 bug。
                請把 LTM_MEMORY_ROOT 指到語料之外的位置。
                """
        case .insecureDirectory(let path):
            return """
                記憶層目錄的權限太寬：\(path)
                它存的是使用歷史，不該是 world-readable。改成 0700 後再試。
                """
        }
    }
}
