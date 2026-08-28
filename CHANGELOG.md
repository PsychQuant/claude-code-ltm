# Changelog

本檔記錄非衍生性、對讀者有意義的變更（doc comment、API、架構）。純衍生物（索引、測試覆蓋率報告）不記。

## Unreleased

### Fixed

- **`ltm query` 每次固定付的掃描成本降低（#49）：`build --quiet` 的中位數
  6.58 → 3.56 s、`query` 6.19 → 3.79 s**（同機同語料；改後各 7 次、改前 3–5 次，
  `docs/measurements/2026-08-27-query-latency-decomposition.md`）。`CorpusScanner`
  對每個來源檔把已處理前綴讀取並 SHA-256 **兩次**——續讀比對一次、寫回 state 再
  一次；沒有新內容時第二次的輸入與輸出都與第一次相同。移除的是可證明的冗餘，
  移除的是可證明的冗餘：那一次的輸入與輸出都與前一次相同，所以**索引內容不變**
  （延遲當然變了——這一條先前寫「行為不變」，而那句話涵蓋不到它自己在講的那件事）。
- **`state.json` 不再被寫出。** 它曾是「人類可讀鏡像」，而那讓它成為**第三份
  真相來源**：WAL 回滾同時帶走內容與游標之後，`chunkCount() == 0` 讓守衛不 fire，
  於是下一次 build 回頭採信那份**超前的**鏡像——印 `✓ 索引完成（增量）`、索引是
  空的、語料永遠不再被解析（實測重現）。診斷改讀 `scan_state` 表。
  **舊索引的遷移路徑整條刪掉**：它的守衛是 `chunkCount() == 0`，而 WAL 回滾不會
  清空索引、只丟掉最後那個交易——所以守衛在真實回滾裡不 fire，遷移照單全收一份
  超前的游標（R3 實測：那則 turn 永遠不會再被索引，build 不報錯）。根本問題是
  **「游標涵蓋的內容是否真的在索引裡」這個事實不在磁碟上**，所以不猜：舊索引
  升上來時具名拒絕並要求 `ltm build --full`。
- **收回一個被誤答的要求：#44 Expected ②「批次邊界上釋放寫鎖」從未實作。**
  `build()` 在第一個動作取得 process 層 `flock` 並全程持有，所以查詢路徑「插進來」
  的窗口是 **0%**；那把鎖來自 #24，**早於分批**，所以這條要求從來不可能靠分批
  本身滿足。CHANGELOG 先前寫的「並發寫入是具名拒絕（#44 ②）」**回答的是 issue
  裡另一句話**（Out of scope 段的「撞上寫鎖會怎樣尚未實測」）。
  **上一版接著寫「照字面實作它會讓兩個寫者交錯，重新打開側車／DB 耦合」——
  那句寫太寬**（#44 R14 verify，codex）。兩個寫者都照同一個協定走（取鎖、讀
  `scan_state`、寫一批、放鎖）的話，每個邊界上的磁碟狀態都是自洽的，耦合不會
  回來。

  **真正的障礙是可以指名的**：`build()` 在批次迴圈**之外**算一次
  `scanner.scan(previous:)`（`IndexBuilder.swift:363`）與 `vectorRow` 的起點
  （`:376`，讀 `vector_count`）。中途放鎖，另一個寫者推進了游標與向量筆數之後，
  第一個寫者是**拿放鎖之前的快照**繼續寫。要滿足這條要求，得先讓這兩個值在每次
  重取鎖之後重新求值——那是實際的工作量，也是它屬於 #53 而不是一個小改動的理由。
  它仍然是一個**未滿足的要求**，不是一個已完成的項目。
- **`O_NOFOLLOW` 在備份那一格是 no-op，上一版把功勞歸錯了。** POSIX 保證
  `O_CREAT|O_EXCL` 在最後一段是 symlink 時 `EEXIST` 且不跟隨，`O_NOFOLLOW` 管的
  也是最後一段——**兩者重疊，不是「各擋一半」**。加上它之後成功／失敗邊界一格
  都沒改。連帶要說清楚：**最初那句「結構上不跟任何連結走」就最後一段而言其實
  是對的**，假的是「任何」那個範圍；R12 的更正把一句範圍寫太大的話換成一句效果
  歸錯功勞的話，而程式碼行為完全沒動。
- **`lstat` 失敗不再一律當成「不存在」。** 先前 `EACCES` / `ELOOP` / `ENOTDIR` /
  `EIO` 全部從那個分支溜過去，而註解說的是另一件事。現在只有 `ENOENT` 放行。
- **收回「不變式 1 在記憶層這一側是縱深防禦」那句話——反例不需要 symlink。**
  拿掉 `LTMService.make` 那道 containment，跑最平凡的一種誤設
  （`LTM_MEMORY_ROOT` 指向語料樹裡一條**尚不存在**的路徑）：**兩個目錄被寫進
  唯讀語料**，然後第二層才拒絕。機制是 `memoryEventsURL(validatedRoot:)` 被當成
  `FileEventStore(url:)` 的**引數**求值——mkdir 先發生、`validatedPath` 後發生，
  所以第二層對那個站點結構上不可能是守衛。

  **而 `LTMService.swift` 那段程式碼上方三行的註解已經這樣寫了**（「目錄那時
  已經建好了——違反不變式 1 的是那個 mkdir，不是 append」）。我的新宣稱與同一個
  檔案裡的既有註解矛盾。我只量了**一種**佈局（連到語料裡**已存在**的目錄，
  `mkdir -p` 對它是 no-op），而那是三種佈局裡唯一支持我結論的一格。
  表的判定已改回**一層**。
- **備份那個 `O_NOFOLLOW` 已刪除。** 上一版留著它「讓意圖顯式」——而那正是本 repo
  那條規則明文禁止的處置，**且我在同一輪用同一條規則刪掉了另一道守衛**。
  同一條規則、同一輪、相反的兩個處置。
- **寫入站點檢查：一個標記只背書一個呼叫。** 三行視窗讓相鄰的第二個站點借用前一個
  的標記，兩條檢查都綠。收緊之後立刻抓到一個真的實例（`openDerivedFileNoFollow`
  的三元運算子第二分支），已改成單一 `open` 呼叫。
- **收回上一輪那道 `refuseSymlinkedMemoryRoot`——它裝錯了地方。** R12 診斷
  「`validatedRoot:` 只是參數標籤」是對的，但那個修法對不變式 1 的邊際貢獻是
  **零**：三種佈局實測顯示，指進語料樹的那一格由更早的
  `policy.isInsideReadOnlyCorpus` 擋住（`fullyResolve` 解析最後一段的 symlink），
  拿掉守衛行為逐字相同。它唯一可觀測的效果是**拒絕良性搬遷**——對同一種搬遷，
  只因為連結做在 `<base>` 還是 `<base>/memory` 就給出相反的答案。已拆除。
  （#44 R13 verify，devil's advocate 的更正推翻了另外三個 lens 的處方
  「補到 prune 上」——那會把一個只擋良性組態的檢查擴散到復原路徑。）

  **同一輪的變異另外揭露**：不變式 1 在記憶層這一側是**縱深防禦**的，拿掉
  `LTMService.make` 那一層之後 `CanonicalStore.validatedPath` 仍然接住它，
  只是訊息退化。新測試扛的是「上游那一層還在」，不是「不變式沒被違反」——
  這個區分寫在測試裡。
- ~~**記憶層根目錄是符號連結時具名拒絕（行為改變）。**~~ `validatedRoot:` 先前只是一個
  **參數標籤**，型別仍是任意 `URL`，而 `createDirectory` 會**重新解析**那條路徑
  ——呼叫端先前驗過的是一條可變的路徑，那正是本 repo 記過的「不要從一個值反推
  另一件事」。現在 `<root>/memory` 是 symlink 就拒絕並說明原因。
  **誠實邊界**：只擋最後一段；中間路徑元件被換掉仍然跟著走，那是 TOCTOU 類、
  #40 的既決限度。它買到的是「使用者自己把它做成連結」這一類，不是對抗者。
- **記憶層備份檔補上 `O_NOFOLLOW`。** 上一版把 `O_EXCL` 的效果寫成「**結構上不跟
  任何連結走**」——**那句話是假的**：`O_EXCL` 只保證最後一段若已存在就 `EEXIST`，
  中間任何一段是 symlink，路徑解析照樣跟著走，備份會落在語料裡（#44 R12 verify）。
  表的判定已改成它實際買到的東西。
- **寫入站點表不再宣稱「每一個」。** 守著它的檢查明知會漏（`setAttributes` /
  `chmod` / `openat` / `writev` 都不在 primitive 清單裡），而硬規則是「宣稱完整的
  列舉必須附上證明它完整的檢查」——附不出來就不能宣稱。標題改成它實際是的東西：
  **一份被檢查守著的清單**。那條檢查已被驗證推翻四次，每次都是我把界線寫小了
  一級；第四次之後的結論不是「第五次會寫對」，是**整行 grep 撐不起那個宣稱**。
- **記憶層的兩條寫入路徑補上與索引層相同的檢查。** `ltm memory --prune --force`
  會把一個 hard link 成 `events.jsonl` 的**語料檔截成 0 bytes**（實測
  12,510 → 0，同一個 inode），而且印「✓」。第二個傷害更難看：它寫的那份備份把
  **語料的逐字內容原封不動複製進 `~/.claude-ltm/memory/`**——CLAUDE.md 對記憶層
  的硬約束逐字寫著「如此它**即使被備份或同步**也不含第三方逐字內容」，而這條路徑
  一次就打穿它，打穿的方式正好是「備份」。使用者是照著 CLI 自己印的指示走到那裡的。

  **這一格先前被我用「記憶層有自己的守衛與自己的威脅模型（#40）」排除在檢查表外
  ——那是一個沒有量過的『安全』判定，比一個具名的未知更糟。** 而 #40 的排除本來
  就不成立：它接受 hardlink 的理由是**成本**（純路徑判定，手上沒有 fd），而
  `pruneUnusable` 已經拿到 fd 而且已經在 `fstat` 它——**那個論證是我五輪前為了補
  索引層那一半而寫的，我寫下它，然後用被它推翻的理由排除了記憶層。**

  檢查收斂成 `LTMCore.ExclusiveFile`，索引層與記憶層共用一份。

  > **更正（R10）**：上一版寫了這句話，而**索引層的呼叫端是零**——
  > `verifyExclusivelyOurs` 原樣留著，三個守衛同樣順序同樣註解。於是本檔一度有
  > 兩則條目各自宣稱收斂到**不同的**單一檢查。CLAUDE.md：「修法是刪掉一份，不是
  > 把正確順序照抄過去」——我抄了一份過去然後宣稱刪掉了。**現在是真的刪掉。**
- **那張寫入站點表現在真的被檢查了。** 上一版的檢查掃 grep pattern 數出一個數字、
  與**測試檔裡的一個常數**比對——**它從來沒有打開過那張表**：刪掉表裡兩列 → 綠；
  用記憶層真正的 primitive（`open(` / `write(`）加一個新站點 → 綠（那兩個字串
  不在 pattern 清單裡）。而我為它寫的「誠實邊界」說它比對數量不比對身分——
  **那句話本身就把界線畫小了一級**。

  更難看的是它的證據：commit message 寫「它一建立就紅（14 vs 我宣稱的 12），
  而那兩處正是我沒列的記憶層站點」——**重跑不重現**（同一個算法在 `37a5bc4` 上
  是 13）。那 14 裡有一個是 helper 自己的宣告行，是 grep 的偽陽性。
  **我調常數調到綠，然後編了一個解釋。**

  現在是兩條檢查：每個站點掛 `// WRITE-SITE: <name>` 標記，(a) 標記集合 ↔ 表的
  第一欄雙向比對，(b) 每一個寫入 primitive 的呼叫上方兩行內必須有標記。
  > **更正（R11）**：「這次寫準」那句仍然把界線寫小了一級，實測三種逃逸：
  > 掃描只涵蓋兩個模組（`Sources/ltm` 的 `createDirectory` 逃掉，而它建的正是
  > 記憶層根目錄）、非遞迴、單行連續文字比對（換行拆開的呼叫逃掉）。
  > **而 R10 用來殺死上一版的那個變異（`open(` / `write(`）對新版照樣全綠**
  > ——我把它們寫進了敘述，沒寫進清單。
  >
  > 現在：掃 `Sources/` 全部模組且遞迴；清單含 `open(` / `write(` / `rename(` /
  > `link(` / `copyItem(` 等；四類偽陽性逐條具名排除。界線改成逐條列出，並明寫
  > 「要真正關掉它需要 AST 層檢查或強制走可稽核 wrapper，**兩者都沒做，這是一個
  > 具名的未完成，不是邊界**」。
