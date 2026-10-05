import LTMIndex

/// 整份稽核不通過時，給人讀的訊息（#61）。放在 LTMService 而不是 CLI：每一種組合都要能在單元測試裡
/// 印出來核對（R3-9：不中斷重建的第一次失敗，CLI 造不出來），而 CLI 只是把它印到 stderr。
public enum AuditMessage {
    /// 欠著稽核或建置結尾的稽核不通過（`IndexBuilder.BuildError.auditFailed`）。歸因只有
    /// `AuditFailure.Attribution` 的兩種，措辭跟著它與發生的時點走；只有覆蓋缺口時不提計數（R2-11）；
    /// 來源鍵是本機路徑，單獨一行並註明回報前遮掉（R2-12）。
    public static func failure(_ failure: AuditFailure) -> String {
        var lines: [String] = []
        switch failure.moment {
        case .beforeScan:
            lines.append("✗ 這份索引欠一次整份稽核；掃描前補跑，不通過——這次沒有併入任何內容。")
        case .afterBuild:
            lines.append("✗ 建置結尾的整份稽核不通過；這次的併入已經提交。")
        }
        lines += findingLines(chunks: failure.divergentChunks, sources: failure.divergentSources,
                              coverage: failure.coverageFindings.count)
        switch (failure.attribution, failure.moment) {
        case (.defect, .afterBuild):
            lines.append(
                "  這次 build 開始時計數是對的（從零開始，或掃描前的稽核剛通過），不符長在這一次的寫入裡：除非建置期間有 ltm "
                    + "以外的程式寫這個檔，否則是 ltm 自己的缺陷。")
            lines.append(defectRemedy)
        case (.defect, .beforeScan):
            lines.append(
                "  先前一次 build 的結尾稽核已經判定是 ltm 自己的缺陷。之後查詢的併入仍經同一組 trigger 寫入、ltm 以外的程式"
                    + "也可能寫過，所以這次的不符未必是同一個。")
            lines.append(defectRemedy)
        case (.defectOrOutsideChange, _):
            lines.append(
                "  這次 build 開始之前的計數沒有驗證過（從零重建被中斷後由別的 build 續完，或一次失敗的 `--audit` 之後），"
                    + "而那段期間 ltm 以外的程式可以改這個檔，所以分不出是 ltm 的缺陷還是外部修改。跑一次 "
                    + "`ltm build --full`：若它結尾的稽核又不通過，那就是缺陷，請回報。")
        }
        lines.append(
            "  在那之前：每次 `ltm build` 會在掃描前先補跑稽核，不通過就什麼都不併入；查詢不跑稽核，閘放行時照常回答"
                + "（新內容照樣併入）並提示欠著稽核，閘拒絕時叫你先跑 `ltm build`。")
        if !failure.coverageFindings.isEmpty {
            lines.append(localPaths(failure.coverageFindings))
        }
        return lines.joined(separator: "\n")
    }

    /// 沒有欠著稽核時，`ltm build --audit` 發現計數不符（`derivedCountsDiverged`）。
    public static func diverged(chunks: Int, sources: Int, coverageFindings: [String]) -> String {
        var lines = ["✗ 掃描前的稽核發現衍生計數與 chunk_sources 不符；每次 build 的閘讀的就是這兩份計數，所以這次在掃描"
            + "之前就停了，沒有併入任何內容。"]
        lines += findingLines(chunks: chunks, sources: sources, coverage: coverageFindings.count)
        lines.append(
            "  請跑 `ltm build --full` 從零重建：兩份計數會由 trigger 從頭長出來，重建的結尾也會再稽核一次。在那之前，"
                + "這份索引記成欠一次稽核：每次 `ltm build` 會在掃描前先稽核、不通過就不併入，查詢會提示。")
        if !coverageFindings.isEmpty { lines.append(localPaths(coverageFindings)) }
        return lines.joined(separator: "\n")
    }

    /// 欠著稽核時附在查詢輸出的那一行（R2-4）。CLI 的 stderr、recall 區塊、MCP 回應共用。
    public static let owedLine = "索引欠一次整份稽核（從零重建被中斷、稽核沒通過，或判定過缺陷）：跑一次 ltm build 看說明"

    private static let defectRemedy =
        "  `ltm build --full` 不是補救：它重跑同樣的程式，而從零重建不經過增量的作廢與刪除路徑，所以它通過也不代表沒有"
        + "缺陷。請回報這個問題（附上面的數字）；升級到修正版之後，若新版改了索引結構，第一次 `ltm build` 會自動從零重建，"
        + "否則跑一次 `ltm build --full`。"

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
