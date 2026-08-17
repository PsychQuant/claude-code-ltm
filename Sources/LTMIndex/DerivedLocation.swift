import Foundation
import LTMCore

/// 「這條路徑是否落在唯讀語料裡」的判定。
///
/// 這是**依賴反轉**，不是重新發明：判定的實作住在 LTMMemory（`CorpusLocation`，
/// 五輪 verify 換來的 symlink／firmlink／inode 身分處理），而 LTMIndex 刻意不
/// 依賴 LTMMemory——索引不該看得到事件儲存。
///
/// 兩個被否決的替代方案，理由留著免得日後有人「順手簡化」：
///
/// 1. **LTMIndex 直接依賴 LTMMemory**——會讓索引看得到 `FileEventStore`。依賴
///    宣告是那條紀律唯一的執行點（見 Package.swift 檔頭）。
/// 2. **在 LTMIndex 自己寫一份路徑檢查**——那段邏輯被 symlink、`..`、dangling
///    link、firmlink 各咬過一次。複製它等於保證兩份實作日後會漂移，而漂移的
///    方向是「其中一份放行了不該放行的路徑」，且不會有任何錯誤訊息。
///
/// 所以：需求在這裡宣告，實作由 facade 注入。
public protocol CorpusContainmentPolicy: Sendable {
    func isInsideReadOnlyCorpus(_ url: URL) -> Bool
}

/// 衍生產物的根。**所有**索引輸出都必須經過這裡取得路徑。
///
/// 不變式 1 說語料唯讀。索引層有自己的輸出路徑（資料庫、向量 sidecar、state），
/// 而那些路徑是可設定的——一個吃任意 URL 的輸出建構子等於把寫入語料的能力放進
/// 公開 API，跟 `FileEventStore(url:)` 當初的問題同一個形狀。
///
/// 所以檢查放在建構子，而不是「呼叫端記得別指到語料」；而 policy 是**必填**
/// 參數，因為有預設值就等於有一條沒想過這件事也能走通的路。
public struct DerivedLocation: Sendable {
    /// 預設根：`~/.claude-ltm/derived`。
    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude-ltm")
            .appendingPathComponent("derived")
    }

    public enum LocationError: Error, Sendable, Equatable {
        /// 輸出路徑解析後落在語料根底下。
        case insideReadOnlyCorpus(path: String)
    }

    public let root: URL

    /// - Throws: `LocationError.insideReadOnlyCorpus` 若 `root` 解析後落在語料裡。
    ///   判定委給注入的 policy——它背後是 inode 身分比對，字串比對擋不住 symlink，
    ///   也擋不住 macOS firmlink 那種「同一個 inode 的另一條穩定路徑」。
    public init(root: URL, policy: some CorpusContainmentPolicy) throws {
        guard !policy.isInsideReadOnlyCorpus(root) else {
            throw LocationError.insideReadOnlyCorpus(path: root.path)
        }
        self.root = root
    }

    public init(policy: some CorpusContainmentPolicy) throws {
        try self.init(root: DerivedLocation.defaultRoot, policy: policy)
    }

    public var databaseURL: URL { root.appendingPathComponent("index.sqlite3") }
    public var vectorsURL: URL { root.appendingPathComponent("vectors.bin") }
    public var stateURL: URL { root.appendingPathComponent("state.json") }
    public var lockURL: URL { root.appendingPathComponent("build.lock") }

    /// 建立根目錄（若不存在）。建構子已經保證它不在語料裡。
    public func createRootIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }
}