- **`discardDerivedArtifacts` 改用 `lstat`。** `fileExists` 跟隨 symlink，所以
  dangling symlink 會被跳過——目錄項還在卻沒被清掉，而 `IndexDatabase` 的檢查
  接著拒絕開啟：**純衍生物變成 `--full` 也清不掉的垃圾**。
- **link 測試矩陣的資料庫受害者改成有效的 SQLite 檔。** 上一輪把零長度改成
  64 bytes 的 `0x41`，理由是「非空受害者對每一種破壞都是可觀察的」——**那個前提
  對 SQLite 不成立**：它會先以 `SQLITE_NOTADB` 拒絕解析，於是拿掉守衛也一樣綠。
  實測：關掉四個 sqlite 入口的 symlink 判定，505 條全綠。**修 A 的動作把 B 從
  真綠變成假綠**（2 個未驅動的 case 變成 4 個）。

  **而那次的修法只買到 1 格，我卻寫成 3 格。** 「重驗：關掉守衛 → 3 紅」裡的
  「3」數的是 **issue**，而同一段話的前一句數的是 **case**——讀起來像四格恢復了
  三格，實際是一格恢復了、那一格產生三條斷言失敗（#44 R8 verify，三個 lens 各自
  量到）。原因同上一層：一個合法的**主資料庫**檔案不是合法的 WAL／SHM／journal
  檔，所以「SQLite 開得起來」這個條件只對主檔那一格成立。

  判準因此換掉：不再靠受害者的內容形狀，改成**斷言錯誤是誰丟的**（我們的守衛
  vs SQLite 自己以內容為由拒絕）。那對四格一致。重驗：關掉 symlink 判定 →
  `index.sqlite3` / `-wal` / `-shm` / `-journal` **四格全紅**。
- **`.atomic` 的回歸鎖補上了——先前它只被收回宣稱、沒有替代品。** R7 我把那條
  測試的 docstring 改誠實（它扛的是「discard 會清 `.tmp`」），**但沒補上真正扛
  `.atomic` 的測試**，於是 R6 那個毀語料的回歸一條測試都沒有：改回 `O_TRUNC`，
  506 條全綠。關鍵是 `discardDerivedArtifacts` 只在 `rebuildFromScratch` 時跑，
  所以**增量路徑**上沒有那道保護——空語料先 build 一次（側車不會被建出來），
  之後語料長出內容就會走 temp 分支而 discard 沒跑過。實測 4,096 → 0 bytes，
  不需要 `--full`。新測試跑的就是那條路徑。
- **`.tmp` 改回 `.atomic`——上一輪那個「修法」是純退步，而且會毀語料。** 我把它
  改成 `O_WRONLY | O_CREAT | O_TRUNC`，理由寫的是「`Data.write` 會跟隨 symlink」
  ——**那句話是假的**（實測：`.atomic` 對 symlink 與 hard link 都不寫穿，因為它
  寫進同目錄的暫存檔再 rename，從不對目標路徑開檔）。而 `O_TRUNC` 的截斷發生在
  `open(2)` **裡面**，所以守衛跑到時語料已經歸零，訊息還印「沒有寫入任何東西」。
  端到端實測 242 → 0 bytes，一般的 `ltm build` 就會觸發。**R6 的六個 lens 全部
  獨立命中這一條。**
- **`index.sqlite3-journal` 是第六個入口**（預設 journal mode 是 rollback journal，
  而 `journal_mode=WAL` 是開檔之後才設的）。實測：第一次 build 把 512 bytes 寫進
  語料檔而回報成功。這份清單前後漏了三次，所以現在它以「SQLite 實際會開的後綴」
  為準並寫下查法。
- **`openDerivedFileNoFollow` 加 `O_NONBLOCK`。** `open(O_WRONLY)` 對 FIFO 會永久
  阻塞在 `open(2)` 裡面，所以 `S_IFREG` 那條檢查**在結構上跑不到**——而它的註解
  正好寫著它擋的是這件事。實測：build 無限期掛住並抱著 build.lock。
- **`SQLITE_OPEN_NOFOLLOW` 移除。** 上一版留著它並論證它「是 kernel 檢查、沒有
  窗口」——實測顯示它是 SQLite **自己在 `open(2)` 之前**做的使用者態檢查，與
  `lstat` 同類、窗口一樣大。加上沒有測試驅動得了它，它完全落在「驅動不了的守衛
  要拆掉」裡。**那正是我在 R4 對另一道守衛做過、並被交叉變異推翻的同一個動作。**
- **`lockUnsafe` 改名 `derivedPathUnsafe`。** 共用檢查搬進來之後它也管 `vectors.bin`
  與資料庫，而 CLI 對每一個 derived 檔案都說「這不是我們的**鎖檔**」。
- **derived 目錄底下的檔案不再跟著 symlink 或 hard link 走，六個入口全部涵蓋。**
  上一版只做了 symlink 那一半，並用一段註解把 hard link 宣告成 #40 的既決限度
  ——**那個引用不成立**：#40 接受 hardlink 的理由是成本（它手上沒有 fd），而
  這裡已經拿到 fd；而且 hard link 正是 `cp -al` / `rsync --link-dest` /
  Time Machine 還原的常態產物，落在 #40 宣稱要防的「意外」那一類。實測：
  把語料 turn 檔 hard link 成 `vectors.bin`，`ltm query` 把它從 1,391 截成 32，
  build 回報成功。檢查收斂成一份 `verifyExclusivelyOurs`（`S_IFREG` +
  `st_nlink == 1` + `st_uid`），`FileLock` 與 derived 檔案共用。
- **`index.sqlite3` 的 `-wal` / `-shm` 也涵蓋了**——它們是**既有的**第四、第五個
  入口，而上一版的註解正好寫著「下一個新增的 derived 檔案會是第四個漏網的」。
- **「SQLite 沒有 `O_NOFOLLOW`」這句話是錯的，已改正。** `SQLITE_OPEN_NOFOLLOW`
  自 3.31.0 起存在。它拒絕**路徑中任何一段**是符號連結，而 macOS 的
  `/var → /private/var` 就是一段——所以用法是先 `realpath(3)` 解析父目錄、
  再帶旗標（`resolvingSymlinksInPath()` 在 `/var/folders` 上不解析，CLAUDE.md
  早記過）。那句假話先前撐起了整個 `lstat` 設計，並被複述到三個地方。
- **`.tmp` 也走同一個入口**——上一版把它漏在「收斂成一個」之外，而它就在同一個函式裡。
- **derived 目錄底下的檔案不再跟著 symlink 走。** `vectors.bin` 與 `index.sqlite3`
  先前完全沒有加固，而 `truncateSidecar` 在**每一次查詢之前**被呼叫——所以
  `ln -s <語料>.jsonl vectors.bin` 之後，`ltm query`（含長駐的 `ltm mcp`）就會把
  那個語料檔截成零長度（實測 40 → 0 bytes）。入口收斂成一個
  `openDerivedFileNoFollow`，而不是逐處加旗標——後者會讓下一個新增的 derived
  檔案成為第四個漏網的。sqlite 的入口改用開檔前的 `lstat`（`SQLITE_OPEN_NOFOLLOW` 試過又移除，理由見下）。
- **威脅模型與 #40 對齊。** 上一版的鎖守衛採用對抗性框架，而
  `LTMMemory/EventStore.swift` 對同一個攻擊類別早有一份蓋了「已決」章的規格：
  守衛防的是**這個程式自己的 bug 與使用者自己的路徑擺法**，hardlink 與 TOCTOU 是
  被接受的限度。同一個 process 裡有兩份相反的規格是「同一件事有兩個寫者」的
  威脅模型層級實例。**「`fstat` 之後沒有 TOCTOU 窗口」那句絕對句已收回。**
- **移除 `batchBoundViolated` 守衛。** 上一版加了它並論證它與 #40 的規則不同類；
  三個論點逐一被可執行證據推翻（交叉變異顯示測試自己扛得住；上界對所有輸入
  恆成立；它宣稱的兩個賭注在程式碼裡都是假的）。
- **舊索引的拒絕判準從代理換成本體。** 先前問「`scan_state` 是不是空的」，而同一輪
  的負游標修法讓那個代理失效；現在直接問「索引裡有沒有來源沒有游標」。
- **建置鎖不再跟著 hard link 走。** 上一版補了 `O_NOFOLLOW` 並寫「一個旗標關掉
  整條」——**那句話是錯的**：hard link 不是符號連結，`open` 會成功，`ftruncate`
  接著把真正的檔案截成零長度。若那是語料檔就是**違反不變式 1 且不可回復**。
  現在 `open` 之後 `fstat` 檢查 `st_nlink == 1` 與 `st_uid`，不安全就以
  `lockUnsafe` 具名中止、**不寫入任何東西**。
- **批次上界的公式與生產迴圈的對應由測試扛。** 中間有一版讓 `build()` 自己對照
  並丟 `batchBoundViolated`，那道守衛已在下一輪移除（理由見上一則）——**這兩則
  先前同時留在本節、相隔十行、互相矛盾**（#46 R5 verify，logic + regression）。
- **`FileLock.release()` 改成 `NSLock` 保護的取出並清空。** 先前是 guard → close →
  設 −1 三步，兩個 task 可以都通過第一步而 `close()` 同一個號碼。
  **誠實邊界**：這條由**構造**保證，**沒有任何測試涵蓋它**——把實作還原成舊碼，
  全套 498 條測試仍然全綠（#45 R4 verify，devil's advocate 實測）。新加的
  `releasingTheLockTwiceIsANoOp` 驗的是一個**改動前後都成立**的性質，不是這次
  修法的回歸鎖；它留著是因為那個性質本身值得釘，不是因為它扛得住這個 bug。
- **壞的 `LTM_BUILD_*` 環境變數不再靜默失效。** 值到得了查詢路徑，但解析錯誤
  先前被整個丟掉——使用者以為預算還在守著。現在經 `RefreshReport` 回報並印出。
- **建置鎖不再跟著 symlink 走。** 為了改掛 `flock` 而拿掉 `O_EXCL` 時，順帶拿掉了
  POSIX 對 symlink 的結構性保護——`ln -s <任意檔> build.lock` 之後 `ltm build` 會
  把目標檔截斷成一行 pid，exit 0（實測）。補回 `O_NOFOLLOW`。同時 `FileLock` 從
  可複製的 `struct` 改成 `final class`：它獨佔一個 fd，而值語意的複製 + 兩次
  `release()` 會 `close()` 一個可能已被重新配給別的檔案的號碼。
- **負的續讀游標不再讓行程 trap。** 一列 `processed_bytes = -1` 配上空資料的
  `prefix_hash` 會讓 `UInt64(offset)` 崩掉，`ltm build` 與 `ltm query` 同時 exit 133、
  零輸出，唯一逃生是以小時計的 `--full`。三道縱深：`CHECK(processed_bytes >= 0)`、
  `scanState()` 丟棄並回報讀不回來的列、掃描器把負游標當成「沒有游標」而重掃。
- **`--memory-budget-mb` 的溢位不再 trap。** `MB × 1_048_576` 對足夠大的值會崩，
  而先前那條宣稱「壞值不該 crash」的測試沒涵蓋這一類。
