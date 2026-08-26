import Foundation
import Testing

@testable import LTMCore
@testable import LTMMemory

// #1 verify R4 的核心指控：**把這一輪的招牌修復逐一 revert 掉，測試全部照過。**
// 也就是說測試數字（57 → 114）不是證據——它們沒有釘住任何一個修復。
//
// 這一檔的每一條都做過 A/B：把它守的那個修復拿掉，它必須變紅。做不到 A/B 的
// （例如「拒絕 FIFO」——測試本身會掛住而不是失敗）就寫明為什麼沒有測試，
// 不寫一條名字比證據強的。

private func tempDir(_ tag: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ltm-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - 語料守衛：R4 量到的四種穿透擺法

@Test func aDanglingLinkWhoseTargetPassesThroughASymlinkedDirectoryIsCaught() throws {
    // R4 的 A2：`A -> "linkdir/probe.jsonl"`，而 `linkdir -> <corpus>`。
    // 舊實作把 symlink 目標當**不透明字串**，目標路徑裡的 symlink 目錄不解析，
    // 於是守衛判「在外面」而 kernel 寫進語料裡。**沒有 `..`、沒有 hardlink、
    // 沒有競態**——純粹確定性的穿透。
    let dir = try tempDir("a2")
    let linkdir = dir.appendingPathComponent("linkdir")
    try FileManager.default.createSymbolicLink(at: linkdir, withDestinationURL: CorpusLocation.readOnlyRoot)

    let a = dir.appendingPathComponent("A")
    // 用 `atPath:withDestinationPath:`——`withDestinationURL:` 會把相對路徑
    // 變成絕對，那就測不到「相對目標」這一型了（我第一版就是這樣寫的，
    // 測試因此紅了，而紅得有道理）。
    try FileManager.default.createSymbolicLink(
        atPath: a.path, withDestinationPath: "linkdir/ltm-probe-never-created.jsonl")

    #expect(CorpusLocation.isInsideReadOnlyCorpus(a))
    #expect(throws: (any Error).self) { _ = try FileEventStore(url: a) }
}

@Test func aDanglingLinkWhoseAbsoluteTargetPassesThroughASymlinkedDirectoryIsCaught() throws {
    // R4 的 A3：同上但目標是絕對路徑。
    let dir = try tempDir("a3")
    let linkdir = dir.appendingPathComponent("linkdir")
    try FileManager.default.createSymbolicLink(at: linkdir, withDestinationURL: CorpusLocation.readOnlyRoot)

    let a = dir.appendingPathComponent("A")
    try FileManager.default.createSymbolicLink(
        at: a, withDestinationURL: linkdir.appendingPathComponent("ltm-probe-never-created.jsonl"))

    #expect(CorpusLocation.isInsideReadOnlyCorpus(a))
}

@Test func aDanglingLinkWhoseTargetContainsDotDotAfterASymlinkIsCaught() throws {
    // R4 的 A4：`A -> /work/linksub/../probe.jsonl`，而 `linksub -> <corpus>/sub`。
    // `..` 在 symlink 之後的語意是「解析後那個目錄的父層」＝ `<corpus>`，
    // 但舊實作對**目標字串**做了字面消解。
    //
    // **這條先前是恆真斷言**（#1 verify R5）：它寫成
    // `#expect(verdict || !fileExists(sub))`，而 `sub` 是測試自己刻意不建立的
    // 目錄，所以右半永遠為真、整個析取式與 verdict 無關。R5 實測印值：
    // `verdict = false`——守衛判「在語料外」，正是註解宣稱要確認不會發生的事，
    // 而測試照樣通過。`#expect(x || 恆真條件)` 這種寫法是「名字比證據強」的極端版。
    //
    // 修法有兩層：(a) 語料根改成**合成的**，測試自己建得出子目錄，於是不再
    // 依賴真實語料樹當下的內容；(b) 斷言改成無條件。
    let dir = try tempDir("a4")
    let corpus = dir.appendingPathComponent("synthetic-corpus")
    let sub = corpus.appendingPathComponent("sub")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

    let work = dir.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let linksub = work.appendingPathComponent("linksub")
    try FileManager.default.createSymbolicLink(at: linksub, withDestinationURL: sub)

    let a = work.appendingPathComponent("A")
    try FileManager.default.createSymbolicLink(
        atPath: a.path, withDestinationPath: "linksub/../ltm-probe-never-created.jsonl")

    #expect(CorpusLocation.isInside(a, root: corpus), "`..` 穿過 symlink 後落在語料裡")
    // 反向對照：同一個佈局下，真正落在語料外的路徑仍判為外。沒有這條，
    // 上面可以被一個 `return true` 滿足。
    #expect(!CorpusLocation.isInside(work.appendingPathComponent("plain.jsonl"), root: corpus))
}

/// 本機是否具備 firmlink 佈局（`/System/Volumes/Data` 前綴與語料根同 inode）。
///
/// 下面那條測試的**前提**。分開寫是因為它決定的是「這條能不能驗」，不是
/// 「驗的結果如何」——兩者混在一起就會得到一個機器相依的紅燈（#22 item 17）。
private var firmlinkLayoutPresent: Bool {
    let root = CorpusLocation.readOnlyRoot
    let alt = URL(fileURLWithPath: "/System/Volumes/Data" + root.path)
    guard let rootID = CorpusLocation.identity(root.path),
        let altID = CorpusLocation.identity(alt.path)
    else { return false }
    return rootID == altID
}

@Test(
    .enabled(
        if: firmlinkLayoutPresent,
        "此機器上 /System/Volumes/Data 前綴與語料根不是同一個 inode（或語料根不存在），firmlink 這條的前提不成立"
    ))
func anAlternateAbsolutePathToTheSameDirectoryIsRecognised() throws {
    // R5 的 HIGH：macOS 的 firmlink 讓 `~/.claude/projects` 與
    // `/System/Volumes/Data/Users/…/.claude/projects` 是**同一個 inode 的兩條
    // 穩定路徑**，而 `realpath(3)` 不會把後者正規化。舊的元件比對因此判「在外」，
    // 建構子照收，寫進去的檔案出現在語料裡——不變式 1 被違反且無錯誤。
    //
    // 這條只做 `stat`，不建立也不寫入任何東西在語料樹裡。
    let root = CorpusLocation.readOnlyRoot
    let alt = URL(fileURLWithPath: "/System/Volumes/Data" + root.path)

    // 前提由 `.enabled(if:)` 擋在外面（#22 item 17）。先前是在 body 裡
    // `Issue.record` 然後 return——那讓缺少該佈局的機器得到一個**紅燈**，於是
    // 「測試全綠」變成一句機器相依的宣稱。skip 帶理由才是誠實的形狀：沒驗到
    // 仍然看得見，但它不冒充成失敗。

    let target = alt.appendingPathComponent("ltm-firmlink-probe-never-written.jsonl")
    #expect(CorpusLocation.isInsideReadOnlyCorpus(target), "同一個 inode 的另一條路徑必須判為在語料內")
    #expect(throws: (any Error).self) { _ = try FileEventStore(url: target) }
}

@Test func anOrdinaryTemporaryPathIsStillAccepted() throws {
    // 反向確認：新的解析沒有把所有東西都判成「在語料裡」。沒有這條，
    // 上面三條可以被一個 `return true` 滿足。
    let dir = try tempDir("ok")
    #expect(!CorpusLocation.isInsideReadOnlyCorpus(dir.appendingPathComponent("events.jsonl")))
    #expect(throws: Never.self) { _ = try FileEventStore(url: dir.appendingPathComponent("events.jsonl")) }
}

@Test func aSiblingPrefixPathIsNotMistakenForBeingInsideTheCorpus() throws {
    // 元件比對而非字串前綴：`~/.claude/projectsX` 不在 `~/.claude/projects` 底下。
    let sibling = CorpusLocation.readOnlyRoot.deletingLastPathComponent()
        .appendingPathComponent("projectsX")
        .appendingPathComponent("events.jsonl")
    #expect(!CorpusLocation.isInsideReadOnlyCorpus(sibling))
}

// MARK: - 空 span：驗證器與**每一個入口**各自被釘住

@Test func theMemberwiseInitialiserRejectsAnEmptySpan() throws {
    // R4 CRITICAL：R3 抓到空 span 之後，我補了 decode 與 turn-based 兩個入口，
    // **漏掉 memberwise**——萬用 anchor 仍造得出來：
    //
    //     Anchor(source: "s", turnID: "t", contentHash: Anchor.hash("", key: .forTesting), span: 3..<3)
    //
    // 它對任何 scalar 數 ≥ 3 的 turn 都 `.resolved("")`，即使來源整段被換掉。
    //
    // **這條的自辯在 R5 被推翻了，留著當紀錄。** 原本寫的是「這裡測的是共用
    // 驗證器而不是某一個入口——入口會再長出來，判準不會」。不成立：抽出驗證器
    // 不會讓呼叫端去呼叫它，而 R4 抓到的缺陷正是「有一個入口沒呼叫」。R5 實測
    // 把 memberwise 裡的 `try Anchor.validate(span:)` 整段刪掉，測試全綠；把
    // `init(source:turn:span:)` 的 guard 改回 `?? ""` 也全綠——兩個入口的修復
    // 都可以無聲 revert。
    //
    // 判準要生效必須有測試站在入口上，見本檔末尾的 exit test。
    #expect(throws: Anchor.SpanValidationError.empty(3..<3)) { try Anchor.validate(span: 3..<3) }
    #expect(throws: Anchor.SpanValidationError.negativeLowerBound(-1..<2)) {
        try Anchor.validate(span: -1..<2)
    }
    #expect(throws: Never.self) { try Anchor.validate(span: 0..<1) }
}


