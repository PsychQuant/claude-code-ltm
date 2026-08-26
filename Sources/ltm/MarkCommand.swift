import Foundation
import LTMCore
import LTMEval
import LTMService

/// 把一次互動記成 deliberate 事件（#35，經 #24 落地）。
///
/// ## 這個命令補的是一個結構性的缺口
///
/// 在它之前，**全 repo 只有一個事件寫入端，而它固定寫 `shown`**。後果不是「少了
/// 一個便利功能」，是三個機制在出貨的程式碼裡從來沒有執行過：
///
/// - `Projection` 的淨強度只由 deliberate 事件推動（`shown` 被明確排除、只計
///   impressions），所以每個 anchor 的淨強度恆為 0，`human-like` 與 `archival`
///   的輸出**必然相同**。
/// - 擴散由 `opened`／`cited`／`pinned` 驅動，所以那個迴圈一次都沒跑過（#15）。
/// - 交錯比較的每一次都是 null comparison，跑一萬次也一樣（#33 的機具因此讀不到
///   任何 deliberate 事件）。
///
/// 缺的從來不是時間，是一個把互動記成 deliberate 事件的產生端。
enum MarkCommand {
    static let usage = """
        用法：ltm mark <presentation-id> <名次> (--opened | --cited | --pinned | --dismissed)

        對一次呈現裡的某一筆記一則互動事件。名次就是輸出上的編號（由 1 起算）。

        **目前只有 `ltm query --compare` 的呈現可以 mark**，識別碼印在它的
        footer 上。`--record` 只寫 `shown` 事件、不寫呈現紀錄，而名次要翻回
        anchor 需要那份紀錄——所以那條路徑上還沒有入口（具名缺口，非遺漏）。

        為什麼要記：使用歷史只由這四種事件推動。只有曝光（`shown`）等同於沒有
        事件——那是 spec 明寫的，不是實作細節。不記的話，`human-like` 與
        `archival` 的輸出必然相同，而比較實驗每一次都是平手。

        選項：
          --opened      開起來讀了
          --cited       在後續工作裡引用了它
          --pinned      刻意留住它
          --dismissed   看了但判定無關（**這是負向訊號**，會壓抑它）
          -h, --help    顯示本說明
        """

    /// 可記的事件種類。**封閉列舉**：`shown` 刻意不在裡面，它由呈現當下自動寫入。
    private static let kinds: [(flag: String, kind: EventKind)] = [
        ("opened", .opened), ("cited", .cited), ("pinned", .pinned), ("dismissed", .dismissed),
    ]

    static func run(arguments raw: [String]) -> Int32 {
        let arguments = Arguments(raw, valueOptions: [])
        if arguments.has("help") || arguments.has("h") {
            print(usage)
            return LTMCommandLine.ExitCode.success.rawValue
        }
        let unknown = arguments.unknown(known: Set(kinds.map(\.flag) + ["help", "h"]))
        guard unknown.isEmpty else {
            Output.error("✗ 未知選項：\(unknown.map { "--\($0)" }.joined(separator: ", "))\n\n\(usage)")
            return LTMCommandLine.ExitCode.usageError.rawValue
        }

        // **恰好一個種類**。零個是漏了，兩個是矛盾——`--opened --dismissed` 對同
        // 一筆同時說「有用」與「無關」，靜默取其一會讓使用歷史記到反向的東西。
        let chosen = kinds.filter { arguments.has($0.flag) }
        guard chosen.count == 1 else {
            Output.error(
                chosen.isEmpty
                    ? "✗ 要記哪一種？\n\n\(usage)"
                    : "✗ 一次只能記一種，收到：\(chosen.map { "--\($0.flag)" }.joined(separator: " "))")
            return LTMCommandLine.ExitCode.usageError.rawValue
        }

        let positional = arguments.positional
        guard positional.count == 2, let rank = Int(positional[1]),
            let uuid = UUID(uuidString: positional[0])
        else {
            Output.error("✗ 需要兩個引數：<presentation-id>（UUID）<名次>\n\n\(usage)")
            return LTMCommandLine.ExitCode.usageError.rawValue
        }

        do {
            let service = try CommandSupport.makeService(
                needsEventStore: true, needsRecordStore: true)
            let anchor = try service.mark(
                presentation: PresentationID(id: uuid), rank: rank, kind: chosen[0].kind)
            // **只印指標，不印內容**——與 `ltm memory` 同一條隱私紀律：這個命令的
            // 輸出會進 shell 歷史。
            print("✓ 已記 \(chosen[0].kind.rawValue)：第 \(rank) 筆，turn \(anchor.turnID)")
            return LTMCommandLine.ExitCode.success.rawValue
        } catch let error as LTMService.ServiceError {
            return QueryCommand.report(error)
        } catch {
            Output.error("✗ \(error)")
            return LTMCommandLine.ExitCode.indexStateError.rawValue
        }
    }
}