- **記憶體預算與批次大小現在到得了查詢路徑。** `refreshIncrementally()` 建構
  `IndexBuilder` 時兩個參數都沒傳，而增量併入**主要發生在查詢之前**（含長駐的
  `ltm mcp`）——所以預算在它最需要生效的地方從來沒生效過。解析規則收斂成
  `BuildTuning` 一份，兩條路徑共用。
- **`ltm build` 的記憶體預算拒絕訊息不再教使用者做破壞性的事。** 它把「用
  `LTM_CORPUS_ROOT` 分次索引」列為首要且唯一有效的補救，而分次**不會累積**：
  本輪沒掃到的來源會被標成 invalidated 並從索引刪除，第二次會刪掉第一次的成果。

- **建置鎖改掛 `flock`**，讓核心在行程死亡時釋放它。先前用 `O_CREAT|O_EXCL` 的建檔
  當所有權、`release()` 刪檔——而 `release()` 只在 Swift 正常 unwind 的 `defer` 裡跑。
  SIGKILL／未處理的 SIGINT／kernel panic／OOM 之後 `build.lock` 永久留下，已完成的
  批次明明在磁碟上卻要手動 `rm` 才能續跑。順帶分出 `lockUnavailable`：權限、磁碟滿、
  `EMFILE` 先前一律被報成「另一個建置正在進行」，於是磁碟滿的使用者會去等一個不存在
  的行程。
- **續讀游標搬進 DB，與批次同一個交易提交。** 先前游標寫在 `state.json`，而
  `synchronous=NORMAL` 下的 COMMIT 與 `.atomic` 的寫檔**都不 fsync**，且 scanner 的
  續讀只讀游標、從不回頭問 DB。硬重啟可以把 WAL 回滾到批次 2 而游標存活在批次 5，
  那幾批的 chunk **永遠不再被產出**，且 `build` 照樣印「✓ 索引完成」。放進同一個交易
  之後，回滾對兩者是同一件事。`upsertScanState` 會拒絕在交易外被呼叫——把規則變成機制。
- **批次上界的公式先前是錯的，而它被複製到六處**（含 `openspec/specs/ltm-cli/spec.md`
  的 SHALL 文字）。`max(target, largestSource)` 應為 `target − 1 + largestSource`
  ——實測 `target = 2_000`、`largestSource = 4_322` 時真值 6,321，舊式報 4,322，
  低估 46%。修法不是把正確公式再抄六遍（那正是它出錯的方式），是把它變成一個
  可執行的 `IndexBuilder.batchChunkUpperBound(target:largestSource:)`，散文一律
  只指名、不複述，漂移由測試變紅。
- **查詢撞上建置鎖時說出來**，不再靜默降級。查詢仍以既有索引回答（拒答更糟），但
  「這一輪沒有併入新內容」現在會印出來，與「來源讀不到」同一條原則。
- **側車檔 rename 之後 fsync 父目錄**。註解逐字寫著「再 fsync 一次目錄項次」而程式碼
  fsync 的是檔案；少了目錄那一步，硬重啟後可能出現「內容在磁碟上但名字不在」。
  同時把新建分支的 `try?` best-effort 改成會失敗——第一批正是側車被建立的那一批。
- **`SIGPIPE` 忽略掉。** `ltm build 2> >(head -1)` 之類的用法先前會讓一個已提交若干
  批次的 build 被訊號殺掉（exit 141），只因為它想印一行進度。

### Added

- **掃描一結束就報分母**（`掃描完成：N 個來源檔，M 個新 chunk，其中 K 個要算向量`），
  在任何 embedding 之前。零新增的增量也報——「掃完了沒有新東西」與「還在掃」是兩件事。
- **嵌入期間的心跳**：每 200 chunk 或每 5 秒，先到者發。批次邊界的回報在一批很大時
  幫不上忙，而那正是最壞情況。
- **`--batch-chunks` 與 `--memory-budget-mb`**（各有對應環境變數）。超過預算時在算任何
  向量**之前**具名拒絕，訊息按有效程度排序列出補救，並明說縮小批次對單一超大 session
  檔無效。**預設不設限**：本 repo 沒有量測支撐得起一個門檻。

### Changed

- **收回兩個宣稱。** (a)「批次以 chunk 數為單位、避免上界由最大來源決定」——實作做的
  正是它說要避免的事，實際上界隨最大來源成長（公式的唯一一份在
  `IndexBuilder.batchChunkUpperBound(target:largestSource:)`，見 #47）。
  (b) 量測紀錄的「查證後的實際來源：scanner 持有完整文字」——合成文字 630 B/chunk
  解釋不了擬合出的 142 KB/chunk，差約 225 倍；改成只保留相關性並列出七組能區分機制的
  對照量測。「這個結果推翻了 #46 的前提」整段收回。
- 補上 `docs/measurements/2026-08-26-interrupted-full-build.md`。先前散在 source 與
  CHANGELOG 的「1 小時 20 分／WAL 751 MB」沒有任何紀錄可指；新紀錄同時標明每個數字的
  證據等級——那組數字只存在於一則 commit 訊息裡，與有時間戳的觀察不同等。

## [0.3.0] - 2026-08-26

### Changed

- **改名**：repo `claude-LTM` → **`claude-code-ltm`**，marketplace → `claude-code-ltm`，
  plugin → **`ltm`**。理由是準確性：這個工具讀的是 `~/.claude/projects/**/*.jsonl`，
  而**只有 Claude Code 會寫那個東西**。**on-disk 路徑 `~/.claude-ltm/` 刻意不動**
  （`memory/` 是唯一不可重建的資料）。

- **wrapper 一律用 GitHub Release 的 binary**，不再撿本機建置或 `/usr/local/bin`。
  先前的搜尋順序讓「我跑的是哪一版」失去單一答案：版本檢查只套用在 `~/bin` 那份，
  撿到別處的就整個跳過檢查。

### Fixed

- **`ltm build` 分批提交**（#44）。先前整個嵌入迴圈在單一 `database.transaction`
  內——而這個檔案的註解逐字寫著「第一階段（**交易外**）：算向量」。code 與它
  自己的設計說明分岔了。

  實測代價（`docs/measurements/2026-08-26-interrupted-full-build.md`）：一次全量
  build 跑到 41 分鐘時 `index.sqlite3` 仍停在 4 KB、WAL 358 MB、外部讀取者看到的
  `chunks` 是 0。而中斷不需要當機，**關掉 session
  就夠了**。

  現在每批四段：交易外算向量 → 交易外側車 fsync → 單一交易（刪失效來源 +
  insert + 寫指標）→ 寫 state。中斷代價從「全部」變成「最後一批」。

- **並發寫入是具名拒絕**（#44 ②，先前未實測）。第二個 build 撞上 `build.lock`
  拋 `BuildError.lockHeld(path:)`，不是逾時也不是誤報索引損壞——後者會讓使用者
  去跑 `--full`，丟掉正確的索引。

### Added

- **`ltm build` 的進度輸出**（#45）。每批完成印一行到 **stderr**，`--quiet` 可關。
  先前它在完成前一個字都不印，而全量建索引是數十分鐘等級的工作——**一個跑數十
  分鐘、完成前完全沉默的命令，跟卡死在外觀上是同一個樣子**。

- **`docs/measurements/2026-08-26-build-peak-memory.md`**。結果**推翻了 #46 的
  前提**：向量累積已被分批封在 4 MB，線性成長來自 `CorpusScanner.scan()` 一次
  回傳全部 chunk 連同完整文字。紀錄也寫明不可外推並附實證。

## [0.2.1] - 2026-08-26

### Fixed

- **沒有登入鑰匙圈時回訊息，不要回一個等人點的視窗**（#45 之前的 keychain 修正）。
  舊版檔案式 keychain 在該環境不回 status code，而是彈 modal 並停住；`SecItemAdd`
  最終回的 `-60006` 逐字是 "The authorization was canceled by the user"。

  改用 data-protection keychain 實測不可行（要 `keychain-access-groups` entitlement
  → 需嵌 provisioning profile，Developer ID 的 CLI 發布做不到；帶 entitlement 而無
  profile 會被 SIGKILL）。改成在碰 Keychain 之前判斷，拋 `noLoginKeychain` 並指名
  補救（`ltm memory --export-key` → `LTM_ANCHOR_KEY`）。

  第一版讀錯東西：`NSHomeDirectory()` 不跟隨 `$HOME`，而 keychain 層看的是 `$HOME`。
  **檢查的東西必須與被檢查的那一層看同一個。**

- `save` 的註解把「不進 iCloud 同步」掛在 `kSecAttrAccessible` 上，而該屬性在 macOS
  要生效需要 `kSecUseDataProtectionKeychain`。結果成立而理由不同（舊版 keychain
  預設就不同步），註解已更正。

## [0.2.0] - 2026-08-26

### Added

- **`ltm-setup` skill**。分清楚兩件成本差三個數量級的事：binary 下載是自動的
  （幾秒），建索引不是（數十分鐘的本機運算）。先報使用者自己的語料規模與預估
  成本，經同意才跑。

  **不做成 SessionStart hook**：那個機制適合幾秒的下載＋版本檢查，塞不下數十分鐘
  的工作。

### Fixed

- **`ServiceError` 的訊息只在 CLI 路徑上存在**。每則補救說明都寫在
  `QueryCommand.report` 裡，而 MCP 路徑構不到它——它走 `"✗ \(error)"`，拿到的是
  enum 的預設描述（`indexMissing(path: "…")`），**而那個 case 的 doc 逐字寫著
  「訊息一律指名 `ltm build`」**。

  同一條規則兩個寫者，而沒照做的那個正是模型會讀到的。修法是刪掉一份：訊息移進
  `ServiceError: CustomStringConvertible`，CLI 只留結束碼對應。

## [0.1.0] - 2026-08-26

**首次發布。** 這一版之前的所有條目都列在下面——本檔從 repo 開始就在記，所以
0.1.0 的內容就是「到目前為止的全部」，不是這一次改了什麼。

以下是**為了讓它能被安裝**而做的改動，其餘條目是既有功能的紀錄：

### Added

- **`ltm mcp` 子命令**：MCP server 從獨立的 `ltm-mcp` executable 併進 `ltm`。
  理由是出貨形狀——生態的 release pipeline（`harness-devtools:mcp-deploy`）從頭到尾
  是單 binary 假設，餵它兩個要出貨的 binary 只有一個會出貨**且不報錯**。
- **`Sources/LTMCore/Version.swift`**：版本號的單一來源，由 `ReleaseVersionSyncTests`
  看守其餘三處（`mcpb/manifest.json`、`plugin.json`、wrapper 的 `DESIRED_VERSION`）。
  三者不同步的失敗方式是**四步都「成功」而版本各不相同**。
- **`mcpb/manifest.json`**、**`plugin/bin/ltm-mcp-wrapper.sh`**（自動下載 wrapper）。
- **README〈安裝〉**：使用者路徑、原始碼路徑、三層獨立驗證、maintainer 出貨流程。
  三層分開驗是刻意的——它們的失敗看起來一樣（模型說「查不到東西」），補救分別是
  重裝 binary、跑 `ltm build`、檢查 plugin 設定。

### Changed

- `PluginShellTests` 從比對 command 字尾改成驗**整條鏈**（`.mcp.json` 的 args →
  wrapper 存在且可執行 → wrapper 確實 `exec "$LTM" mcp` → 派發表裡有 `case "mcp"`）。
  先前那條斷言在 plugin 改用 wrapper 之後只是在比對一個檔名，而 wrapper 裡面 exec
  什麼完全沒被看著。

### 發布形式

Developer ID 簽章 + Apple notarization（`spctl` 回 `source=Notarized Developer ID`）。
**不是 ad-hoc**：本專案用 Keychain 存 anchor key，而 ad-hoc 簽章每次 build 換一個
code identity，會讓使用者反覆看到 Keychain 授權對話框。

