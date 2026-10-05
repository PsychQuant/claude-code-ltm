import LTMIndex

/// 整份稽核不通過時，給人讀的訊息（#61）。放在 LTMService 而不是 CLI：每一種組合都要能在單元測試裡
/// 印出來核對（R3-9：不中斷重建的第一次失敗，CLI 造不出來），而 CLI 只是把它印到 stderr。
///
/// 關於 `ltm build --full`，所有訊息守同一個事實（R4-3、R4-4）：從零重建不經過增量的作廢與刪除路徑，所以它
/// 結尾的稽核只驗得到從零重建的路徑——不通過就是缺陷，通過不排除增量路徑的缺陷；它（以及 embedding
/// revision、layout 變動觸發的重建）還會丟掉索引裡記著的判定。
public enum AuditMessage {
    /// 欠著稽核或建置結尾的稽核不通過（`IndexBuilder.BuildError.auditFailed`）。歸因只有
    /// `AuditFailure.Attribution` 的兩種，而在程式裡它等於時點：結尾是 `.defect`，掃描前是 `.defectOrOutsideChange`。
    /// 只有覆蓋缺口時不提計數（R2-11、R4-7）；來源鍵是本機路徑，單獨一行並註明回報前遮掉（R2-12）。
    public static func failure(_ failure: AuditFailure) -> String {
        var lines: [String] = []
        switch failure.moment {
        case .beforeScan:
            lines.append("✗ 這份索引欠一次整份稽核；掃描前補跑，不通過——這次沒有併入任何內容。")
        case .afterBuild:
            lines.append("✗ 建置結尾的整份稽核不通過；這次的併入已經提交。")
        }
        let countsDiverge = failure.divergentChunks > 0 || failure.divergentSources > 0
        lines += findingLines(chunks: failure.divergentChunks, sources: failure.divergentSources,
                              coverage: failure.coverageFindings.count)
        if failure.previousDefect {
            lines.append("  先前一次建置結尾的稽核已經判定過 ltm 的缺陷；這次的問題可能是同一個，也可能不是。")
        }
        switch failure.attribution {
        case .defect:
            let what = countsDiverge ? "不符" : "覆蓋缺口"
            lines.append(
                "  這次 build 開始時索引已知一致（從零開始，或掃描前的稽核剛通過），\(what)長在這一次的寫入裡：除非建置"
                    + "期間有 ltm 以外的程式寫這個檔，否則是 ltm 自己的缺陷。")
            lines.append(defectRemedy)
        case .defectOrOutsideChange:
            lines.append(
                "  這次 build 開始之前有一段沒稽核過的期間（從零重建被中斷後由別的 build 續完、失敗的 `--audit` 之前，"
                    + "或先前判定過缺陷之後），那段期間 ltm 以外的程式可以改這個檔，所以分不出是 ltm 的缺陷還是外部修改。")
            lines.append(fullRebuildRemedy)
        }
        lines.append(
            "  在那之前：每次 `ltm build` 會在掃描前先補跑稽核，不通過就什麼都不併入；查詢不跑稽核，閘放行時照常回答"
                + "（新內容照樣併入）並提示欠著稽核，閘拒絕時叫你先跑 `ltm build`。")
        if !failure.recorded { lines.append(notRecorded) }
        if !failure.coverageFindings.isEmpty {
            lines.append(localPaths(failure.coverageFindings))
        }
        return lines.joined(separator: "\n")
    }

