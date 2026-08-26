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
        用法：ltm memory [--prune] [--force] [--export-key] [--import-key <hex>]

        檢查記憶層事件檔，逐行報出讀不回來的紀錄：
          - 損壞：解不開的行（半途中斷的 append、外來寫入者）
          - 舊規則：用已被取代的 anchor 定址規則寫的行

        選項：
          --prune            把可用的紀錄寫回去，丟掉上面兩類。**先備份原檔**
          --force            允許「一筆都不保留」的修剪（整份歷史都讀不回來時才需要）
          --export-key       印出這台機器的 anchor 密鑰（64 個十六進位字元）
          --import-key <hex> 把密鑰寫進這台機器的 Keychain（換機器時用）
          -h, --help         顯示本說明

        不帶 --prune 時只讀不寫。

        密鑰：anchor 的內容摘要是 HMAC，密鑰存在 Keychain 且**不與事件檔一起
        備份**——那正是它擋「備份外流即可還原原文」的方式。所以換機器時要自己
        把密鑰搬過去，否則舊紀錄會全體讀不回來（顯示為「舊規則」）。

        搬法：舊機器 `ltm memory --export-key`，新機器 `--import-key <那串>`。
        **匯出的是秘密**，別貼進會被記錄的地方。
        """

    static func run(arguments raw: [String]) -> Int32 {
        let arguments = Arguments(raw, valueOptions: ["import-key"])
        if arguments.has("help") || arguments.has("h") {
            print(usage)
            return LTMCommandLine.ExitCode.success.rawValue
        }
        // 未知選項一律拒絕。少了這道檢查，`--prune=true` 會被解析成 values 而不是
        // flags，於是 `has("prune")` 為假——**命令安靜地什麼都不做而回 0**。
        // 現在多了 `--force`，打錯字的代價從「沒修剪」變成「以為加了保護其實沒加」。
        let unknown = arguments.unknown(
            known: ["prune", "force", "export-key", "import-key", "help", "h"])
        guard unknown.isEmpty else {
            Output.error("✗ 未知選項：\(unknown.map { "--\($0)" }.joined(separator: ", "))\n\n\(usage)")
            return LTMCommandLine.ExitCode.usageError.rawValue
        }

        if arguments.has("export-key") {
            return exportKey()
        }
        if let hex = arguments.value("import-key") {
            return importKey(hex)
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

            // **備份由 `pruneUnusable` 自己做**（#31）。先前這裡有一次
            // `copyItem`，而那是**另一次獨立讀取**——與即將被覆寫的內容之間隔著
            // 一個可以有 append 的窗口。現在備份在獨占鎖內、用剛讀到的那份 bytes
            // 寫出，並且確認落地與內容相符之後才動原檔。
            //
            // 這也讓保險不再依賴呼叫端記得做：任何繞過本命令直接呼叫的路徑
            // （含日後的 MCP server）都吃得到同一份保障。
            //
            // **上面那次讀取的結果不拿來當寫入依據。** `pruneUnusable` 自己在
            // 獨占鎖內重讀一次——先前是「讀完、放鎖、再把讀到的寫回去」，中間任何
            // 一筆 append 都會被靜默丟掉。
            let pruned = try store.pruneUnusable()
            let dropped = pruned.corruptLines.count + pruned.supersededLines.count
            print("")
            if let backup = pruned.backup {
                print("  ✓ 已備份原檔：\(backup.lastPathComponent)")
            }
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

    /// 印出這台機器的 anchor 密鑰。
    ///
    /// **這是秘密。** 印到 stdout 是刻意的——使用者要能把它導進檔案或密碼管理
    /// 器；但它會進 shell 歷史與任何在錄的終端機，所以說明裡寫明了這一點。
    private static func exportKey() -> Int32 {
        do {
            let key = try AnchorKeyStore.loadOrCreate()
            print(key.hexEncoded)
            return LTMCommandLine.ExitCode.success.rawValue
        } catch {
            Output.error("✗ 讀不到 anchor 密鑰：\(error)")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        }
    }

    /// 把密鑰寫進這台機器的 Keychain。
    ///
    /// **會覆寫既有的那一把**，而那會讓這台機器上既有的 anchor 全體讀不回來。
    /// 所以先檢查是否已有一把、且與要匯入的不同——是的話拒絕並說明，不靜默
    /// 覆蓋掉一份不可重建的資料的鑰匙。
    private static func importKey(_ hex: String) -> Int32 {
        guard let incoming = AnchorKey(hex: hex) else {
            Output.error("✗ 密鑰格式不對：要 64 個十六進位字元（32 bytes）")
            return LTMCommandLine.ExitCode.usageError.rawValue
        }
        do {
            if let existing = try AnchorKeyStore.load(), existing != incoming {
                Output.error(
                    """
                    ✗ 這台機器已經有一把不同的 anchor 密鑰。
                    覆寫它會讓現有的紀錄全部讀不回來（顯示為「舊規則」），而記憶層是
                    這裡唯一不可重建的資料。
                    確定要換的話，先自己備份：`ltm memory --export-key > old-key.txt`，
                    再用 `security` 刪掉 Keychain 裡 service 為 claude-ltm-anchor-key
                    的項目，然後重跑這個命令。
                    """)
                return LTMCommandLine.ExitCode.indexStateError.rawValue
            }
            try AnchorKeyStore.save(incoming)
            print("✓ 已匯入 anchor 密鑰")
            return LTMCommandLine.ExitCode.success.rawValue
        } catch {
            Output.error("✗ 寫入 Keychain 失敗：\(error)")
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