### Added
- **#36 階段 1–3：兩輪 verify 的非阻擋 findings 收攏（前三階段）**。`#36` 收的是
  `#33`（21 條）與 `#34`（25 條）判為非阻擋的 findings，共 46 條。診斷把它分成五群
  並指出本 issue 自己的風險：**46 項的桶子太大而不會一次做完**，於是每次做掉最上面
  幾條而 issue 看起來一直有人在追。plan 因此先把四個決策拍死，再讓修法照著決策走。
  - **`FilePresentationRecordStore.allRecords(skippingUnusable:)`（新）**：鏡像
    `FileEventStore.allEvents(skippingUnusable:)`——fail-loud 預設、兩類不可用分開
    回報（損壞 vs 舊定址規則）、行號用真實檔案行。先前只有事件檔有這個逃生口，而
    兩者走同一個 `CanonicalStore.appendLine`、同一種中斷風險：**一次半截 append 會讓
    整份呈現歷史永久讀不回來**。
  - **呈現紀錄補上舊定址規則守衛**。一筆紀錄帶多個 anchor，**任何一個**是舊規則就
    整筆不可用——這筆紀錄的用途是把事件歸屬到位置，而部分歸屬的分母是錯的。
  - **刻意沒有 `presentations.jsonl` 的 `--prune`**（決策 D2）。`--prune` 在它主要的
    觸發情境（定址規則換代）裡做的是「清空整份歷史」，再開一個同形狀的破壞性表面是
    複製已知危險。**可復原性不需要用刪除達成。**
  - **`KnownItemHarness` 的三個具名錯誤**：`skipped` 拆成 `skippedNoSample` 與
    `skippedNoQuery`（前者是語料實作的 bug，後者是正常損耗，合併之後兩者看起來一樣）；
    負的 `sampleSize` 不再 trap；檢索回傳不足時具名拒絕，不安靜低估 recall。
    深度門檻是 `min(recallK, corpus.count)`——初版寫死 `recallK`，對小語料是誤報。
  - **`LTMService.interleavedPolicy`（新具名常數）**：`"interleaved"` **刻意不是**
    `StrategyRegistry.known` 的成員——它不命名一個策略，它命名「這次呈現沒有單一
    策略」。測試釘住它不在 `known` 內、`make()` 回 `nil`。

### Fixed
- **#36 verify：一條 CRITICAL 與兩條 HIGH，三條都指向作者自己的宣稱**。
  - **階段 5 有三項承諾完全沒有落地，而收尾核對沒抓到**（CRITICAL）。
    `strategy-comparison/spec.md` 在那四個 commit 裡的唯一改動是腳本路徑改名——
    plan 承諾的 `incompatibleComparisonPair`、CLI 比較對的決定與後果、D4 的紀律邊界
    **一項都沒寫**（`git log --all -S"incompatibleComparisonPair" -- openspec/` 零命中，
    從來沒進過任何 spec）。`RankingGuard.swift` 與 `ConservativeStrategy.swift`
    **完全沒被碰**。而收尾 comment 寫「(A) 對齊｜四份 spec…」暗示階段 5 完成。
    **這正是 plan 自己點名的頭號風險（分流變成排序），在本該攔住它的那一步重演**
    ——因為我是照「打算做什麼」而不是照 diff 寫的核對。三項現已實際寫入。
  - **「兩天」是錯的**（HIGH）。git 時間戳：指標被刪 `cfa8841` 03:04、補回
    `97a827c` 10:50，**間隔 7 小時 46 分，同一天**（取 `#16` 的 close 當起點也只有
    約 25.5 小時）。那句話寫在四處，含**一條 live spec requirement**。
    **這正是 #39 要抓的形狀——一句斷言了可查證之事而沒有人查證的散文，出現在一個
    逐字引用 #39 的 diff 裡。** 四處已全部更正，並留下更正紀錄而非只換數字。
  - **淺檢索守衛是未揭露的行為回歸**（HIGH）。它 `throw`，而那個 throw 從 per-sample
    迴圈傳出去、**中止整個 run**；量測腳本對 `harness.run` 只寫 `try`、沒有 `do/catch`。
    更根本的是**稀有詞查詢合法地就會回少於 `recallK` 筆**（FTS5 回真的匹配到幾筆、
    不補滿），所以它會在完全正常的資料上把整份量測炸掉。
    改成**第三種跳過計數**（`skippedShallowRetrieval`），與同一 commit 已建立的紀律
    一致。並在 `docs/measurements/2026-08-23-known-item-retrieval.md` 揭露：該紀錄的
    數字產生於這個計數之前，**recall 應讀成下界而非點估計**，且它的可重現性宣稱
    沒有在新版 harness 上重驗。
  - 順帶：`memory-strategy` spec 的兩份 `@trace` 清單補回那兩個 Swift 檔（現在補是
    真的了——它們這次確實被改了）；「出貨策略輸出不變」的保證恢復全稱量詞與
    displacements/reasons，**並寫明支撐它的是 `union(X, X) == X` 這個合成恆等式而不是
    窮舉測試**——讀者因此知道哪一種未來改動會打破它。

### Changed
- **#14：seam 的兩條 SHALL NOT 改寫成具名執行點**（Spectra change
  `name-seam-enforcement-points`）。原文「Retrieval SHALL NOT read the event store
  directly, and no strategy SHALL read the corpus directly」沒有執行點，而 issue 提的
  兩個方向（把 `Event: Codable` 移出 `LTMCore`、把 `CorpusReader` 變 internal）**交不出
  它們承諾的編譯期事實**：一個策略要讀事件檔或語料，需要的是 Foundation 的
  `Data(contentsOf:)` 與 `JSONSerialization`，不是被提議移走的那些便利型別。
  **理由不是「兩個反例都沒用到那些型別」**——R3 抓到那句是假的，其中一個用了
  `CorpusReader`，變 internal 會讓它編不過（而推翻它的正是我自己寫在同一份 spec
  裡的 Example）。成立的理由是：**兩個反例都能用標準函式庫重寫並再次通過**，所以
  藏起型別拿掉的是某一段程式碼、不是它行使的 capability。那個代價（動依賴圖底層、
  波及所有模組）仍然換不到承諾的東西，但結論的理由換了一個。
  - **改寫成它實際保護的兩件事，各自指名執行點**：排序正確性由 seam 的**十項檢查**
    執行（依入口實際執行順序列出），每項列出它拋的違規名，共 11 個名字；隱私邊界的
    執行點在 canonical store **落地 bytes** 的 round-trip 檢查。**其中八項每次呼叫
    都跑，兩項有條件**：第 5 項（`malformedStatistics`）只對宣告會消費歷史的策略
    執行；第 9 項（`movedAcrossTieRuns`）只在策略的有效位置約束非空時執行——三個
    出貨策略裡只有 `conservative` 帶著 tie-run 約束。兩個閘門各有刻意的理由（見
    spec 與 authority table 的條目），但**假設每一項都會跑的讀者會誤診那兩項**。
  - **列舉本身寫成可查證的，而且把查法寫在旁邊**：spec 明寫這 11 個名字必須與
    `StrategyViolation` 的 case、以及公開入口可達的 `throw` 站點**三者逐一對應**。
    實測 11 = 11 = 11、三個集合互減皆為空。
  - **這份列舉的第一版是錯的，而錯法就是它現在改寫查法的理由**（verify #14 抓到）。
    初版列 8 個違規名並宣稱「每個可達的 `throw` 都在清單裡」，**漏了三個**：
    `nonFiniteBaseScore` / `bandsOutOfOrder` / `malformedStatistics` 是 `rerank` 在進
    `rerankChecked` **之前**跑的前置檢查，而我只從 `rerankChecked` 往內數。
    **一份宣稱自己完整、卻不寫出怎麼驗的列舉，比不宣稱更糟——那句宣稱和一次真的
    查證在字面上分不出來。**
  - `ValidatedCandidates` 的 `internal` init 記為**刻意的信任邊界**（doc 指向 spec），
    不是遺漏。四處過期註解一併修掉；**第四處由獨立掃描步驟找到、不在 proposal 的
    Impact 內**——與 `#34` 那次同形狀，但這次在宣稱完成**之前**被抓到，因為那一步是
    獨立掃描而不是「我記得我改了哪些檔」。
  - **第一個 commit（`6c56e41`）的 Swift 改動全部是註解**，測試 397 條與改動前逐字
    相同。**這句只描述那一個 commit，不描述 #14 這條線的最終狀態**——後續三個
    commit 有真正的修正，`bead662` 還新增了一個可執行的測試檔（測試數 397 → 399）。
    R4 抓到這條 bullet 在原處未改、讀起來卻像在總結整條線：一句**當時為真**的話，
    在它描述的東西之後又動了三次而沒人回頭看它。
- **#36 階段 4–5：測試品質與 artifact 對齊**。
  - **未知策略的結束碼有回歸鎖了**。`#33` 的 blocking 修正把它從 trap 改成具名錯誤
    （4 → 2），而那個 change 的 AC3 寫著「不帶旗標時 byte-identical」——字面上與該
    改動衝突，且**沒有任何東西釘住新值**。新測試斷言的是**跑出來的結束碼**，不是
    `ExitCode.usageError.rawValue == 2`（後者只驗一個常數的字面值）。
  - **`memory-events` spec 補上 `interleaved` 保留值條款**。原文寫 policy 是
    「naming the strategy in force」，而交錯比較裡沒有單一 in-force strategy
    ——spec 的措辭涵蓋不到已出貨的值。修 spec，不修 code。
  - **`ltm-cli` spec 明說那個拒絕情境從 CLI 不可達**。`--compare` 分支無條件建兩個
    store，所以「沒有事件存放時失敗」只在 service 邊界可測。把不可達寫進 requirement
    本身，讀者才不會去找一條不可能存在的 CLI 測試。
  - **`memory-strategy` spec 新增「識別碼每次呼叫只讀一次」**，並把 `displacementBound`
    的開放問題指向 **#38**（原指標指向已 close 的 `#16`，而 `#34` 的 diff 刪掉那行
    沒補替代——**一個寫進 spec 的已知缺口有約 8 小時完全沒有落點**）。
  - **`unregisterForTesting` 的 doc 收窄**。「測試之間不互相污染」對 bootstrap 名單
    不成立：`readyForTesting` 是 `static let`，撤銷名單內的識別碼是**不可逆的**。
    目前沒有測試這樣做，所以是潛伏的——但那句無限定的宣稱正是下一個人會依賴的東西。
  - **archived proposal 的 Impact 清單刻意不改**。它們是歷史紀錄，而「哪個 change
    動了哪個檔」的權威答案是 git。該 finding 的實質是流程缺口（Impact 在 propose 時
    寫、archive 時無人對帳），屬 **#39** 家族。

### Changed
- **#36：`compare(persist:)` 刪除**（決策 D1）。它的 doc 寫著「存在只是為了讓測試能
  檢查『不落地時什麼都不寫』」，而 `grep -rn "persist: false"` 全 repo **零命中**
  ——那條測試從來不存在。它不是一條沒被記到的測試縫，是一個**以不存在的測試為理由**
  存在的參數，提供的正是 spec 明說不提供的組合。記進 spec 等於把假話升格成契約。
- **#36：零候選的比較不再留呈現紀錄**。沒有候選就沒有位置 0，也就沒有 starting side，
  把這種列計進 `startingSides` 的分母等於用沒有起始邊的列稀釋交錯平衡統計。
- **#36：`EventStoreError` 的補救建議改成 path-aware**。它是**兩個** canonical 存放
  共用的錯誤型別，而 `ltm memory --prune` 只處理 `events.jsonl`；對
  `presentations.jsonl` 給那條建議是叫使用者跑一個根本不看這個檔的命令。
- **#36：seam 的 `id` 在整個 `rerank` 裡只讀一次**。先前讀兩次（查表、組錯誤），
  交替回值的 getter 因此能讓 `unauthorizedStrategy` 指名一個**從未被用來查表**的
  識別碼。**這不解決 #37**（`id` 仍是 per-call 自報，跨呼叫仍能換身分），只保證
  單次呼叫內部一致。