// MARK: - 入口本身（R5：驗證器有測試，入口沒有）

@Test func theMemberwiseInitialiserTrapsOnAnEmptySpan() async {
    // R4 修的是**入口**（memberwise init 呼叫共用驗證器），而 R4 補的測試只驗
    // 了驗證器。R5 實測：把入口那段刪掉，141 條全綠。
    //
    // 入口用 `preconditionFailure` 而不是 throw（它是程式錯誤，不是外來資料），
    // 所以只能用 exit test 站上去——那正是 Swift Testing 的 exit test 存在的理由。
    await #expect(processExitsWith: .failure) {
        _ = Anchor(
            source: "s", turnID: "t",
            contentHash: Anchor.hash("任意合成文字", key: .forTesting), span: 3..<3)
    }
}

@Test func theTurnBasedInitialiserTrapsWhenTheSpanIsOutOfBounds() async {
    // 第二個入口，同樣沒被釘住：R5 實測把它的 guard 改回 R3 的 `?? ""`，全綠。
    // 越界 span 取不到文字，`?? ""` 會讓 hash 變成 `sha256("")`——又一個萬用 anchor。
    await #expect(processExitsWith: .failure) {
        let turn = Turn(
            id: "t1", role: "user", timestamp: Date(timeIntervalSince1970: 1), text: "短")
        _ = Anchor(source: "s", turn: turn, span: 50..<60, key: .forTesting)
    }
}