    /// 沒有欠著稽核時，`ltm build --audit` 發現計數不符（`derivedCountsDiverged`）。
    public static func diverged(chunks: Int, sources: Int, coverageFindings: [String], recorded: Bool) -> String {
        var lines = ["✗ 掃描前的稽核發現衍生計數與 chunk_sources 不符；每次 build 的閘讀的就是這兩份計數，所以這次在掃描"
            + "之前就停了，沒有併入任何內容。"]
        lines += findingLines(chunks: chunks, sources: sources, coverage: coverageFindings.count)
        lines.append(
            "  這份索引上一次稽核之後只經歷過增量併入與可能的外部寫入，所以分不出是 ltm 的缺陷還是外部修改。在處理之前，"
                + "它記成欠一次稽核：每次 `ltm build` 會在掃描前先稽核、不通過就不併入，查詢會提示。")
        lines.append(fullRebuildRemedy)
        if !recorded { lines.append(notRecorded) }
        if !coverageFindings.isEmpty { lines.append(localPaths(coverageFindings)) }
        return lines.joined(separator: "\n")
    }

    /// 欠著稽核時附在查詢輸出的那一行（R2-4）。CLI 的 stderr、recall 區塊、MCP 回應共用。
    /// 這一輪的併入因為另一個 build 持鎖而延後時，欠著的原因很可能就是那個正在跑的 build，所以換一句話（R4-2）：
    /// 從零重建在第一批之前就記下欠著、結尾才稽核，整段期間查詢都會讀到這個旗標。
    public static func owedLine(mergeDeferred: Bool) -> String {
        mergeDeferred
            ? "有另一個 ltm build 正在跑，而索引記著欠一次整份稽核：若那是從零重建或補跑稽核的 build，它結尾會自己稽核；"
                + "它結束後若查詢仍提示欠著，再跑一次 ltm build 看說明"
            : "索引欠一次整份稽核（從零重建被中斷、稽核沒通過，或判定過缺陷）：跑一次 ltm build 看說明"
    }

    /// 這一輪因另一個 build 持鎖而沒有併入新內容（#51）。CLI、MCP、recall 區塊共用（R4-2：recall 先前沒有）。
    public static let mergeDeferredLine = "有另一個 `ltm build` 正在跑，本輪未併入新內容（答案來自既有索引）"

    private static let fullRebuildRemedy =
        "  `ltm build --full` 會讓兩份計數從頭長出來，但它結尾的稽核只驗得到從零重建的路徑：不通過就是 ltm 的缺陷，"
        + "請回報；通過不排除增量路徑（來源被改寫時的作廢與刪除）的缺陷——等之後有來源被改寫的 build 跑過，再跑一次 "
        + "`ltm build --audit` 才看得到。"

    private static let defectRemedy =
        "  `ltm build --full` 不是補救：它重跑同樣的程式，而從零重建不經過增量的作廢與刪除路徑，所以它通過也不代表沒有"
        + "缺陷；它（以及 embedding revision、layout 變動觸發的重建）還會丟掉索引裡記著的這筆判定。請回報這個問題"
        + "（附上面的數字）；升級到修正版之後，若新版改了索引結構，第一次 `ltm build` 會自動從零重建，否則跑一次 "
        + "`ltm build --full`，之後在有來源被改寫的 build 跑過時，再跑一次 `ltm build --audit` 確認。"

    private static let notRecorded =
        "  （這次的判定沒能寫進索引：寫入旗標失敗。下一次 build 不會記得它——修好寫入問題後再跑一次 `ltm build --audit`。）"

    private static func findingLines(chunks: Int, sources: Int, coverage: Int) -> [String] {
        var lines: [String] = []
        if chunks > 0 || sources > 0 {
            lines.append(
                "  計數不符：\(chunks) 個 chunk 的 source_count、\(sources) 個來源的 source_chunk_counts 與 chunk_sources "
                    + "重算的結果不同。")
        }
        if coverage > 0 {
            lines.append("  覆蓋缺口：\(coverage) 個（有 chunk 卻沒有續讀游標的來源，或沒有任何 source mapping 的 chunk）。")
        }
        return lines
    }

    private static func localPaths(_ keys: [String]) -> String {
        "  本機路徑（貼到公開的 issue 之前請先遮掉）：\(keys.prefix(3).joined(separator: "、"))"
    }
}