- **#36：位置約束依 `allCases` 迭代，不依 `Set`**（後者隨 hash seed 變動）。
  **誠實邊界：這條沒有回歸鎖。** `PlacementConstraint` 只有一個 case，一種約束不可能
  有兩個同時違反，所以該性質無法被任何測試驅動——缺口寫進 code 註解，加第二個 case
  的人要同時補測試。寫一條驗不到的測試比沒有測試更糟。
- **#36：量測腳本移到 `scripts/measure-retrieval/main.swift`**，`Package.swift` 的
  逐檔 `exclude` 清單整份刪除。`sources:` 已指名單檔但 SwiftPM 仍對 target 目錄下
  任何未處理的檔案發 warning（實測拿掉 exclude → `found 11 file(s) which are
  unhandled`），於是每新增一個探針檔都要回頭改清單。目錄化把負擔拿掉。
- **#36：「全部」列依 `QueryClass.allCases` 累加**。Double 加法不可結合，而
  `Dictionary.values` 的迭代順序隨 hash seed 變動——「同一 seed 逐字相同」先前不是
  結構性保證，只是桶數少所以沒撞到。

- **#34：策略的位置約束改由授權表決定**（change `authorize-strategy-declarations`）。
  `#32` 把 tie-run 約束的**執行點**上提到 seam（對的），但留下「策略仍能決定自己
  受不受檢」——而那句「策略只能選、不能弱化」寫在六處 artifacts 裡，被一個 getter
  交替回值的探針可執行地證偽（同 instance、同候選，第一次拋、第二次過）。
  - **`StrategyAuthority.swift`（新，`LTMQuery`）**：`id → 授權約束` 的封閉表，與
    `StrategyRegistry` 住同一個檔案。seam 取 **`表 ∪ 實例`**——策略可以給自己**加**
    約束，永遠**減**不掉表裡的。
  - **交替回值的 getter 因此拿不到任何東西**，所以不需要跨呼叫的一致性驗證：保證來自
    **合成的方向**，不是記住上次讀到什麼。seam **不記錄任何策略宣告過什麼**——但它
    不是純函式（授權查詢每次都經過一張有鎖的 process-lifetime 註冊表；初版在七處
    artifact 宣稱「無狀態、無同步」，那是假的，已全數收窄）。
  - **verify 抓到同一個形狀往下移了一層，已具名記錄**：授權表以 `id` 為鍵，而 `id`
    也是未經驗證的 per-call 自報。實測 `id` 交替於兩個都被授權的識別碼：第一次拋、
    第二次過——#32 探針輸出的逐字重現，對著新機制。成立的陳述因此是「策略無法被檢查
    得比**它在該次呼叫回報的識別碼**所要求的更鬆」。缺口追蹤於 **#37**。
  - **`StrategyRegistry` 從 `LTMService` 下移到 `LTMQuery`**（服務層 `typealias`
    re-export，呼叫端零改動）。授權表必須被 seam 讀得到，而 seam 所在模組的依賴刻意
    只有 `LTMCore`；另立第二張表則會讓「有哪些策略」有兩份會漂移的定義。
  - **新增 `StrategyViolation.unauthorizedStrategy`**：表裡沒有的識別碼**具名拒絕**，
    不退回自報——退回等於留一個「宣告新名字就不受檢」的後門。拒絕發生在 `rerankChecked`
    之前（測試斷言 `wasEntered` 為假，不只是「有拋錯」）。
  - **套件內的測試註冊口**（`internal`）：seam 的每道檢查都靠刻意違規的 conformer 鎖住，
    而那些 conformer 必須有自己的假 id。封閉性對模組外仍成立，且**寫進 spec**——沒被
    記錄的信任邊界與疏漏無法區分。
  - **`displacementBound` 不在授權表裡，而「為什麼不能在」是這次的實質收穫**：表以
    識別碼為鍵，而 spec 要求 bound 可在建構時組態——`human-like(bound: 3)` 與
    `human-like(bound: 1)` 是同一個識別碼的兩個實例。issue 說「兩者是同一個問題的兩個
    實例」對了一半：都是無人驗證的自報，但**只有一個能用身分鍵的權威回答**。
    **bound 的權威問題仍未決。**
  - 四個變異各殺掉一條不同的測試（聯集的兩個方向、未知 id 的拒絕、出貨策略對齊）。
    實作期間另抓到兩次「靠順序才綠」：bootstrap 放錯 target（整批綠、單跑紅）、
    探針借用了 bootstrap 名單裡的識別碼（`static let` 初始化時機決定成敗）。

- **#33：兩條評估路徑的機具接上了**（change `wire-evaluation-machinery`）。issue 原本只
  說「ground truth 資料集沒人在追」，而 discuss 期間查證出**第三塊、也是真正的瓶頸**：
  `grep -rn "InterleavingHarness" Sources/LTMService/ Sources/ltm/` 零命中、
  `PresentationRecord(` 只出現在 `Interleaving.swift` 自己——**live 的交錯路徑不存在**，
  所以 `ltm query --record` 寫的 `shown` 事件到 `ComparisonScorer` 全部落進
  `skippedPresentationNotTracked`，報告照樣產出而且不報錯。
  - **`ltm query --compare`**：一次檢索、兩個策略各排一次、交錯後呈現，落地
    `PresentationRecord` 與對應的 `shown` 事件。隱含 `--record`，與 `--strategy` 互斥。
    人類可讀輸出**一個策略名字都不出現**——逐位置的歸屬是給計分讀的，讓看結果的人
    知道會影響他接下來點哪一筆，而那個點擊正是要拿來計分的東西。
  - **比較模式住服務層**（`LTMService.compare`），CLI 只轉述旗標。服務層收的是策略
    **識別碼**不是實例，實例由新的 `StrategyRegistry` 產生——那張對照表先前只活在 CLI，
    第二個呼叫端出現時就會變成兩份。
  - **`KnownItemHarness`**（LTMEval）：從語料抽段、由段內文字導出查詢、把該段當 gold，
    對 lexical-only／vector-only／fused 三軌各跑一次既有的兩階段評分。回傳型別**只有
    計數與比率**，查詢與 gold 指標用完即丟（測試對序列化後的 bytes 下斷言）。
    導不出可用查詢的樣本被**跳過並計數**——靜默跳過會讓有效樣本數與要求的不同。
  - **新增 public API**：`LTMEval` 的 `PresentationRecordStore` / `FilePresentationRecordStore`、
    `KnownItemCorpus` / `KnownItemHarness` / `KnownItemReport` / `ChannelRankings` /
    `ChannelAggregate(s)` / `SplitMix64`；`LTMMemory` 的 `CanonicalStore`；`LTMService` 的
    `StrategyRegistry` 與 `LTMService.compare`；`RetrievalEngine.search(query:limit:scope:channels:)`。
  - **新增 `ServiceError`**：`comparisonRequiresStores`（不能記錄的比較不執行）、
    `incompatibleComparisonPair`（兩個都消費歷史卻對擴散要求不同的策略無法共用一份
    projection——交錯器只收一份）、`unknownStrategy`（不退回預設值）。
  - **第一份紀錄**：`docs/measurements/2026-08-23-known-item-retrieval.md`
    （1,600 檔抽樣語料建成的獨立索引 18,470 chunk、兩個 seed 各約 490 對）。
    三軌分報第一次讓「`cjk-2char` 的向量軌掛零」變成表上讀得出來的事實。
  - **誠實邊界**：這次改動讓**機制**存在，**沒有**讓策略比較獲得量測支撐。

### Fixed（#33 verify）

5-lens ensemble（pai-ensemble 2.20.0，**codex leg 停用 → 無跨模型盲驗**）回報 53 條，
以下 5 條判為 blocking 並已修，每條都以變異測試確認回歸鎖會為對的理由變紅：

- **`--strategy <任意字串>` 讓行程 abort（exit 133）**。本次改動引入的回歸：把對照表
  搬進 `StrategyRegistry` 時，順手把使用者字串包成 `RankingPolicyID(_:)`，而那個
  initializer 對非法值是 `preconditionFailure`。改用 `init(validating:)`。CLAUDE.md
  的「外來資料解析路徑一律不得 trap」逐字適用於 CLI 參數。
- **`generation` 是 wall-clock 秒數，而 spec 定義是「索引建置的世代」**。後果是致命的：
  `ComparisonScorer` 對 generation 不符是 `throw`（且排在 null 檢查之前），所以任何
  **事後**寫入的互動事件——交錯比較存在的全部理由——會讓整份報告產不出任何數字。
  改成由索引三個戳記雜湊而來。
- **applied `ltm-cli` spec 自相矛盾**：既有 requirement 寫「沒有 `--record` 就不得寫
  任何事件」，而 `--compare` 會寫。delta 只有 `## ADDED` 沒有修既有句子。已更正。
- **「機制就緒、只差資料累積」是假的**。淨強度只由 deliberate 事件推動，而**全 repo
  沒有任何寫入端**（只有 `.shown`，且它被明確排除在 reinforcement 之外）。原本寫進
  spec 與 CLAUDE.md 的「需要時間」讀起來像等得到的 bootstrap 期——已改成事實陳述，
  缺的那一端開為 **#35**。
- **`compare` 讀歷史的那一行零覆蓋**：把它改成「永遠不讀、永遠不擴散」，367 條測試
  全綠。所有 compare 測試都跑在空事件檔上。已補種真實歷史的非 null 比較測試。

另修 1 條 MEDIUM：`KnownItemHarness.deriveQuery` 的 ASCII 路徑會回傳**整段文字**
（`"tokenizer"` → `"tokenizer"`），正是它自己的 doc 宣稱擋掉的退化情形；而唯一那條
回歸測試只餵中文，走不到那條路徑。量測紀錄的數字是修正後重跑的。

量測紀錄本身也改寫過一次（三處過度宣稱／揭露不足，見該檔末節）：做了同一段自己說
「分辨不了」的歸因、在整體數字上下結論而赤字其實集中在 `cjk-2char`、nDCG 從不印
分母（`n=12` 的 0.465 與 `n=243` 的 0.652 並列）。

- **#18：RRF 平手發生率已在語料子集上量到**（`docs/measurements/2026-08-22-rrf-tie-rate.md`；
  探針 `scripts/measure-rrf-ties.swift`、查詢集 `scripts/rrf-tie-queries.txt`、抽樣
  `scripts/sample-corpus-scales.py`、機制表 `scripts/rrf-tie-mechanism.sh`、自驗
  `scripts/rrf-tie-fixtures/`）。`conservative` 在 base score 兩兩相異時可證明等同於
  `archival`，所以平手發生率就是這一檔的全部價值。
  - **結論：不是佔位符，作用面高度集中在 `cjk-2char`。** 16,585 chunk 的索引上，該桶
    99.6% 的候選落在平手段內、100% 的查詢至少有一段；其餘四桶都在個位數以下，
    `mixed` 在三個規模上都是 0.0%。整體 13.5% 會洗掉這種集中——分桶報告在這裡再次
    證明是必要的。
  - **機制**：中文雙字查詢的 `trigram` 通道整條空掉（3 字元硬底線，`2026-08-10-fts5-tokenizer.md`
    已記錄），只剩 `segment` 與 `vector` 兩組互斥的單通道候選按名次對撞。同一條硬底線
    既壓低了中文雙字的召回，也製造了這一檔主要的作用面。**但它不是平手的唯一來源**
    ——機制表裡 `資料庫` 一列沒有任何單通道組卻仍有 1 個平手（兩通道候選的分數碰撞）。
  - **量的是生產路徑**：探針不含檢索邏輯，呼叫 `ltm query --json` 讀回真正的
    `score`／`band`（「兩個寫者＝兩份會漂移的規格」）。分桶用生產的 `QueryClassifier`
    （編譯時帶入該原始檔）。
  - 踩到一個**不會報錯**的誤設：只設 `LTM_DERIVED_ROOT` 而未設 `LTM_CORPUS_ROOT` 時，
    每次查詢都對真實語料做增量續讀（單一查詢燒掉三分鐘 CPU 仍未返回），量到的索引
    不是指定的那個而且中途還在長大。