@Test func theMemberwiseInitialiserAcceptsAValidSpan() {
    // 反向對照：exit test 只證明「會死」，不證明它死得有道理。沒有這條，
    // 一個無條件 trap 的建構子也能讓上面兩條變綠。
    let anchor = Anchor(source: "s", turnID: "t", contentHash: Anchor.hash("abc", key: .forTesting), span: 0..<3)
    #expect(anchor.span == 0..<3)
}

// MARK: - #40：「stat 不到」的兩種意思，姿態相反

/// 語料根**看不到**（EACCES）時守衛必須 fail closed。
///
/// 這是 #40 診斷出來的第三件事，而它不在該 issue 提的兩個選項裡：那兩個選項
/// （實作 `openat` vs 接受並明寫）都把限度當成**攻擊者才碰得到**的東西。這一條
/// 是**意外可達**的——權限漂移、換使用者、sandbox——而它的失效方向是放行。
///
/// **這條測試自己糾正過一次我的修法。** 第一版加了一個三態的 `rootIdentity`
/// （把「確定不存在」與「不知道」分開、後者 fail closed），而變異測試顯示退掉
/// 它零測試變紅——真正在扛的是元件比對兩邊改用同一個解析器。三態因此被移除：
/// 構造不出「根 stat 不到但解析得到」的輸入，那個分支沒有執行點。
///
/// 破壞實作確認過會紅：把元件比對的 `Self.fullyResolve(root.path)` 改回
/// `Self.realpath(root.path)`，這條與下面那條會一起紅。
@Test("語料根不可讀時，守衛拒絕而不是放行")
func unreadableCorpusRootRefusesRatherThanAllowing() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("ltm-40-\(UUID().uuidString)")
    let outer = base.appendingPathComponent("outer")
    let root = outer.appendingPathComponent("projects")
    let target = root.appendingPathComponent("proj/s.jsonl")
    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outer.path)
        try? fm.removeItem(at: base)
    }

    // 前提：可讀時擋得住。不先確認這件事，下面的斷言可能只是「一直都 true」。
    #expect(CorpusLocation.isInside(target, root: root), "可讀時語料根的子檔本來就該被擋")

    try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: outer.path)
    var info = stat()
    _ = stat(root.path, &info)
    try #require(errno == EACCES, "這個探針要的是 EACCES，實際 errno=\(errno)")

    #expect(
        CorpusLocation.isInside(target, root: root),
        "語料根 stat 不到時要當成在語料內（不變式 1：不確定就不要寫）")
}

