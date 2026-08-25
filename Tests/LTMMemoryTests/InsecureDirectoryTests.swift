import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

// #22 item 14：`CanonicalStore.validatedPath` 的目錄安全檢查**一條測試都沒有**
// ——全樹零處提到 `insecureDirectory`。R6 修過它一次（改用解析後的父目錄），
// #20 又往裡面加了擁有者檢查與 stat fail-closed，兩次都沒有鎖。
//
// 「revert 之後全綠」是這一類缺口的定義。

@Test("葉節點是 symlink 時，檢查的是它真正會被寫進去的那個目錄")
func theDirectoryCheckFollowsTheLeafSymlink() throws {
    // R6 的原始缺陷：兩個檢查看的是不同的路徑。`isInsideReadOnlyCorpus` 走
    // `fullyResolve`（會解析最後一段），而權限檢查用
    // `deletingLastPathComponent()`——純字面。
    //
    // 於是 `~/safe/events.jsonl` 是個指向 `/tmp/pub/events.jsonl` 的 symlink 時，
    // 檢查的是 0700 的 `~/safe`，而 `open` 跟著連結寫進 world-writable 的目錄。
    let sandbox = try Sandbox()
    defer { sandbox.cleanup() }

    let exposed = try sandbox.directory("exposed", mode: 0o777)  // 非 sticky
    let safe = try sandbox.directory("safe", mode: 0o700)
    let link = safe.appendingPathComponent("events.jsonl")
    try FileManager.default.createSymbolicLink(
        at: link, withDestinationURL: exposed.appendingPathComponent("events.jsonl"))

    // 字面父層是 0700 的 `safe`；解析後的父層是 0777 的 `exposed`。
    #expect(throws: EventStoreError.self) { _ = try CanonicalStore.validatedPath(link) }
}

@Test("sticky 的 world-writable 目錄可以接受，非 sticky 的不行")
func stickyIsTheOnlyWorldWritableCaseAccepted() throws {
    let sandbox = try Sandbox()
    defer { sandbox.cleanup() }

    // `/tmp` 是 1777。sticky 讓非擁有者無法 unlink 或 rename 別人的既有檔案，
    // 所以那個組合是可接受的——**它擋的只有這個**（#20 item 4 更正了先前寫在
    // 這裡的理由：sticky 不擋建立，而 `open` 沒有 `O_NOFOLLOW`）。
    let sticky = try sandbox.directory("sticky", mode: 0o1777)
    #expect(throws: Never.self) {
        _ = try CanonicalStore.validatedPath(sticky.appendingPathComponent("events.jsonl"))
    }

    let open777 = try sandbox.directory("open777", mode: 0o777)
    #expect(throws: EventStoreError.self) {
        _ = try CanonicalStore.validatedPath(open777.appendingPathComponent("events.jsonl"))
    }
}

// MARK: - 未涵蓋的部分，具名而不假裝

// **擁有者檢查沒有測試**（#20 item 4 加的那條）：要造一個屬於別人的目錄需要
// 權限，單元測試做不到。同理 **`stat` 失敗的 fail-closed 分支**——要讓一個
// 讀得到的父層 stat 失敗，需要的條件測試造不出來。
//
// 兩者都是靠閱讀驗的，而那比上面兩條弱。寫在這裡而不是留白，因為一個看起來
// 完整的測試檔會讓下一個人以為這條守衛整體都有鎖。

private struct Sandbox {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ltm-insecure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func directory(_ name: String, mode: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    func cleanup() {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
}

@Test("寫入端也拒絕非一般檔案——用字元裝置，因為 FIFO 到不了那條分支")
func appendRejectsANonRegularFileOnTheWriteSide() throws {
    // #22 item 15：讀取端在 R7 補了會走到 `fstat` 的測試，寫入端沒有——而
    // issue 指出 FIFO 到不了那條分支。實測確認：
    //
    //   flock(FIFO)                          → errno 45（EOPNOTSUPP）
    //   open(FIFO, O_WRONLY|O_APPEND|O_CREAT) → errno 6（ENXIO，無讀者）
    //
    // 兩條都在 `S_IFREG` 檢查之前。**但那條分支不是不可達，只是 FIFO 選錯了
    // 探針**：字元裝置的 `open` 與 `flock` 都成功，而 `S_IFREG` 為 false。
    #expect(throws: EventStoreError.self) {
        try CanonicalStore.appendLine(Data("x\n".utf8), to: URL(fileURLWithPath: "/dev/null"))
    }
}