### Changed
- **#32：策略的額外條件改由 seam 執行**（`da2283d`，change `enforce-strategy-conditions-at-seam`）。
  - **新增 public API**：`PlacementConstraint`（封閉 enum，單一 case `.withinTieRuns`）與
    `MemoryStrategy.placementConstraints`（protocol requirement，extension 預設空集合）。
    既有 conformer 零改動。
  - **根因**：策略軸的定義是「消費哪些訊號」+「在什麼條件下作用」，而**後半一直沒有
    宣告點**。於是 `conservative` 的等分區段條件只活在自己的 `rerankChecked` 裡，唯一能
    執行它的就是策略自己——**被約束者執行自己的約束**。實測把那一行換成只驗排列的版本，
    `LTMQuery` 67 條測試全綠：唯一覆蓋該約束的測試從不建構策略，只把手工排列餵給 helper。
  - **關掉了哪一半**：`RankingGuard` 自己從 `band` 與 `baseScore` 導出區段，
    **策略對這個檢查貢獻零資料**，所以策略無法**定義**一條約束的意思。
  - **沒關掉、而且初版宣稱錯了的那一半**（#32 verify 證偽，見下方 Fixed 段）：
    初版寫「宣告只能選不能定義，所以無法弱化一條已宣告的約束」。後半是錯的——
    `{ get }` 允許 computed property，seam 每次重讀而不記錄，實測同一個 instance
    可以第一次被擋、第二次被放行。與 `displacementBound` 的差別是**表面大小**
    （連續值域 vs seam 擁有的封閉詞彙子集），不是**種類**——兩者都是未經驗證的
    per-call 自報。殘留缺口追蹤於 #34。
  - **封閉 enum 為什麼不違反「列舉會漏」**：它住在 seam 裡不住在散文裡——每個 case 都有
    `RankingGuard` 側的實作，新增 case 是**帶著執行它的程式碼一起出貨**的 spec 變更。
    同一條窄例外也涵蓋 `QueryClass` 的封閉五值。
  - **兩個變異都實際跑過，不是宣稱**：(a) 拿掉 seam 執行 → 新鎖以「預期的違規沒被拋出」
    變紅，**且僅此一條**（精準、非偶然耦合）；(b) 把 extension 預設翻成受約束 →
    `human-like` 的正確輸出被自己的 seam 拒絕，而錯誤名稱指向 tie-run 檢查、不指向造成它的
    預設值——**正是 design 預測的「看起來像策略 bug」失敗模式**。兩份觀察記在 archived
    change 的 `tasks.md` Completion notes。
  - `memory-strategy` spec 新增一條 Requirement（4 scenarios + 三列 example table，26 → 30
    scenarios）。用 ADDED 而非 MODIFIED——`## MODIFIED` 是整條 Requirement 替換，#25 就是
    那樣把新增條款刪掉的。

### Fixed
- **#32 verify 的 4 條 HIGH**（5/5 lens；Codex 仍停用——無跨模型盲驗）。三條打在
  「我宣稱量過的東西」上，形狀與 #18 R1 同源：**跑了實驗、得到想要的答案就停手**。
  - **核心宣稱被可執行地證偽**：「策略無法弱化一條已宣告的約束」。`placementConstraints`
    是 `{ get }`，conformer 可用 computed property；seam 每次呼叫**重讀**它、不記錄也不
    驗證——而緊接著那個迴圈**確實**驗了 `displacement` 與 `movement`。DA 建了一個 getter
    第一次回 `[.withinTieRuns]`、之後回 `[]` 的 conformer，我重跑確認：同一個 instance、
    同一個跨區段排序，**第一次拋 `movedAcrossTieRuns`、第二次被接受**。已在五處撤回並
    改成實際成立的較窄陳述（無法**定義**約束的意思；能控制單次呼叫受不受檢）。與
    `displacementBound` 的差別是表面大小不是種類。殘留缺口 → **#34**。
  - **`enum` 插在 protocol 之前卻沒空行，偷走了 protocol 的 doc comment。** Swift 把連續
    `///` 綁到後面的宣告，於是 `MemoryStrategy` **完全沒有文件**，而 #14 逃生口那條註記
    掛到了 `PlacementConstraint` 上——一個與它無關的型別。已把 enum 整塊移到 protocol
    的 doc 之前。
  - **task 5.3 的 Verify 條款是假的**：它寫「把預設翻成受約束時這條會紅」，但
    `MisbehavingStrategy` 自帶 stored `placementConstraints`，**extension 預設從不被諮詢**
    ——實測翻預設後那條測試照樣過。真正持有該性質的是
    `theShippedStrategiesDeclareTheConstraintsTheSpecSays`。測試檔內的同一句註解一併修。
  - **第二個變異的記錄少算一半且性質描述錯誤**：我寫「另外四條，全是同一形狀」，實測是
    **19 個 issue / 16 個 test function**。而且**不是同一形狀**——其中兩條正是本次新增的
    `theShippedStrategiesDeclareTheConstraintsTheSpecSays`，它們**逐字指名被翻掉的預設值**。
    所以我從那次觀察推出的「失敗會隱藏自己的成因、看起來像策略 bug」，被這次改動自己
    加的測試推翻了。記錄已更正。

### Fixed
- **#16 verify 的 2 CRITICAL + 3 HIGH**（5/5 lens 全跑完，Codex 仍停用——**沒有跨模型盲驗**）。
  五組裁決裡有兩組只落地了一半，而 change 被歸檔成 8/8。
  - **CRITICAL：起手方校正是「只做一半」的第四次，而 spec 用 SHALL 規定了報告要有它。**
    `startingSideCorrectedPreference` 全 repo 唯一的呼叫點是它自己的測試；`0a35783`
    **完全沒動** `ComparisonReport.swift`（而 proposal 的 Impact 明寫要動）。同一個 commit
    寫進 spec 的是「the report SHALL include a starting-side-corrected preference estimate」
    加兩條 scenario，**兩條都沒有測試也不可能通過**。前三次是 R3 拿掉預設值 → R4 補機制
    未記錄 → R5 補計數沒人讀。已把配對放進 `ComparisonScorer` 的計分迴圈（唯一同時知道
    `policy` 與 `record.startingSide` 的地方），報告新增 `startingSideCorrected`，並補上
    那兩條 scenario 的測試——第一條刻意讓校正後（0.5）與 pooled（0.75）不相等，否則分不出
    有沒有校正；驗過把計算改成恆 `nil` 會紅。
  - **CRITICAL：spec 的兩條 Requirement 直接互斥。** :274 寫「SHALL NOT attempt to
    **construct or score** negative cases」，而同一檔 :226 的 scenario「An empty result list
    is scored as not recalled」逐字就是 construct 且 score 一個負例——`.notRecalled` 這個
    case 的存在理由正是描述負例。這是 `common-spec-prose-enumeration` 的教科書失效：
    心裡想的是一組特定案例（事件日誌收集不到的真實失敗查詢），寫成了一句總括判準，
    字面涵蓋範圍大於那組案例，於是在**它自己的 change 內部**長出矛盾。已把禁令收斂成
    「不得從真實使用**收集**」並明寫合成 fixture 一直都在範圍內。
  - **HIGH：`prefix(recallK)` 是死碼。** 實測整段拿掉 → **60/60 全綠**。六條測試沒有一條
    把 expected 放在窗外——名為 `recallAt20ConfirmsPresenceBeforeAnyRankingScore` 的那條
    fixture 是「expected 根本不在列表裡」，驗的是「不存在」而不是「超出第 20 名」。而
    recall 窗正是兩階段指標的第一階段。已補 fixture（25 筆、expected 在第 21 名），並驗過
    拿掉 `prefix(recallK)` 後它會紅。
  - **HIGH：校正函式的簽名偏離 Implementation Contract**，偏離方向剛好讓 wiring 可以被
    略過，且它的 doc 宣稱「呼叫端從既有欄位配對，本型別不重做那段邏輯」——而當時**沒有
    任何呼叫端**，那段配對只存在於 `ComparisonScorer` 的 private 迴圈裡。接上呼叫端即解決；
    doc 改成具名指出呼叫端。
  - **HIGH：spec:235 的三軌 SHALL 是條件句，而沒有任何報告型別呈現 fused outcome**
    ——目前 vacuously 成立。已在 spec 內寫明這件事與它為什麼仍然留著，讓讀者不必從
    `ComparisonReport` 沒有欄位這件事去推斷。
  - **未變的誠實邊界**：ground truth 依裁決 2 仍在範圍外，CLAUDE.md「策略比較目前沒有
    任何量測支撐——沒有評估集」**仍然成立**。本輪修的是「指標有沒有接上」，不是「有沒有
    資料可比」。

### Fixed
- **#17 verify 的 4 條 HIGH**（`conservative` 檔次的裁決驗證；5/5 lens 全跑完，Codex 仍停用
  ——**沒有跨模型盲驗**）。四條我都自己重跑實驗確認：
  - **spec scenario 對 `conservative` 的 THEN 是錯的。** 它寫「reorders the tied
    candidates by strength」，但共用的有界重排核心在預設 bound=1 下是**單趟相鄰交換**，
    且 `movedThisPass` 讓每個候選一趟只能動一次：`[a(0), b(2), c(5)]` → `[b, a, c]`
    ——**最強的 c 完全沒動**。覆蓋它的測試只斷言「順序有變」，比 scenario 的 THEN 弱得多，
    弱到剛好蓋不住它要覆蓋的性質。scenario 改成描述實際行為並寫明那個不對稱；測試改成
    斷言完整輸出順序。同一份測試裡「強者往前一格」那句註解對它自己的輸入就是錯的，一併修。
  - **R3 的無限迴圈修法（`end = start + 1`）沒有任何東西釘住。** 實測改回 `var end = start`
    → **67/67 全綠**。名義上的回歸鎖 `conservativeDoesNotHangOnNonFiniteBaseScores`
    **到不了那個迴圈**：`rerank` 在 seam 就被 `requireFiniteBaseScores` 擋下。而那條路徑
    不是假想的——`ValidatedCandidates` 是 public+Sendable、可儲存可轉手。已補
    `conservativeTerminatesOnNonFiniteScoresEvenWithTheSeamBypassed`，直接建構 token 走
    `rerankChecked`，只斷言「它會回來」。**驗過會為對的理由變紅**：退回修法後
    `timeout 180 swift test` 回 exit 124（掛住）。
  - **三個寫者對「被約束者提供約束值」的洞說兩套話。** `ConservativeStrategy` 與
    `RankingGuard.checkTieRunsOnly` 各自寫著「那個洞在結構上關掉了」，而
    `MemoryStrategy.displacementBound` 的註解**逐字撤回過那句話**（「『從 protocol 讀』
    就是『從策略讀』，來源相同、只換了管線」，#1 verify R6 實測）。已讓前兩處指向
    SoT 而不重述——重述一次就是第二份會漂移的規格。
  - **tie-run 守衛在生產路徑上可整行換掉而測試全綠**（實測 67/67）——覆蓋它的測試從不
    呼叫 `ConservativeStrategy`，只把手工排列餵給 helper。這是 `CLAUDE.md` 記過的形狀
    （「回歸鎖全測在 helper 上而生產路徑那行可以整行刪掉」）。**補測試不夠**：策略不會
    違反自己的約束，要讓那行 load-bearing 只能把執行點上提到 seam，而那與
    `displacementBound` 的「誰有權決定」是同一個未解決的設計決定 → 開 #32。