/// 對照組：語料根**確定不存在**（ENOENT）時不該一併變成恆真。
///
/// 沒有這條，上面那條可以被「`isInside` 永遠回 true」滿足——而那會讓整個記憶層
/// 寫不進去，卻仍然「通過測試」。
@Test("語料根確定不存在時，語料外的路徑仍判為在外")
func absentCorpusRootStillAllowsPathsOutsideIt() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("ltm-40b-\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let absentRoot = base.appendingPathComponent("never-created/projects")
    let outside = base.appendingPathComponent("elsewhere/events.jsonl")
    try fm.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)

    #expect(CorpusLocation.identity(absentRoot.path) == nil, "前提：這個根真的不存在")
    #expect(
        !CorpusLocation.isInside(outside, root: absentRoot),
        "根確定不存在時，沒有東西在它裡面——這條路徑必須仍然可寫")
}

/// 元件比對的兩邊要用**同一個解析器**。
///
/// macOS 的 `temporaryDirectory` 給 `/var/…`，`realpath` 給 `/private/var/…`
/// （`CLAUDE.md` 記過這個坑）。先前根走 `realpath`、目標走 `fullyResolve`，
/// 根解析失敗退回字面路徑時兩邊形式不同，比對永遠落空。
@Test("語料根不存在時，字面落在它底下的路徑仍判為在內")
func componentFallbackResolvesBothSidesTheSameWay() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("ltm-40c-\(UUID().uuidString)")
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }

    let absentRoot = base.appendingPathComponent("projects")
    let inside = absentRoot.appendingPathComponent("proj/s.jsonl")

    #expect(CorpusLocation.identity(absentRoot.path) == nil, "前提：這個根真的不存在")
    #expect(
        CorpusLocation.isInside(inside, root: absentRoot),
        "根還沒被建立，但這條路徑就在它底下——元件比對要抓得到")
}
