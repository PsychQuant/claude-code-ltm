import LTMIndex

/// 整份稽核不通過時，給人讀的訊息（#61）。放在 LTMService 而不是 CLI：每一種組合都要能在單元測試裡印出來
/// 核對，而 CLI 只是把它印到 stderr。
///
/// **不歸因**（R5，使用者決定）：ltm 分不出不符是自己的缺陷還是外部修改，所以訊息只陳述發現、這次有沒有併入、
/// 索引接下來會怎樣、能做的事。關於 `ltm build --full` 只陳述它做什麼：讓兩份計數從頭長出來、結尾再稽核一次；
/// 從零重建不經過增量的作廢與刪除路徑，所以它通過不排除那兩條路徑上的問題（R4-3）。
public enum AuditMessage {
    public static func failure(_ failure: AuditFailure) -> String {
        var lines: [String] = []
        switch failure.moment {
        case .beforeScan:
            lines.append("✗ 掃描前的整份稽核不通過——這次沒有併入任何內容。")
        case .afterBuild:
            lines.append("✗ 建置結尾的整份稽核不通過；這次的併入已經提交。")
        }
        let countsDiverge = failure.divergentChunks > 0 || failure.divergentSources > 0
        // 只有覆蓋缺口、計數一致、沒有懸空連結時，結構性閘看到的正是稽核的覆蓋缺口——閘必然拒絕（R6-2）。
        let coverageOnly = !countsDiverge && failure.danglingLinks == 0 && !failure.coverageFindings.isEmpty
        if countsDiverge {
            lines.append(
                "  計數不符：\(failure.divergentChunks) 個 chunk 的 source_count、\(failure.divergentSources) 個來源的 "
                    + "source_chunk_counts 與 chunk_sources 重算的結果不同。")
        }
        if failure.danglingLinks > 0 {
            lines.append(
                "  懸空的連結：\(failure.danglingLinks) 個 chunk_sources 列指向已不存在的 chunk。結構性閘看不到它們；在處理之前，"
                    + "新的 turn 若重用那個 id，可能接上錯的來源，也會帶著被刪的那則 turn 留下的舊索引詞。")
        }
        // 覆蓋缺口有兩種條目：沒有游標的來源鍵（本機路徑），與「N 個 chunk 沒有任何 source mapping」那一筆（不是路徑，
        // R7-6：先前被算成 1 個缺口、印在本機路徑那一行）。辨識比對完整格式（R9：只看 `(` 會誤判來源鍵）。
        let orphanCounts = failure.coverageFindings.compactMap(IndexDatabase.orphanChunkCount(in:))
        let sourceKeys = failure.coverageFindings.filter { IndexDatabase.orphanChunkCount(in: $0) == nil }
        if !failure.coverageFindings.isEmpty {
            var parts: [String] = []
            if !sourceKeys.isEmpty { parts.append("\(sourceKeys.count) 個來源有 chunk 卻沒有續讀游標") }
            parts += orphanCounts.map { "\($0) 個 chunk 沒有任何 source mapping" }
            lines.append("  覆蓋缺口：\(parts.joined(separator: "；"))。")
        }
        lines.append("  ltm 分不出原因：可能出在 ltm 自己，也可能是 ltm 以外的程式改過索引檔。")
        if failure.recorded {
            lines.append(
                "  這份索引記著欠一次稽核：之後的 `ltm build` 會在掃描前先稽核、不通過就不併入（從零重建——`--full`，或 "
                    + "embedding revision、layout 變動觸發的——會丟掉這個紀錄，只在它自己的結尾稽核）。")
            // R6-2：R5 把「閘拒絕時」那一半拿掉了，而只有覆蓋缺口、或計數一致時，閘與稽核看到的是同一件事。
            if coverageOnly {
                lines.append(
                    "  查詢不跑稽核；這次的覆蓋缺口結構性閘也看得到，所以查詢會被拒絕、叫你先跑 `ltm build`（另一個行程正持有"
                        + "建置鎖、查詢這一輪沒有併入時不跑閘，會照常回答）。")
            } else {
                lines.append(
                    "  查詢不跑稽核：結構性閘放行時照常回答、照常併入新內容並提示欠著稽核；閘看得到這個問題時，查詢會被拒絕、"
                        + "叫你先跑 `ltm build`。")
            }
        } else {
            // 沒記上時也要說 build 與查詢怎麼做（R7-6），而且要跟記上時一樣分「閘放行」與「閘看得到」（R8，codex）：
            // 先前無條件寫「查詢照常回答、照常併入」，但閘看得到的不符——例如有連結的 chunk 的 source_count 被改成 0——
            // 照樣讓查詢與下一次 build 被拒。沒有旗標時閘拒絕的補救是 `--full`，不是 `ltm build`。
            //
            // R9：三條失敗路徑都在旗標不在時寫一次、寫完讀回（`IndexBuilder.recordMarker`）。沒記上的意思是讀回時看不到：
            // 寫入出錯、被 trigger 靜默略過，或讀回本身失敗（R10-4：最後一種其實可能寫進去了，所以訊息說「沒能確認」、
            // 並以「沒有這個紀錄時」為條件）。「之後的 build」限定成不帶 `--audit` 的增量 build——`--audit` 與從零重建
            // 都不走閘（R9-8）。
            //
            // R11-4：條件「沒有這個紀錄時」要管到每一個分支，不只第一句；原因也不寫——寫入可能拋錯、被 trigger 略過、
            // 撞上別人持有的寫鎖，或讀回失敗（而寫入其實成功），所以先前的「寫完讀回時看不到」與「確認索引檔可以寫入」
            // 都只對其中一種成立。
            lines.append("  （這次沒能確認「欠一次稽核」寫進了索引：寫入或讀回沒有成功。）")
            if coverageOnly {
                // R12：`--audit` 只有覆蓋缺口時照結構性閘的方式拒絕、不寫旗標，所以這一支不提「再跑 --audit 會再試寫入」。
                lines.append(
                    "  沒有這個紀錄時，之後的增量 `ltm build` 與查詢都不會記得它，而且都會被拒絕、叫你跑 `ltm build --full`"
                        + "——這次的覆蓋缺口結構性閘也看得到（另一個行程正持有建置鎖、查詢這一輪沒有併入時不跑閘，會照常回答）。")
            } else {
                lines.append(
                    "  沒有這個紀錄時，之後不帶 `--audit` 的增量 `ltm build` 與查詢都不會記得它，只走結構性閘：閘放行時，"
                        + "build 照常併入、查詢照常回答與併入，不會提示欠著，也不再找這些問題；閘看得到這個問題時，兩者都會"
                        + "被拒絕、叫你跑 `ltm build --full`。再跑一次 `ltm build --audit` 會重新稽核、再試一次寫入。")
            }
            lines.append("  從零重建——`--full`，或 embedding revision、layout 變動觸發的——不走閘，只在自己的結尾稽核。")
        }
        lines.append("  能做的事：")
        lines.append(
            sourceKeys.isEmpty
                ? "  - 回報這個問題（附上面的數字）。"
                : "  - 回報這個問題（附上面的數字；下面的本機路徑貼到公開的 issue 之前請先遮掉）。")
        let what = countsDiverge || failure.danglingLinks > 0 ? "兩份計數與連結" : "索引"
        lines.append(
            "  - `ltm build --full` 從零重建：\(what)從頭長出來，結尾再稽核一次。它驗得到的只有從零重建的路徑——結尾若又"
                + "不通過，請回報；通過也不排除增量路徑（來源被改寫時的作廢與刪除）的問題，那要等之後有來源被改寫的 "
                + "build 跑過，再跑一次 `ltm build --audit` 才看得到。")
        if !sourceKeys.isEmpty {
            lines.append("  本機路徑（貼到公開的 issue 之前請先遮掉）：\(sourceKeys.prefix(3).joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    /// 欠著稽核時附在查詢輸出的那一行（R2-4）。CLI 的 stderr、recall 區塊、MCP 回應共用。
    /// 這一輪的併入因為另一個行程持鎖而延後時，欠著的原因可能就是那個正在跑的 build，所以換一句話（R4-2）：
    /// 從零重建在它的 stamps 提交之後（第一批之前）就記下欠著、結尾才稽核。持鎖的也可能是另一個查詢的併入（R5-6）。
    public static func owedLine(mergeDeferred: Bool) -> String {
        mergeDeferred
            ? "索引記著欠一次整份稽核，而另一個行程正持有建置鎖：若那是 ltm build，它會自己補跑這次稽核（不通過時它自己會"
                + "說明）；之後查詢若仍提示，再跑一次 ltm build 看說明"
            : "索引欠一次整份稽核：跑一次 ltm build 看說明"
    }

    /// `ltm build` 成功結束、索引卻仍記著欠一次稽核時印的那一行（R9-7）。先前 build 從不印 `auditOwed`：清除紀錄被
    /// trigger 靜默略過時，build 每次都報稽核通過、查詢每次都說欠著，而 build 這邊什麼都沒說。
    ///
    /// 只陳述觀察到的事，不寫原因（R10-1）：先前 `false` 那一支寫「有來源未併入」，而 `ltm build` 不帶時間預算，那個
    /// 情形在 exit 0 時走不到；走得到的是別的寫者在這次 build 期間寫下旗標。清不掉的那一支補上 `--full` 這個出口——
    /// 只說「再跑 `ltm build`」，清除一直被略過時是一個不會結束的循環（R10-1，DA）。只說「結束時仍在」：ltm 看到的
    /// 只有 COMMIT 之後那一次讀取——「清除了」（R11-3）與「沒有清掉」（R12：清除可能成功、再被 trigger 寫回）都是推論。
    public static func owedAfterBuild(auditedAtEnd: Bool) -> String {
        auditedAtEnd
            ? "這次 build 結尾的稽核通過了，但欠一次稽核的紀錄在結束時仍在：之後的 `ltm build` 會再稽核。一直如此，"
                + "可以回報，或跑 `ltm build --full` 從零重建——它會丟掉這個紀錄"
            : "這次 build 結束時，索引記著欠一次整份稽核，而這次沒有跑結尾稽核：再跑一次 `ltm build`"
    }

    /// 這一輪因另一個行程持鎖而沒有併入新內容（#51）。CLI、MCP、recall 區塊共用（R4-2：recall 先前沒有）。
    /// 持鎖的可能是 `ltm build`，也可能是另一個查詢的併入（R5-6）。
    public static let mergeDeferredLine = "另一個行程正在建置或併入（ltm build 或另一個查詢），本輪未併入新內容（答案來自既有索引）"
}