### Fixed
- **#18 verify R2 的 findings**（該輪 5 個 lens 只跑完 3 個——devil's advocate 與另一個
  因 ECONNRESET 失敗，**覆蓋不完整**）。全部是 R1 那批事實的殘留，形狀只有一個：
  **我修的是被引用的句子，不是那個事實。**
  - **撤回只寫進了描述撤回的文件。**「`cjk-4plus` 與 `mixed` 一次都沒觀測到平手」
    仍留在 `ConservativeStrategy.swift` 與 `docs/memory-systems/README.md`，而**同一個
    commit 落地的量測表**就寫著 `cjk-4plus` 在兩個較大規模都是 0.3%。更正寫進了
    CHANGELOG 與量測紀錄（描述撤回的兩份），沒寫進被撤回的那兩份。
  - **「觀測到的段長都是 2」在三處存活**（spec、doc comment、README），而量測紀錄
    寫著 400 檔那一階出現 2 段長度 3。那句話唯一的任務是提醒「那是觀測、不是上界」
    ——**它自己把觀測講錯了**，於是 spec 用一個假的觀測去禁止從觀測推上限。
  - **spec 段落開頭句仍宣告 "is unmeasured"**，而同一段結尾說 "has now been measured"。
    R1 的 H2 只點名段尾那句禁令，我就只改了那一句。
  - **抽樣腳本的守衛是字串式路徑比對，五條旁路實測全部放行**：APFS 大小寫不敏感、
    firmlink、以及**目的地是 `~/.claude/projects` 本身**（`rmtree` + 寫入唯讀語料，
    違反不變式 1）。`Sources/LTMMemory/EventStore.swift` 的 `CorpusLocation` 就是正確
    做法，其註解逐字禁止複製那段邏輯——那支腳本就是被禁止的複製品，且比原版弱三處。
  - **修法一律改成性質而非列舉**：doc comment / README / spec 三處不再複述任何數字
    （連「某桶是 0」都不複述），只留定性結論與指向紀錄的指標；spec 條文改成「不得從
    **任何**被觀測到的段長分佈推導上限」。抽樣腳本**不再接受目的地參數**——用
    `tempfile.mkdtemp()` 自己建立並印出，沒有外來路徑就沒有要判定的東西；另留一道
    inode 身分檢查當縱深（大小寫與 firmlink 折疊到同一個 inode，五條旁路實測全擋）。

### Fixed
- **#18 verify R1 的 6 條 HIGH**（`e6494ef` 之後的修復）。核心邏輯沒問題，**壞的是
  那些數字的可信度與周邊宣稱**——四條打在量測紀錄上、一條在 spec、一條在 CHANGELOG。
  - **`JSONSerialization` 的數字解析不保真，初版用它比對分數。** 初版附了一個實驗
    宣稱「JSON 的 Double 是忠實的」——那個實驗測的是**寫入端單射**（相等值印同一串），
    而需要的性質是**讀取端保真**。實測：`0.015384615384615385` 與 `…387` 都被讀成
    bits `…650`，真值是 `…648`／`…649`（差 2 ulp 且合併）。方向只有一邊：不會漏掉真
    平手，但**會製造假平手**（兩通道分數空間 5,009 → 5,004）。修法是改比對原始 JSON
    token 字串，完全不經解析器；回歸鎖 `rrf-tie-fixtures/ulp-neighbours` 驗過會為
    對的理由變紅。**這個錯的形狀值得記住：做了一個實驗、得到想要的答案就停手，
    而那個實驗測的不是需要的那個性質。**
  - **「52.6% 是結構上限」是無效推論，已撤回。** 從「觀測到段長恆為 2」推「10/19 是
    上限」，而「成對」是觀測不是結構保證。平手不限於單通道候選：`1/96+1/160`、
    `1/100+1/150`、`1/120+1/120` 是同一個有理數，多個雙通道候選可以逐位元同分而
    不需要 `trigram`。**修正後的量測直接證偽它**——400 檔那一階出現長度 3 的段。
    連帶撤回「全語料未觀測這個缺口對該桶是有界的」。
  - **「`cjk-4plus` 與 `mixed` 裡逐字等同 `archival`」是無條件斷言，已撤回。** 證據
    只有各 20 條查詢的零觀測。修正後 `cjk-4plus` 在兩個較大規模上都是 0.3%，不是 0。
  - **spec 沒跟著改，規範層比衍生層舊。** `openspec/specs/memory-strategy/spec.md`
    逐字仍寫著 "Until it is, no artifact may claim the tier \"hits in practice\""，而
    shipped 的 doc comment 正在做那個宣稱。與 #25 R3（`ltm-analogy.md` 自稱 SoT 卻
    落後於它的摘要）**同形狀、同一週重演**。已改寫成「已在子集上量到」並寫入兩條
    引用限制（不得從觀測段長推上限、不得用 JSON 解析器讀分數）。
  - **一段撤回敘事是憑空的。** CHANGELOG 與量測紀錄都寫著「code 註解一度宣稱這一檔
    『實務上會命中』、已撤回」。`git show 9e5bb3c` 的那一行是**禁令**；被引號括起來
    的「原文」`git log --all -S` 只命中初版 commit 自己。那是 issue body 對一個未落地
    工作狀態的描述，被當成 repo 事實轉述了。
  - **抽樣腳本沒提交，而它有一個真缺陷。** 目的地路徑用 `f.parent.name / f.name`，
    不同 project 下的同名檔互相覆蓋（400 檔只落地 398、1600 檔只落地 1584），
    **被覆蓋的是哪幾個隨複製順序而定**——初版的檔案層巢狀性確實破了。已提交
    `scripts/sample-corpus-scales.py`，用完整相對路徑、結束前當場自證巢狀性，
    並擋掉「目的地在 repo 內」。
  - **`.gitignore` 缺 `*.jsonl`** ——一份格式列舉，漏掉的偏偏是本 repo 唯一真正處理的
    那種第三方逐字內容，而 #18 的重現步驟正好教人把語料副本落到磁碟。
  - 探針的其餘修復：守衛從 XOR 改成「兩個根都必須顯式給」（初版**唯一沒被擋的**那支
    會對生產索引寫入）、空字串視同未設、stderr 與 stdout 並行排空（初版只處理單向，
    另一向仍死鎖）、子行程 timeout、查詢失敗改非零 exit、五桶一律都印、`k` 解析失敗
    不再靜默退回 20、檔頭用法示例不再逐字就是守衛要擋的指令。

- **#25 第三輪 verify**（`11b614a`+`b30f9c2`；這輪 5/5 lens 全跑完，補上第二輪因週配額
  用盡而從未執行的 requirements / logic / devils-advocate）。**核心邏輯零 finding** —— 欄位
  對位、layout 4→5 遷移、生產路徑無特權元素三項獨立複核皆通過。問題全在文件遷移與量測：
  - **`.claude/rules/ltm-analogy.md`（自稱 source of truth）落後於它自己的摘要。** 該檔開頭
    逐字寫著「三處不要各寫一份完整版，那是保證會漂移的結構」，而我上一輪只改了摘要
    （CLAUDE.md），讓漂移以最糟方向發生：**摘要比 SoT 新**。性質 1 仍寫「違反兩次」、
    性質 5 導出的不變式 3 仍是單數 `sessionId`。已補上第三次違反，並記下它為什麼偽裝
    得最好——**存進去的不是一個 id，而是一個挑選結果**；會變的不是那個值，是產生它的
    規則。判準因此推進一層：不只問「這個識別碼會不會變」，還要問「這個值怎麼被決定，
    那個決定會不會隨無關的東西改變」。
  - **README.md 兩處未遷移**，其中一處把已被證偽的規則當**現行行為**寫在「刻意的，不是
    暫時的」清單裡——live spec 已逐字寫「That rule never held」，門面仍在宣傳它。
  - `fix-band-semantics-and-turn-identity` 的 `design.md` 第三處（Implementation Contract 的
    Interface/data shape：「`session_id` remains a column」）與 `tasks.md` 兩處仍記載已移除
    的規則，其中一條 Verify 的三個指涉（spec Example、fixture、測試名）全部落空。
  - `CorpusScanner.swift` 的型別文件仍以舊四元組敘述不變式 3、並稱 session 是 chunk 的欄位。
  - **補量的母體錯了（DA 抓到，我在修「引用落空」的動作裡重犯同類錯）**：`MAX(chunk_sources
    .timestamp)` 只在「一個 chunk 有 ≥2 個 source 列」時才有多於一個成員，那個母體是
    **2,736**，而我上一輪量的是只要求 `uuid`+`timestamp` 的寬鬆母體 **23,908**——差 8.7 倍，
    其餘是 tool_use/result 這類永不進索引的行。0 相異於超集確實蘊涵 0 於子集（我也直接
    量了子集＝0/2,736），所以結論沒變，但「量測要涵蓋你宣稱的那件事」指的是**母體也要
    對得上**。已改用正確母體，並在該節寫明兩個母體的差異與它們為何不可互相比較。

