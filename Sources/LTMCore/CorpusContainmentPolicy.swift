import Foundation

/// 「這條路徑在不在唯讀語料裡」的判定**需求**。
///
/// ## 為什麼是協定，而且住在最底層
///
/// 不變式 1 說語料唯讀，所以任何吃任意 URL 的輸出建構子都等於把「寫進語料」
/// 這個能力放進公開 API。要擋它就得知道語料在哪——而**語料在哪是 facade 的
/// 知識**（`LTM_CORPUS_ROOT` 可以覆寫），不是任何一個 library 層的知識。
///
/// 判定本身（逐段解析 symlink、`..` 在解析後才消解、`(st_dev, st_ino)` 身分
/// 比對、firmlink）住在 `LTMMemory.CorpusLocation`，只有一份。
///
/// 兩個被否決的替代方案，理由留著免得日後有人「順手簡化」：
///
/// 1. **讓需要它的模組直接依賴 `LTMMemory`**——那會讓索引層看得到
///    `FileEventStore`。依賴宣告是那條紀律唯一的執行點（見 `Package.swift` 檔頭）。
/// 2. **各模組自己寫一份路徑檢查**——那段邏輯被 symlink、`..`、dangling link、
///    firmlink 各咬過一次。複製它等於保證兩份實作日後會漂移，而漂移的方向是
///    「其中一份放行了不該放行的路徑」，且不會有任何錯誤訊息。
///
/// 所以：需求在這裡宣告，實作由 facade 注入。
///
/// ## 為什麼從 `LTMIndex` 移到這裡（#27）
///
/// 先前這個協定宣告在 `LTMIndex`，於是**只有索引層**享有「宣告需求、由 facade
/// 注入」這個形狀。記憶層的 `FileEventStore` 反而自己呼叫固定預設根的
/// `CorpusLocation.isInsideReadOnlyCorpus`——`CLAUDE.md` 寫著那條判準，而記憶層
/// 是它的反例。
///
/// `LTMIndex` 與 `LTMMemory` 是同層（都只依賴 `LTMCore`），所以共用一份宣告
/// 的唯一位置就是這裡。在 `LTMMemory` 另宣告一份會讓同一件事有兩個寫者。
public protocol CorpusContainmentPolicy: Sendable {
    func isInsideReadOnlyCorpus(_ url: URL) -> Bool
}