### Fixed
- **#25 第二輪 verify 的四條 findings**（`11b614a` 之後；該輪 5 個 lens 只跑完 2 個——
  requirements／logic／devils-advocate 都因週配額用盡失敗，覆蓋不全）：
  - **待歸檔 delta 的修法先前不夠**：上一輪只改掉 delta 裡「most recently observed」那一句，
    但 `## MODIFIED Requirements` 是**整條 Requirement 替換**——archive 一跑仍會刪掉本輪新增的
    「There is no privileged single source」「element zero is not special」「owns the definition」
    等全部條款，而 `retrieval` 與 `ltm-cli` 兩處**逐字指名**該 Requirement 為定義來源。已把
    delta 的 body 同步為 live 全文，並用腳本逐條核對（3 個 Scenario + 5 個關鍵子句全數涵蓋）。
  - `fix-band-semantics-and-turn-identity` 的 `design.md` 仍有兩處規定被移除的規則（含
    Implementation Contract 的驗收條件），已補上 superseded 註記。
  - live `corpus-indexing` spec 自我矛盾：同一份檔案先說 chunk row 只剩三個純量欄位，
    Scenario 仍要求「all four pointer fields」——layout 5 之後那是結構上不可能成立的驗收條件。
  - **誠實邊界違規（自己犯的）**：spec 與程式碼註解引用
    `docs/measurements/2026-08-18-resume-duplication.md` 宣稱 timestamp 前提「已量測」，
    而該紀錄第 62 行明文寫著「不涵蓋時間戳是否相同」。**補量**：唯讀掃 8,680 檔、23,908 個
    跨檔 uuid，時間戳相異率 **0.00%**（0/23,908），寫進該紀錄的「補量」一節，並把 spec 與
    註解改成引用這個具體數字＋明示它是語料當下的形狀而非寫入契約。
  - 順帶移除 `refreshNavigation` 裡 `ORDER BY … source_key DESC` 這個**死 tiebreak**（只取
    timestamp 時平手取誰都一樣），改為 `MAX(s.timestamp)`——在一份專講「source_key 排序＝
    位置定址」的檔案裡，那條殘留會讓讀者以為 timestamp 仍有 path-derived 成分。
  另補驗兩件 verify 因 lens 掛掉而未查的事：(1) layout 4 → 5 對既有 DB——實測手工造的
  layout-4 庫（含 NOT NULL `session_id`）遇新 binary 乾淨觸發全量重建、舊表連欄位一併丟棄，
  無半套狀態；(2) `loadChunk` 欄位索引整體前移一位——用各欄位值互不相同的資料端到端驗，
  每欄都取到自己的值，無錯位。(#25)

### Changed
- **導航的 session 分量改成集合，`chunks.session_id` 欄位移除（#25，index layout 4 → 5，需重建索引）。**
  上一版（`a28d3dc`）保留了一個「代表值」純量，`/idd-verify #25` 指出它與 `refreshNavigation`
  是兩個方向相反的寫者（儲存取 `source_key` 極大、回傳取極小），同一份 DB 對同一則 turn
  給出兩個不同的值。往下追根因不是方向選錯，而是**「挑一個代表」這個動作本身**：
  - 實測（三步）：一則**內容從未改動**的 turn，其代表值會因為**另一個 resume 檔出現**
    而改變——`{M,S}` 時回報 M，加入 `s-A` 後回報 A，加入 `s-Z` 後儲存值變 Z。兩個方向
    都不穩定，因為極值隨集合成長而移動。
  - `source_key` 是檔案路徑＝**位置**。以它挑代表就是位置定址，違反 `ltm-analogy` 性質 1
    「內容定址，不是位置定址」。CLAUDE.md 記載這條判準已被違反兩次、判準是「會不會變」
    而非禁用清單——這是第三次，也是偽裝最好的一次（它看起來是個穩定純量）。
  - 人類記憶的對應：source memory 與 content memory 本來就可分離，來源是複數或缺失
    都不損害記憶本身；把它壓成必填單值是模型錯了，而資料層（`chunk_sources`）早就是複數。
  修法是**拿掉特權元素**而非拿掉集合：`ScoredChunk`／`QueryHit` 的純量 `sessionID` 移除，
  `sessionSources` 就是導航資訊；`--json` 移除 `sessionId`、保留 `sessions`；human 輸出
  依來源數用單／複數標籤列出全部。`chunk_sources.session_id` 與 `CorpusChunk.sessionID`
  保留不動——那些是逐來源的真實事實，不是挑出來的代表。
  中途曾試「留欄位但不維護」的折衷，被不變式 2 的性質測試擋下：停止維護後該欄位的值
  變成 insertion-order 相依，增量與全量重建不再等價。**那條性質測試賺到了它的位置。**
  同時把 session 的不變式 2 覆蓋從 `ChunkRow` 搬到 `chunk_sources` 的比較裡——資料搬家，
  覆蓋要跟著搬，否則等於靜默移除該性質的保護。
  三份 spec（corpus-indexing 為唯一定義者）、CLAUDE.md 不變式 3、以及尚未歸檔的
  `fix-band-semantics-and-turn-identity` delta（它原本會在 archive 時**靜默覆蓋**掉這些
  改動）一併更正。

  <details><summary>上一版（<code>a28d3dc</code>）原本的條目，保留供追溯</summary>

  導航從「挑一個來源」改為回傳全部來源；`ScoredChunk`／`QueryHit` 新增
  `sessionSources`；純量 `sessionID` 保留為「來源集合的代表值」並宣稱
  「由集合導出而非獨立計算——不存在兩個寫者」；`timestamp` 維持純量；
  `--json` 新增 `sessions`；human 多來源改複數標籤；補上 issue 明文要求的
  相同時間戳測試。

  **其中「不存在兩個寫者」是錯的**（`refreshNavigation` 仍在寫、且方向相反），
  而「代表值」這個概念本身是上面那條記載的病灶。其餘各項仍然成立並保留在
  現行實作裡。

  </details>

### Fixed
- 第五輪（最後一輪）修復 `add-spreading-activation-fixes`（#15），並在此停止迭代：
  - **補回被上一輪誤刪的 SHALL**：round-4 把 `memory-strategy` 的條件「延後」給 `memory-events` 時，把「`dismissed` 不作為擴散**來源**」（suppression 不擴散）這條規則刪掉了，而延後清單裡寫的是另一條完全不同的規則（dismissed 作為**目標**不接收擴散）。結果是來源側那條 SHALL 在整個 spec 樹裡消失，只剩程式碼與測試守著它。現已補進 `memory-events`（唯一權威來源），並明寫兩者是不同方向的兩條規則。
  - **把「部分重述」改成「完全不重述」**：round-4 的延後句雖然說「not restated here」，同一句話卻又列了三個條件，而那份列舉出生就漏了第四個（`spreadingActivationFactor > 0`）——第五輪了，同一個「列舉會漏」的形狀。改成純指標，一個條件都不列，並在文字裡寫明「列舉本身就是缺陷，不是漏掉哪一項的問題」。
  - **design.md 的 Implementation Contract**（不是 Decision 1）仍是四個閘門全缺的無條件宣稱，而它以驗收條件的身分出現、比 spec prose 更強。改成同樣單向指向 `memory-events`。
- **誠實邊界（本輪最重要的發現，非缺陷修復）**：擴散機制由 `opened`/`cited`/`pinned` 事件驅動，而 **shipped code 沒有任何路徑寫入這三種事件**——`LTMService` 唯一的事件寫入點固定寫 `shown`，`Sources/` 裡唯一的 deliberate 事件建構是 `Event.pin` 的定義本身（無呼叫端）。因此 `project()` 的擴散迴圈在生產上**一次都沒執行過**，五輪 verify 修的全是一個目前只在測試裡活著的機制的規格文字。這件事已寫進 `memory-strategy` spec 與 `docs/memory-systems/README.md`——先前 spec 對一個小得多的 `InterleavingHarness` 缺口特地標了 latent，卻對「整個機制生產不可達」隻字未提，而 README 甚至寫著「現在是真的實作了」。
  **殘留的規格細節不一致（第五輪 verify 仍列出的 MEDIUM/LOW 項）不影響現行行為**，因為現行行為裡這條路徑跑不到；要等 Stage 2 MCP（#24）補上 deliberate 事件寫入路徑，這些 SHALL 才會第一次被生產資料考驗，屆時應重新檢視。(#15)
- 第四輪修復 `add-spreading-activation-fixes`（#15）：前三輪都是「發現複本 → 改掉那幾份」，這輪改用逐條 SHALL／scenario 稽核，對擴散機制的每一條規範句在 `memory-events`、`memory-strategy`（各含 main spec + archived delta spec）、`docs/memory-systems/README.md` 五個位置比對是否一致：
  - `memory-events` 的「gains reinforcement」scenario 仍斷言無條件「nonzero, strictly less than」，跟上一輪才收斂到 Requirement prose 的「來源貢獻須為正」條件不一致——scenario 補上同一個條件。
  - `memory-strategy` 的 Requirement 本體（`human-like` SHALL treat anchors...）先前完全沒被三輪改過，仍是無條件宣稱，且與 `memory-events` 已有的三個例外（正貢獻、dismissed 排除、群組上限）不一致。這次不是再抄一份條件過去（那正是前三輪一直重演的複本問題），而是把這條 Requirement 改成明確指向 `memory-events` 當唯一權威來源、自己不重述條件——減少未來還能漂移的複本數量。
  - `memory-strategy` 的對應 scenario 同樣補上來源貢獻須為正的條件。
  - `README.md` 這份被 round-2 CHANGELOG 明確點名的追蹤複本，round-3 的系統性掃描仍然漏掉了——這輪補上同一個條件。
  逐一核對後，main spec 與 archived delta spec 的對應 Requirement 區塊現在逐字相同（用 diff 確認，只有 `@trace` 區塊的差異，那是預期的）。(#15)
- 第三輪修復 `add-spreading-activation-fixes`（#15）：前一輪把「假宣稱／過時數字」修在某一處、忘了同一句話的其他複本，這輪對整個 repo 做系統性 grep 掃描，一次把所有複本改掉，而不是逐一頭痛醫頭：
  - `design.md:27` 的「透過 `spreadingActivationFactor < 1` 保證，見既有 precondition」——precondition 是上一輪才補的，這句話寫下的當時是假的，先前只改了 spec 沒改 design.md 本體；
  - `design.md` Decision 4 本文與 `Sources/LTMMemory/Projection.swift` 迴圈上方的程式碼註解仍寫著「50」，跟已改成 2000 的常數矛盾；
  - `design.md` Decision 4 與 `tasks.md` 2.2 仍把「`suppression` 數值非零」與「有 dismissed 事件」寫成等價——這個等價已被上一輪的修法本身證明不成立；
  - `LTMEval.Interleaving.present` 這個符號名是錯的，正確是 `InterleavingHarness.present`，四處文件複製了同一個錯誤引用。
  另外收斂了這輪修補動作自己新引入的兩個問題：memory-events spec 新加的「其他策略以 factor=0 投影」括號豁免範圍過寬（把整條 Requirement 都豁免掉，不只是擴散相關的三條 scenario）；收斂後的「逐筆嚴格小於」SHALL 仍可被合法的 `openedWeight`/`citedWeight`/`pinnedWeight: 0` 推翻——與這輪要修的 fix #4 同一類缺陷，在同一份文件的另一句重演，這次把前提條件（來源貢獻為正）寫進 SHALL 本身。也補上一條真正釘住 cap+1（2001）邊界的測試，並清掉舊測試裡沒整理乾淨的自我更正註解。(#15)
- 修正上一輪 `add-spreading-activation-fixes`（#15）修復本身留下的 6 個 `/idd-verify` 缺陷（第二輪 follow-up verify 發現，修法就地補在同一個 commit 基礎上，未開新 change）：
  (1) `memory-events` spec 的「Impressions alone produce no reinforcement」scenario
  文字本身沒有排除同框有擴散的情形——先前只在 prose 加了例外說明，scenario
  的 GIVEN/THEN 依然逐字被生產行為推翻；現在 scenario 本身帶上排除條件；
  (2) `spreadingActivationFactor < 1` 先前只在文件宣稱、沒有 precondition 執行
  ——與 fix #4 要修正的「假宣稱」同一類缺陷，現在補上 precondition，並把
  spec 的 SHALL 收斂成誠實的逐筆保證（不宣稱總量有上限）；
  (3) 同框群組大小上限從 50 調整為 2000——50 比 `ltm query --k` 支援上限
  （1000）低了 20 倍，正常查詢就會靜默關掉擴散；
  (4) dismissed anchor 排除擴散的判準從「suppression 數值是否非零」改為
  「dismissed 事件是否存在」——`dismissedWeight: 0` 是合法參數值，先前的數值
  判準在這種設定下會靜默失效；
  (5) 補齊 archived design.md 的 AI4o 出處 errata（先前只修了 Open Questions
  段落，Decisions 段落的同一個假宣稱漏了）；
  (6) `docs/memory-systems/README.md` 補上本輪修復的行為變更說明。
  另外把 `LTMEval.InterleavingHarness.present`（A/B 比較 harness）繞過 human-like
  專屬擴散閘門這件事記為已知限制（目前無生產呼叫端，潛伏而非即時生效，完整
  修復需要重新設計比較 harness 的 projection 共用契約，留待後續）。(#15)
- 修正 `add-spreading-activation`（#15）擴散機制的 6 個 `/idd-verify` 缺陷：
  (1) 擴散不再違反 `memory-events` spec 既有「Only deliberate interactions
  reinforce」保證——改為在 spec 裡明文記錄為已知例外，而不是安靜違反它；
  (2) 擴散收斂為 `human-like` 專屬，`MemoryStrategy` 新增
  `appliesSpreadingActivation` 能力宣告，`conservative` 不再意外吃到擴散；
  (3) `ComparisonScorer`（`ComparisonReport.swift`）新增第三種合法略過情形
  （`presentation` 非 nil 但查無對應 `PresentationRecord`），生產查詢不再
  系統性地讓比較路徑拋錯；(4) 擴散不再對已被使用者明確 `dismissed` 的
  anchor 生效，同框群組加防禦性大小上限，避免無界放大；(5) `ltm query --json`
  補上 `presentation` 欄位；(6) 已歸檔的 #15 design.md／proposal.md 補
  errata，更正不成立的 AI4o 出處宣稱。(#15，`add-spreading-activation-fixes`)
- doc comment 清掉指向已不存在 API 的引用：`EventStore.allEvents(skippingCorrupt:)` 已改名為
  `allEvents(skippingUnusable:)`，四處殘留舊名稱的引用（`Anchor.swift` / `CanonicalCoding.swift` /
  `EventStore.swift` ×2）已更新為現行名稱；三處刻意的歷史敘述（「先前的簽章是…」）保留不動。
  補回 `QueryOutcome`（被 `RefreshReport` 插在正上方而消失的）doc comment。修正
  `RetrievalEngineTests` 一則過時註解——「band 直接取用名次」正是 #24 拆掉的缺陷（band 現為命中
  通道數，不是名次）。(#24)
