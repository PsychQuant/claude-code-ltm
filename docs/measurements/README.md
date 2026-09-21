# docs/measurements/ — 量測紀錄的使用規則

每一份紀錄自己寫明它涵蓋什麼、不涵蓋什麼；引用時**指名出處**（CLAUDE.md 誠實邊界）。
本檔只放跨紀錄共用的規則。

## 基準查詢使用規則（#63）

### 為什麼需要規則

量測用的查詢字串一旦落進 session 逐字稿裡**會被索引的欄位**，下一次量測的前幾名就是「顯示它
的那一刻」。#56 的量測把三個基準查詢寫在一行 Bash 命令列上（`for q in …`），`command=` 是
被索引的欄位之一，於是 2026-09-01T04:32:12Z 那則 turn 進了索引；v0.4.0 用同三個查詢重跑，
三個的第一名全部是那則命令（觀察記在 issue #62 的 Diagnosis comment，**不是**本目錄的紀錄；
本目錄沒有涵蓋那次觀察的檔案）。從那一刻起，這三個查詢量到的是「自己的量測命令有多好找」。

### 什麼會進索引（判準，不是清單）

判準是「這個字串會不會落進 `CorpusScanner.indexableText` 讀的欄位」。今天那些欄位是：

| 逐字稿裡的位置 | 進索引？ | 查法 |
|---|---|---|
| `message.content` 是**純字串**（使用者鍵入的 prompt 常是這一種） | **會**，整段、不截斷 | `Sources/LTMIndex/CorpusScanner.swift` 的 `indexableText` 第一行 `if let text = content as? String`。結構普查（只印計數；掃 `~/.claude/projects/**/*.jsonl`，留頂層 `type` 為 user／assistant 的紀錄，統計 `message.content` 是字串還是陣列）：2026-09-07 全語料 user 紀錄約 8% 走這條路 |
| `text` block（使用者輸入、Claude 的散文、compaction 摘要） | **會**，全文 | 同檔 `indexableText`，`case "text"`。compaction 摘要那句的查法：掃 `~/.claude/projects/**/*.jsonl` 含 `isCompactSummary` 的行、統計頂層 `type`——全部是 `user`，所以通得過 `chunk(from:)` 的 user/assistant 守衛（只印計數，不讀內容） |
| `tool_use` 的工具名＋七個 metadata 欄位：`command` / `file_path` / `path` / `pattern` / `query` / `url` / `description`，各取前 200 字元 | **會** | 同檔 `toolMetadataFields`（封閉列舉，隨該常數變動；改它就要回來改這段）與 `toolUseMetadata`（工具名先進 `pieces`） |
| `tool_result` 的內容（Bash 的 stdout、`Read` 讀到的檔案） | 今天**不會**，只記 `⟨tool_result ok\|error⟩` 標記 | 同檔 `case "tool_result"`；`Tests/LTMIndexTests/CorpusScannerTests.swift` 的「tool_result 只記成敗，不記內容」。**這是 #6 追蹤中的決定，可能改變** |
| `tool_use` 的其他欄位（Write 的 `content`、Edit 的 `old_string`／`new_string`、Agent 的 `prompt`） | 今天**不會** | 不在 `toolMetadataFields` 裡（同上，隨常數變動） |
| `thinking`／`image`／`document` block；頂層 `toolUseResult`；非 user/assistant 的紀錄（`attachment`、`system`） | 不會 | `indexableText` 的 `default: continue`；`chunk(from:)` 只讀 user/assistant 的 `message.content` |

所以真正危險的動作是：查詢出現在 **Bash 命令列**（`echo`、`ltm query <q>`、`grep <q>`）、
**`ltm_query` MCP 工具的 `query=`**（`Sources/LTMMCP/RetrievalTool.swift` 的 input 欄位名就是
`query`）、任何工具呼叫的 **`description=`**、`Grep` 的 **`pattern=`**，以及**被貼進或引述進對話**
（那是 `text` block）。`cat`／`Read` 查詢檔的輸出本身今天不進索引——但 Claude 看到之後引述它的
那句散文一定進，而且 #6 隨時可能把 tool payload 收進來——所以規則把邊界劃在 jsonl，不劃在索引。

### 查詢集在哪、怎麼用

- 查詢集：`scripts/baseline-queries.txt`（一行一條、`#` 註解）。它的檔頭是這裡的**摘要**，改這裡要
  一起改它；但有機制守的只有測試裡明寫的那幾項——查法：`Tests/LTMMCPTests/BaselineQueryFileTests.swift` 裡
  `verdictAlphabetIsStatedIdenticallyEverywhere` 的每一個 `#expect`，加上另一條測試的 `requiredHeaderPhrases`
  （檔頭 6 個必備短語——這個數字由同步測試對照 `requiredHeaderPhrases.count`）；規則本文沒有機制守（#63 verify R3 就是檔頭漏改被抓到的）。
  `.gitattributes` 對它設了 `-diff`（`scripts/rrf-tie-queries.txt` 同）。它讓 git 把這個 blob **當
  binary 處理**——只影響「產生 diff 或搜尋內容」的命令，不改變 blob 本身：
  `git diff`／`git show <rev>`／`git log -p` 只印「Binary files differ」、`git grep` 只印
  「Binary file … matches」；凡是把 blob 原樣吐出來的命令照樣帶全文——`git show <rev>:<path>`、
  `git blame`、`git cat-file -p`、`git archive`、`git diff --text`、`git diff --no-index`（對 **repo 外**
  的路徑；屬性跟著 repo，複製出去就裸露）、`git format-patch`（base85 blob，肉眼讀不到，但 `git apply`
  一步還原，等同全文）。**這份例外清單會漏，判準是「它會不會把 blob 原樣吐出來」**；要看內容在 session
  **之外**做。GitHub 網頁的檔案檢視與 raw 也不受影響。
- 量測：`scripts/measure-baseline.sh [k]`——讀檔、逐條跑
  `ltm query --all-projects --k <k> --json -- <查詢>`（旗標以腳本為準；注意 `--all-projects`
  是全語料，與舊紀錄的單一 project 不同），**stdout 第一行是 `set sha256:<12 hex> k=<k>`**（非註解行
  內容的指紋，加這一次的 k；紀錄要連這一行一起引——`#N` 是檔內位置，退役換一條之後同一個 `#N` 就是
  別的查詢，而 verdict 全是「前 k 名」的性質，所以兩份紀錄這一行不同就不能逐列對齊），**之後每列
  `#N <ms>ms <verdict>`**（例如 `#3 812ms clean tool=1`；整數毫秒後面緊接字面 `ms`）。指紋是未加鹽
  的 sha256 前 48 bit：不含查詢文字、不會造成 self，但能讓持有候選的人確認一次完整猜測；而持有其餘 N−1 條的人
  （退役換一條是規則 3 的預設處置，所以「N−1 已知」是常態）可對最後那一條做**離線列舉**——短技術詞組對
  48 bit 足以無歧義判定（那個對手本來就讀得到 jsonl 裡的副本，結論不變，但它是性質不是零）。這段只有這一份，
  腳本檔頭只指回這裡。
  `#N` 是檔內第 N 條非註解行（去掉行首行尾的 **ASCII** 空白後，空行與 `#` 開頭不算——腳本與測試
  用同一個定義，而且刻意只認 ASCII：bash 的 `[:space:]` 對全形空白隨 locale 變、Swift 的不變，
  所以兩邊都不剝它，測試另外斷言查詢檔裡沒有控制字元與非 ASCII 空白——寫成性質（DEL、五個 ASCII 空白
  TAB／LF／VT／FF／CR **以外**的 C0、以及非 ASCII 的 Zs／Zl／Zp／Cf／Cc；權威是測試的 `isForbiddenScalar`，R14
  更正這裡漏寫的例外）不是清單——且每條不超過 64 個純量）。
  密鑰用命令替換餵進環境（`LTM_ANCHOR_KEY="$(~/bin/ltm memory --export-key)" scripts/measure-baseline.sh`），
  不落地；查詢檔預設在腳本旁——「腳本旁」照 bash 自己找腳本的順序解（`$0` 含斜線取其目錄；裸名先看 cwd、再搜
  PATH——細節只有一份，在腳本檔頭），有測試從別的 cwd 經 PATH 呼叫裸名來驅動。
- verdict 是**封閉字母表**：`clean tool=<n>`／`self tool=<n>`／`empty tool=0`／
  `error(<rc>|sig<N>|blank|exec|json|shape|judge)`。「封閉」由 `Tests/LTMMCPTests/BaselineQueryFileTests.swift`
  的**同步測試**執行：腳本檔頭的 token 列、本行的 token 列、測試自己的 `errorTokens`、腳本程式碼裡的
  `error(...)` 輸出點四個集合逐一相等，腳本裡的 `ERROR_TOKENS` 等於它們扣掉 `<rc>`／`sig<N>` 的子集（那兩個
  是樣式不是字面），任一處多一個少一個都紅。「輸出點」的判法是形狀不是猜測：程式碼裡**每一個** `error(`
  出現（整行註解除外）都必須是兩種輸出述句形狀之一——python 的 `print(…); sys.exit(0)` 且字面在雙引號裡、
  bash 的 `valid_row "$row" || row="0 error(<token>)"`——否則紅，**行尾註解裡的字面也紅**（R6 用剝註解擋
  「刪掉的輸出點靠註解補回」，R7 證明那個剝法在兩個方向都不是它宣稱的規則，於是不剝、不猜；沒在同一行閉合的
  `error(` 也紅）。
  它擋的是輸出點被刪／改名而清單沒跟；**不證明那一行可達或會執行**，那由每個 token 的行為測試扛；
  `valid_row` 用變數比對、不寫字面，所以沒有被略過的區段。同一條測試也做一個**存在性**檢查：每個 token 在
  **別的**測試裡有一條帶「產生標記」、帶 `#expect(` 的活斷言行，其 `#expect` 的**第一個引數**（期望值那一側，
  以括號配對切出、切不出來就紅、與訊息的寫法無關）寫著它的 tail（要驗的
  token 從 `errorTokens` 導出；標記在檢查函式裡執行期拼出，且**斷言**該測試自己的行範圍內沒有那個字面——
  宣告行以「整行以 `func NAME(` 開頭且恰好一行」找、NAME 由 `#function` 取；標記後列的名字集合必須**等於**該行
  期望值側的 tail 集合）。它擋的是
  產生點被刪掉／改名／註解掉而清單沒跟著改；**它不證明那條斷言被執行**（`.disabled`、迴圈跳過看不到）
  ——執行由整份測試檔綠保證。這一條的版本史（哪一輪、哪個 lens 抓到什麼）不在這裡複述——查 issue #63
  各輪的 verify comment（輪次編號是那些 comment 的索引，可以留；誰抓到、幾個讀者不寫）。
  同一條測試還同步了：退役清單（README 與測試）、七個 metadata 欄位名（`toolMetadataFields` 常數、
  README 表、查詢檔檔頭）、離開碼（腳本檔頭與程式碼裡的 `exit N`）、三個 verdict 詞（README 與腳本檔頭）、
  CHANGELOG 含 `clean|self|empty`、README 寫的每條純量上限與目前條數（對照測試常數與真檔）、截斷長度
  （`toolMetadataFieldLimit`：查詢檔檔頭、README 與腳本檔頭的每一個「N 字元」）、指到查詢檔的三種拼法（識別碼
  `$QF`、檔名字面、環境變數名）各自的出現次數——那是拼法列舉、**不是**「只開一次」的證明，先把路徑存進第四個名字再開
  它看不到（R13）——以及餵 `$QF_CONTENT` 的 process substitution 的個數、腳本前四行是 trap 清除／`builtin set +x`／白名單變數／re-exec 的
  `case`（R14–R17）、README／CHANGELOG 不得再出現被檔頭退回的邊界句拼法（R18）、空集合指紋的字面、白名單三邊互相釘住（變數＝檔頭散文、Sources 的 `environment["…"]` 讀取點 ⊆ 變數、Sources 不得有 `getenv(`
  或非大寫字面鍵的 `environment[`——拼法守衛，改名綁定看不到）、
  `.gitattributes` 對兩個查詢檔的 `diff` 屬性經 `git check-attr` 是 `unset`、字元守衛不用任何 `[X-Y]` range。這份清單是**摘要**，會漂移；權威是查法：讀那條測試的每一個 `#expect`——不在那裡的
  複述就沒有機制守著。任一列是 `error(…)` 腳本最後以 1 離開（每列照印；`empty` 不計入）。離開碼 0 的意義是「0 **且**
  stdout 第一行是 set 行」——這是消費端的硬規則，理由是**存在**讓 set 行印不出來而 rc 仍是 0 的失效（`SHELLOPTS=noexec`／`onecmd`、
  fd 耗盡的其中一段——腳本檔頭的 rlimit 段，R14／R17）；同一族的別段給 rc 1／70／134，所以「都給 rc 0」不成立（R18 更正 R17 的全稱），
  規則只看「0 且 set 行在」這個合取。
  `blank` 是那一行在 Unicode 空白摺疊後是空的（只有 U+3000 這類非 ASCII 空白）——行定義把它算成條目、
  judge 卻會得到空針，空針對任何命中都算 self，所以不跑 ltm、直接報 error；測試同時斷言查詢檔裡沒有
  這類字元。
  離開碼全表在腳本檔頭。
- **`self`** = 前 k 名至少一個 snippet **含這條查詢的原文**（空白摺疊、大小寫摺疊後的子字串比對）——儀器看見了
  自己。量測命令列、`ltm_query query=…`、被引述進散文的那句，都是這個形狀。self 那一列的命中品質
  這一輪不可比；耗時仍可比。**`clean` 不是「乾淨」的證明**：它只說前 k 名沒有 snippet 含原文——
  排在前面但不含原文的殘影，它看不見。`empty` 是零命中——查詢已經對不到任何東西，這不是 clean。
- **`tool=<n>`** = 前 k 名裡含 `⟨tool ` 的 snippet 數。**它不是污染訊號**，理由是它量的不是「這條
  查詢」而是「前 k 名裡有沒有工具 chunk」——而後者的預期是常見的：工具 metadata chunk 佔 chunk 表
  **至少**四成（#67 的 41.7% 只數 metadata-only chunk，而 `tool=<n>` 數的是任何含 `⟨tool ` 的 snippet，所以那是下界；**那是 chunk 表的份額、不是前 k 名的出現率**——檢索不是均勻抽樣，
  兩者不相等，實際的前 k 名出現率要在真索引上跑一次才知道，而那一次還沒跑），拿它當 dirty 會讓
  每一個前 k 名含工具 chunk 的列不可比——有多少列，同一句：還沒量。它是 #62（self-hit 的檢索層排除）要移動的那個量，印出來給 #62 的前後比較看
  ——**所以 #62 前後 `self`／`tool` 的變化量的是 #62 的效果加上兩次量測之間語料的成長，不是語料
  變乾淨了**（#62 自己的實作 session 就在談 self-hit 與工具 chunk，特別容易排進這些查詢的前 k 名）。
  另外，`tool=<n>` 也會數到**談論**這個標記的散文——純字串 `message.content` 不截斷、整段進索引；
  這種紀錄幾乎全是 #63 自己的 session 寫的，而且**會隨討論儀器的 session 增加**（verify 的兩輪之間就
  多了一筆），所以這裡不給計數只給查法：掃 `~/.claude/projects/**/*.jsonl`（計數這一句只關心 message 紀錄，spill 檔沒有
  message 結構；副本掃描要掃**全部**檔案，見規則 1），統計 user／assistant 紀錄裡
  `message.content` 是純字串且含 `⟨tool ` 的筆數（只印計數）。
  第一版的判準是「含 `⟨tool ` 或含 `ltm query`」就 dirty；#63 verify R2 指出那量的是
  「有沒有工具 chunk」不是「這條查詢被自己污染了沒有」，於是改成把命中拿去跟查詢比對。
- `<ms>` 是 `ltm` 行程 fork→exit 的 monotonic 牆鐘（含 process 啟動、查詢前的增量併入、檢索、
  輸出；不含 judge），單一樣本、無暖身；第 1 列是否系統性偏高沒有量過（要量：同一集合連跑兩次、比第 1 列）。

### 三條規則

1. **查詢字串不得落進會被索引的欄位。** 具體（由上表導出，不是另一份清單；表改了這裡要跟）：
   不在 Bash 命令列上帶查詢、不放進 `Grep` 工具的 `pattern`、不餵給 `ltm_query` MCP 工具、不寫進
   任何工具的 `description`、不貼進對話、不在回覆裡引述——連「第 N 條是『…』」這種半句都不行。
   `cat`／`Read`／`git blame` 查詢檔也不做（理由見上表下方那一段）。
   **編輯查詢檔在 Claude Code 之外的編輯器做**——**且 Claude Code 沒在跑、或那個 session 不在這個 project**：Claude Code
   對外部編輯器改動會落一筆 `attachment.type = "edited_text_file"`，`snippet` 帶改動附近的內容（R31 security：全語料含 ≥1 條的
   11 筆裡有一筆是它，1,752 個字元長、2/8 條，2026-09-07T04:52:11Z）——這條建議自己帶著一個沒寫出來的前提。在 session 裡用 Write／Edit 工具是**今天**索引安全
   的（`content`／`old_string`／`new_string` 不在那七個欄位裡），但它不守本規則劃的 jsonl 邊界：
   Write 的 `content`、Edit 的 `toolUseResult.originalFile`（**整份檔案**，不是改到的那幾行）、Read／
   Edit 之後的 `attachment` 紀錄，每一次都把完整查詢集存進 jsonl 一份——而**印**與**讀**也會：一個 Bash
   命令把整份檔案印進 stdout 是一筆 `toolUseResult.stdout`，一次 `Read` 是一筆 `toolUseResult.file.content`。
   **Bash 對 project root 底下檔案的編輯也會落一筆**：Claude Code 把那次 Bash call 對 project root 底下檔案造成的變更記成
   unified diff 進 `toolUseResult.bashEditDiff`。量到的觸發條件（R30 自檢、R31 security 重量，**母體逐句指名**——R30 版把本
   project 的 hunk 數放在「全語料」開頭的句子裡，R31 抓到）：全語料 2,632 筆 file entry **全部**在 project root 底下（2,544 在該筆
   的 `cwd` 底下、88 不在該筆 `cwd` 底下但在 jsonl 目錄名解回的 project root 底下——其中 77 筆的目錄名解碼有歧義，是把路徑同樣編碼後比前綴確認的）、`/tmp`／`$TMPDIR`／`/private/var/folders` 0 筆；
   主 session 1,411 筆與 subagent 431 筆都會產生（jsonl 紀錄的 `isSidechain` 欄位；subagent 逐字稿在 `<session>/subagents/**`，
   走訪要遞迴——只掃頂層 `*.jsonl` 會數到 0 筆 subagent）；context **最多 3 行**（unified diff 預設）——全語料 5,061 個 hunk
   的前置 context 分佈 {0: 567, 1: 19, 2: 157, 3: 4,318}、**後置** {0: 784, 1: 56, 2: 52, 3: 4,169}（檔首、新檔、EOF 的 hunk 少於 3），
   本 project 535/535 前置都是 3。數字是 2026-09-22T03:56+08:00 的快照（R31 verify-fix 重跑；R31 security 的快照較小、形狀相同），
   語料會長，重跑只會變大，**宣稱的是形狀**（全在 root 底下、tmp 0、兩種 session 都有、≤3 且 <3 存在）。終止符那個威脅靠的是**後置** context（終止符是檔頭最後一行、第 1 條在後），所以「編輯點離
   終止符 ≥ 3 行」這個上界成立、「都是 3 行」不成立。查法（只印計數）：遞迴走訪 `~/.claude/projects/**/*.jsonl`，取 `toolUseResult.bashEditDiff.files[].hunks[].lines[]`，
   數每個 hunk 前置／後置以空白開頭的連續行數；file entry 的路徑對該筆 `cwd` 與 jsonl 目錄名解回的 project root 比前綴（目錄名把非字母數字都編成 `-`，比對時要把路徑同樣編碼）。所以「只改註解行」不保證不帶查詢（R30，security＋DA）。**一次 call 內改完又還原
   → 零筆——主 session 量到了**（R31 verify-fix，2026-09-22：同一個主 session 裡 3 個「備份→變異→跑→還原」全在一次 Bash call 內的呼叫，
   `toolUseResult.bashEditDiff` 0 筆；正向對照組是同 session 裡 69 個離開時檔案有變的編輯呼叫，其中 40 個帶 `bashEditDiff`。查法：
   在該 session 的 jsonl 裡由 assistant 的 `tool_use.id` 對回 user 的 `tool_result.tool_use_id`，看那筆有沒有 `toolUseResult.bashEditDiff`，
   只印計數。**n = 3**，量的是「離開時無變動就不記」這條規則，不是每種還原寫法）。這件事在 R30／R31 都寫「推論、未證」：兩處探針
   都在 project root 之外，settle 不了；R31 security 在 project root 建了合成檔驗，**Workflow-harness 的 subagent transcript 根本不寫
   `toolUseResult`**——正向對照組也 0 筆——所以那種 session 驗不了，「主 session 與 subagent 都會產生」沒區分這第三種 session。
   判準是「這個動作會不會把整份檔案落到 `~/.claude/projects/**` 底下的**任何檔案**」，上面是例子不是清單（R29，security：
   R28 版寫「送進 jsonl」，而 Claude Code 今天會把大型 tool result **外溢**到 jsonl 旁邊的 `tool-results/*.txt` 與
   `workflows/*.json`——本輪檔頭短語鍵命中 36 個這種檔、jsonl 34 個；判準鍵在「jsonl」這個**位置**上，位置已經分裂，
   與 R27 的雜湊檔名同形。那 36 個檔逐檔核對含查詢的 0 個——今天沒漏，是查法的結構性盲區）。#63 實作與 verify 期間就這樣存了
   **至少 8 筆**含全部查詢的紀錄（2026-09-07 R3 verify 全語料數的：Write 2、Edit 3、attachment 1、
   Bash stdout 1、Read 1；R1 verify 的 `diff.patch` 另在該輪被讀進 agent 逐字稿）。這個數字**只會
   往上走**——R2b 寫「六份」的九分鐘前，另一個 session 剛 `Read` 過一次；所以它是下界不是計數，
   要現值就跑查法。查法（只印計數、執行期讀查詢檔、不上命令列）：掃 `~/.claude/projects/**` 底下的**全部檔案**——`*.jsonl`
   逐筆遞迴走訪所有字串葉節點、其餘檔（`tool-results/*.txt`、`workflows/*.json`……）直接比對 bytes（R30 自檢：R29 版判準已改成
   「任何檔案」而查法還只掃 jsonl，外溢的 payload 在 jsonl 裡連檔名都查不到），數「同時含全部 N 條查詢」**與「含 ≥1 條」**的
   紀錄與其 json 路徑——**兩個都要數**：`bashEditDiff` 那一筆只帶 3 條，只數「全部 N 條」的話它結構上不會出現，而「至少 8 筆」
   少算的是一個**類別**不只是一個時點（R30，security）。所以 **#6 一旦把 tool payload 收進索引，這一組查詢集就整份作廢**——這是已經發生的曝險，
   不是 if。第一版把 Write／Edit 與外部編輯器並列，理由是索引層的；本規則的邊界在 jsonl，兩者不等價。
   （本段與檔頭的第二版是在 session 內用 Bash 跑一支只改註解行的 python 改的。**R29 版在這裡寫「所以沒有再多一筆」，
   那是假的**：R30 security 量到 2026-09-19T11:10:46Z 那次「加終止符」的 Bash 產生了一筆 `toolUseResult.bashEditDiff`，
   hunk 的 context 行裡有**三條活查詢**（帶查詢的 `bashEditDiff` 全語料恰一筆；查法：走訪 `~/.claude/projects/**/*.jsonl`
   的每筆紀錄，取 `toolUseResult.bashEditDiff.files[].filePath` 以查詢檔結尾者、對其 `hunks[].lines[]` 在行程內數命中的查詢
   條數——分母「全語料幾筆 `bashEditDiff`」是會漲的時點數字，R30 當日 1,602、兩天後 1,642，不寫進句子）。而且這是**依建構**為假——
   終止符是檔頭最後一行、下一行就是第 1 條查詢，任何動到檔頭尾端的 Bash 編輯都會把最多 3 條當 context 帶出去，
   除非編輯點離終止符 ≥ 3 行。**推論**：變異測試的「`cp` 備份 → 改 → 跑 → 還原」若分成多次 Bash call，每一次
   call 結束時檔案是 modified 狀態、就會落一個帶查詢的 hunk——所以**那四步必須在同一個 Bash call 內完成**
   （CLAUDE.md 同步寫了這條）。R28／R29 的真檔盲測沒留下這種紀錄，與「都在單一 call 內完成」一致；R31 verify-fix 在主 session 直接量到 0 筆（見上、n = 3）。）
   要把 diff 交給 review agent，**給檔案路徑讓它自己 Read**，不要把 diff 內嵌進 prompt——agent 的
   prompt 是它逐字稿裡的 `text` block；而且 diff 要在設了 `-diff` 的 commit 之後產生（R1 verify 的
   `diff.patch` 產生於 `.gitattributes` 存在之前，查詢檔在裡面是明文）。唯獨查詢檔——**以及它的任何副本或備份**
   （變異測試 `cp` 出來的 `.good`、job tmp 裡的中間檔、reviewer 的私有 worktree；判準是內容不是路徑）——review
   agent 只准讀檔頭（`grep '^#'`）與統計非註解行（條數、長度、重複），不准讀內容；含查詢的備份還原後立刻刪。
   **`grep '^#'` 的安全性有確切的射程，而且只對 `baseline-queries.txt` 成立**。威脅是這個（R26，codex）：把一條查詢
   加 `#` 退役會讓那個字串脫離其餘每一條約束，而照這條規則執行 `grep '^#'` 的 reviewer 會把那條**仍然活著**的查詢
   原樣印進自己的逐字稿。兩條自動內容約束合起來擋它：「檔頭結構」（終止符恰好一行、之前只有註解、之後沒有註解）
   保證**單一 `#` 編輯**退不掉任何一行查詢——R26 版把約束綁在「第一條查詢之後」這個位置上，把**第一條**查詢註解掉時
   那一行會升格成檔頭而全綠（R27 四家實測），所以 R27 換成與位置無關的終止符；但終止符**放在哪一行**由作者自選，
   「加 `#` ＋ 把終止符往下挪一行」兩個編輯就全綠，而 `-diff` 讓 reviewer 只看得到 `Bin 4402 -> 44xx`、分不出一個
   編輯與兩個（R28，DA 對真檔實測）——所以 R28 加了「檔頭不得含曾經是查詢的字串」。**它擋得住的，寫成性質（R29 更正
   R28 版的封閉單項「擋不住的是從未 commit 過的查詢」與全稱「git 裡每一個版本」）**：一條查詢要是**曾以非註解行出現在
   這個檔的任何一個 git 可達版本**（`git log --all --full-history -- <path>`；不跟改名、不看 reflog／懸空 commit、淺 clone
   只看它有的）**或在退役清單裡**，且它的字元**依序連續**出現在檔頭區塊去空白後的連接文字裡（同退役檢查的正規化），
   就紅——所以整條搬進一行、拆成兩行、字元間插空白、大小寫改寫都紅（R29 DA 對真檔盲測：R28 版逐行比對，拆成兩行相鄰
   `# ` 全綠而 `grep '^#'` 相鄰印出、reviewer 一眼接回去）。**擋不住的**（各自量過）：字元間插**非空白**字元；兩半**順序顛倒**
   放進檔頭（連接鍵順序敏感，R30 DA）；從未進可達歷史也不在退役清單的查詢；改名之後舊名下的版本；只有 `FETCH_HEAD`／
   `ORIG_HEAD` 這類 pseudo-ref 可達的版本（`--all` 不含 pseudo-ref，R30 自檢——那是瞬時 ref，下一次 fetch 就換）。**擋錯的**
   （R30 自檢量到，這一段先前只寫擋不住什麼）：比對是子字串包含，而退役清單裡最短的條目只有 3 個字元、檔頭去空白後約
   1,956 個字元——檔頭散文哪天恰好連出那 3 個字就紅，訊息卻寫「退役要刪除、不得搬進檔頭」。今天最近的一條差 3 個字元
   （查法：對每條 fold 後的查詢，在 fold 後的檔頭連接文字裡找最長已存在的前綴／子串，只印長度差）。檔頭會長，這個邊際不是常數。取不到歷史時真檔測試**具名紅在環境那一側**、其餘八條照跑
   （R29 regression：R28 版把 `try` 放在引數位置，`.git` 不在時這八條一條都不跑。**八**是這條測試裡的 smoke 斷言數，查法要帶
   範圍——`awk '/^func baselineQueryFileDocumentsItsContractAndRetiresThePollutedQueries/,/^}/' <測試檔> | grep -c '#expect(r\.'`
   → 8（整檔不切範圍是 22，R30 自檢）；九是約束項數，第九項 `throw NotUTF8` 依設計沒有 smoke 臂——R30 regression 指出 R29 把 report 的
   「nine smoke arms」抄進兩份 artifact 而沒帶查法）。除此之外檔頭區塊的內容仍不受約束
   （長度、重複、純量上限一律不適用；R27 實測：塞 200 字元段落，八條全過）。所以**退役一條查詢必須刪除**；搬進檔頭
   今天是機制紅的，不再只是人守。這條真檔測試因此需要 git（在 PATH 上、且在 checkout 裡），R28 起。`rrf-tie-queries.txt` **一條內容約束都沒有**（`checkQueryFile` 只跑在
   baseline 上，全 repo 唯一碰它的測試是 `git check-attr`），對它 `grep '^#'` 的安全性零機制——它的處置追蹤於 #68。
   清「repo 之外的副本」的判準是**內容**，鍵不能是檔名、也不能只靠地點、也不能只鍵**現在這一版**：R25 用兩個地點的
   列舉漏掉 `~/.claude/jobs/**` 七棵 reviewer 樹，並把「repo 外零份」寫進了報告；R26 改成四個根目錄＋`-name "$(basename $f)"`
   ——**還是檔名**，而 `~/.claude/file-history/` 裡三份逐位元組相同的明文副本檔名是雜湊＋`@vN`，那條掃描結構上看不到
   （R27，security；已清）；R27 改成 size 篩＋`cmp -s`，但只鍵**目前**檔案的 size——而這個檔在 git 裡有七個版本
   （查法：`git log --format=%h -- $f | while read h; do git cat-file -s $h:$f; done | sort -u`），**七版的非註解內容完全相同**
   （只改過註解），舊版副本與現版同樣致命，那條掃描對它們永遠回「零份」（R28，security）。查法：對每個受限檔、對它
   在 git 裡**每一個可達版本**的 size 各篩一次候選、`cmp -s` 該版本的 blob 定案。**ref 集合要與檔頭檢查同一套**
   （`git log --all --full-history`，不是 `git log`；R30 regression：只在側支／stash／remote 可達的版本對檔頭檢查算
   「曾經是查詢」，對 size 鍵卻看不見），**blob 不要落地**（走 pipe，否則掃描本身就在製造它要抓的副本——R30 security
   本輪每個掃描時刻都觀測到其他 reviewer 的 blob 目錄，N 個並發就有 ~8N 份明文），例如：
   `for h in $(git log --all --full-history --format=%h -- "$f"); do sz=$(git cat-file -s "$h:$f"); find <根目錄…> -type f
   -size "${sz}c" 2>/dev/null | while read -r c; do git cat-file -p "$h:$f" | cmp -s "$c" - && echo COPY "$c"; done; done`
   （非要落地就加 `trap 'rm -rf "$T"' EXIT`——R30 的第一次掃描跑超過 550 秒被 `timeout` 殺掉，只有 trap 救得回來）。
   根目錄至少含 `~/.claude`（含 `file-history`、`jobs`）、`/private/tmp`、`/private/var/folders`——**`$TMPDIR` 在它底下，
   不要兩個都列（每筆會報兩次），也不要只列 `$TMPDIR`**（R30 自檢：R30 verify-fix 一度為了去重砍掉大的那個，`/private/var/folders`
   底下有 39 個 per-user 的 `T/`，只掃自己那一個）；`/tmp` 是 symlink，`find` 不跟隨，列了等於沒列；`~/.claude/jobs` 是 150 GB 且含 FIFO／
   socket（`grep -r` 會卡住），要用 `find -type f` 餵 `xargs` 並加 size 界。第二把鍵是**檔頭的一句註解短語**（註解可以上命令列）：`grep -rlF "<檔頭第一行的一段>" <根目錄…>
   --exclude='*.jsonl'`——它找得到 size 鍵找不到的東西（被改過的副本、只抄了檔頭的檔），命中再各自判有沒有查詢
   （只數不印）。**短語要指名到逐字**——用 `requiredHeaderPhrases` 的任一個常數（例如「不得在 Claude Code session 內顯示」）
   或整行 `headerTerminator`，不要寫「檔頭第一行的一段」：R30 security 用「基準查詢集（#63）」掃本 project 目錄下 2,482 個
   spill 檔回 **0**、換成那個常數回 37；R30 自檢用「第一行前 14 個字元」掃全部 project 的 10,158 個 spill 檔回 25——**鍵與母體
   任一沒指名，兩個照做的人就得到不同答案**。這把鍵找到的是**談這個檔的文字**（diff、測試、報告）也找到副本，兩者都要逐檔判。
   **有限根目錄證不出「零副本」，有限時間也證不出**——掃描是對一棵會動的樹的一個時間點陳述（R29 security：
   第一輪掃描回零份，十分鐘後定向重掃才抓到一棵掃描期間才建立的 reviewer worktree），報告要寫掃描時間，並在最後一個
   讀者收工後補掃一次；只證得出「這幾棵樹在那個時刻零份」——報告要寫後者。**verify 的 worktree 指示本身會製造副本**
   （`git worktree add` 依建構把兩個查詢檔 checkout 到 repo 之外，R3／R16／R29 三次同形）。要建 worktree 就**三步**，
   **且不得在主 checkout 執行**（R30 regression：`sparse-checkout set` 是對「既有的 worktree」操作，照 R29 那句在主
   checkout 跑會把兩個查詢檔從**使用者的工作樹**移除，無警告）：

   ```bash
   W=$(mktemp -d)
   git worktree add --no-checkout "$W" HEAD
   git -C "$W" sparse-checkout set --no-cone '/*' '!scripts/baseline-queries.txt' '!scripts/rrf-tie-queries.txt'
   git -C "$W" checkout -q HEAD
   { grep '^#' scripts/baseline-queries.txt; printf 'ZQXJ-%d\n' 1 2 3 4 5 6 7 8; } > "$W/scripts/baseline-queries.txt"
   trap 'git worktree remove --force "$W" 2>/dev/null; rm -rf "$W"' EXIT   # 收尾綁在 EXIT——父 repo 先被刪時第一個命令跑不了、第二個仍會跑（R31 DA 找到一棵這樣的孤兒）
   git -C "$W" config --worktree sparse.expectFilesOutsideOfPatterns true   # 沒有這行，下一行在 sparse worktree 裡是 rc 0 的靜默 no-op；`--worktree` 讓它不寫進共用 .git/config（R31 regression）
   git -C "$W" update-index --skip-worktree scripts/baseline-queries.txt
   git -C "$W" ls-files -v scripts/baseline-queries.txt | grep -q '^S ' || echo 'FAIL: S 位元沒設上'
   # S 位元只擋「從索引還原」——這棵樹裡一律不對 `.`／`scripts/` 做 checkout／restore，跨 rev 尤其不行（見下）
   # …變異、測試…
   ```

   **寫替身之後那個檔就不再是 sparse 的**（`ls-files -v` 從 `S` 變 `H`、`git status` 顯示 ` M`），此時 worktree 裡任何
   `git checkout -- .`／`git checkout .`／`git restore .`／`git checkout HEAD -- .` 都會把**真檔 blob 實體化到 repo 之外**
   ——而拋棄式 worktree 裡沒有未 commit 的工作，`git checkout .` 正是最自然的還原動作（R30 DA；R3／R16／R29 同形第四次）。
   **`update-index --skip-worktree` 在 `core.sparseCheckout=true` 的樹裡是 rc 0 的靜默 no-op**（R30 自檢逐字跑配方量到：
   `ls-files -v` 仍是 `H`、`checkout .` 之後真檔 blob 實體化；加 `sparse.expectFilesOutsideOfPatterns true` 之後 S 位元才設得上，
   四個還原命令全部保住替身——我在拋棄式 repo 重跑過一次，同）。**但 S 位元只擋「從索引還原」**（R31 DA 逐字跑配方、八個自然
   動作各用一棵新 worktree：`checkout .`／`checkout HEAD -- .`／`restore .`／`checkout HEAD -- scripts/`／`restore scripts/`／
   `reset --hard`／`stash`／切 commit 都保住替身；**`checkout <別的 rev> -- .`、`checkout <別的 rev> -- scripts/`、
   `restore --source=<別的 rev> .`／`scripts/` 全部把真檔 blob 實體化**，前兩個還把 S 清成 H——指定別的 rev 是「先寫索引再寫工作樹」，
   位元擋不住；而 verify 每一輪的標題都是「對 `<上一個 fix>`」，`git checkout <prev> -- .` 正是最省事的對照寫法）。所以自檢那一行
   證明的只是「S 設上了」，**不是**「可以 checkout」；真正在守的是這句禁令：**還原測試檔只准指名路徑**（`git checkout HEAD -- Tests/…`），
   不准對 `.` 或 `scripts/` 做任何 checkout／restore，任何 rev 都不准。也可以改用 CLAUDE.md 指定的 `cp` 備份就地還原（但那條有
   `bashEditDiff` 的要求，見規則 1）。另：`sparse-checkout disable` 會讓從未 checkout 的 `rrf-tie-queries.txt` 實體化。
   附帶：`git sparse-checkout set` 會把 `extensions.worktreeConfig = true` 寫進**共用的** `.git/config`，teardown 不清（本 repo
   今天就帶著它）；`config sparse.expectFilesOutsideOfPatterns` 不加 `--worktree` 也會（R31 regression），所以配方帶 `--worktree`。命中的 checkout **不要靜默
   排除，要另列**：reviewer 的私有 worktree 就是「remote 指向本 repo 的 checkout」，R26 的排除子句把它要抓的那一類整個
   排掉（R27，security）；今天（2026-09-20）已知且接受的一份是 marketplace 的 clone（`~/.claude/plugins/marketplaces/claude-code-ltm/`）
   持有的 `rrf-tie-queries.txt`——那個 clone 停在 `7aab485`，**還沒有** `baseline-queries.txt`（R28，requirements；clone 更新後
   它會出現，屆時也是接受的一份），其餘一律回報。
2. **量測輸出只印編號。** 第一行的查詢集指紋加每列的 `#N <ms>ms <verdict>`；命中內容、snippet、
   查詢文字一律不印。紀錄要把指紋那一行一起抄進去。要看命中內容，在 Claude Code **之外**的 shell
   跑（那個 shell 的逐字稿不在語料裡）。
3. **每次量測前重驗，`self` 要分辨成因。** 選定當下乾淨不代表永遠乾淨——跑一次 `measure-baseline.sh`。
   `self` 的條目先在 Claude Code **之外**讀它的命中，判準只有一條：**含查詢原文的那段文字，是不是因為
   量測／本專案的工作才存在？** 是——任何工具 metadata chunk（Bash `command=`、`Grep pattern=`、
   `ltm_query query=`、`description=`…，即上表會進索引的那些欄位）、量測命令、被貼進或引述的那句——
   都是儀器自己的殘影，該條**退役**（補進退役清單、換一條、查詢集指紋隨之改變）。**預設是退役**；
   唯一的例外是語料裡本來就逐字含這串字的實質 turn（例如退役查詢裡的「資格考」那則使用者 turn）——
   那是正常召回，該條照用、在紀錄裡註明。「語料不可變、殘影永遠不會走」對兩邊都成立，所以它不是
   判準；判準是那段文字的來歷。`empty`／`error` 的條目那一輪不可比。第一版只寫「標記那一輪不可比」
   （R2）；第二版用三個例子當判準、把例外當預設（R3）——兩次都是列舉代替性質。

### 它擋不住什麼（誠實寫下；這一節必然不完整——它列的是想到的，不是全部）

- **規則在某個條目長度以下不可達成**——這一條決定的不是「有沒有漏洞」，是「這條規則對哪一半的受保護內容
  根本立不起來」。判準：一個條目只要短到會出現在**一般中文技術散文**裡，就沒有任何規則守得住它——人寫字時
  不會、也不該先查它是不是某個查詢。量法（只印計數、不印內容）：逐條非註解行，數它逐字出現在工作樹各檔與
  通過的測試輸出裡的次數。R26 量的結果：**基準查詢集（`baseline-queries.txt`）在整棵工作樹零命中**（R27 另量了真正
  要緊的那一面——被索引欄位 `~/.claude/projects/**/*.jsonl` 照 `indexableText` 的規則——也是零命中）——#63 真正
  要建的那組儀器立得起來。**但「零命中」是逐字比對的結果，它的邊際很薄**：8 條裡有 4 條與工作樹裡現成的字串
  只差兩個字元（R28 量；各條的最小編輯距離 [2,2,2,2,3,4,4,5]。R27 security 量到 3 條、對應的近似字串在被索引語料裡各出現
  54／31／3 次。查法：逐條對工作樹每個檔、每個 jsonl 的可索引字串取 Levenshtein 距離最小的子字串，只印距離與次數）；
  judge 的 `self` 判定是整條的子字串包含，這類近似殘影它**看不見**、一律判 `clean`（同規則 3 那段寫的「clean 不是乾淨的
  證明」——這句結論不例外，R27，security）；而 sister set（`rrf-tie-queries.txt`）**約一半**的條目逐字出現在工作樹裡
  （R28 量：以 tracked 檔為母體、排除兩個查詢檔自己，50/104；R26 的 57/104 含未追蹤檔——母體要寫明，R27 這裡寫「超過一半」
  沒寫母體），其中一批來自本 repo 自己的中文註解與 commit 文字，最短的條目只有兩個字元。規則 3 的 `self` 分診也救
  不了它：judge 的判定是子字串包含，所以那些命中每一個都會判成 `self`，而規則 3 的預設處置（退役）會退掉約一半的集合。
  收進同一套紀律時（#68），要先決定 sister set 是換一組足夠長的條目、還是明寫它不受規則 1 保護。這個曝露面有一個
  **每一輪 verify 都會發生一次**的具體入口：交給 reviewer Read 的 diff 檔本身——兩個查詢檔靠 `-diff` 沒進 diff，但
  sister set 的條目經由 README／CHANGELOG／測試註解的中文散文帶進去（R27 量：23/104 逐字在 `diff-r27.patch` 裡；
  baseline 0/8），reviewer 的一次 Read 就讓它們進 `text` block。它與前面列的三個入口同級。

- 人手在 session 裡貼了查詢原文，或 Claude 自己引述了、`git blame` 了——規則靠人守，沒有機制擋
  （`-diff` 屬性只擋 diff 生成這一條路，見上）。同類是腳本防禦邊界之外的那一整類——邊界句的權威在 `scripts/measure-baseline.sh`
  檔頭（「防禦邊界」那一段），這裡**只給指標**（「只有一份」這句 R19 在 CHANGELOG 證偽過：負向 pin 抓複述不抓改寫）：R14 寫成總括判準、R15 寫成封閉六項、R16 縮成只點名一個機制的一元全稱，三版都在
  第一個未列的成員上為假（R17）；R17 改了檔頭卻留下這裡與 CHANGELOG 的舊句（R18）——同步測試現在釘住被退回的拼法不得再出現。
- 語料裡本來就有恰好逐字含該字串的**實質** turn（例如退役查詢裡的「資格考」有一則真的使用者 turn）——
  那不是污染，是正常召回；`self` 會把它標成 self，分不出來，讀結果時要在 session 之外看命中。
  反過來，空白與大小寫以外的改寫（全形／半形、標點、換序）`self` 看不到。
- 查詢原文在執行期在 `python3` 與 `ltm` 的 argv 上（CLI 的查詢就是位置參數），同一帳號的行程 `ps -ww`
  看得到（容器 PID namespace、Linux `hidepid` 下更窄），存活時間是那一列的 wall clock——這是作業系統的
  可見面，不是本腳本的輸出通道；密鑰不在任何 argv 上（R14 版把它寫成 `env` 的 argv、execve 稽核會永久記下，R15 改走繼承的
  fd 3；但它在 re-exec 的 bash、judge 與 ltm 的**環境**裡整個 run，同帳號 `ps -E` 看得到——那正是密鑰該待的地方）；列在這裡是
  因為上一節的第一句是全稱。對照：呼叫端 shell 的環境經繼承進來的那一面，新行程拿到的只有 argv 上明示轉發的 PATH／HOME／哨兵與白名單經 fd 3 到達的名字（見檔頭），其餘 re-exec 之後全掉（R20：R19 版寫「除白名單之外全掉」，PATH 就是第一個未列的成員）——**哪些算「意外」、哪些落在邊界外，
  只由檔頭那一段判定**，這裡不再分列（R18：R17 版在這裡把「已 export 的變數與函式」整個列成擋得住，而 `export -f builtin` 純靠繼承
  就讓前四行全失效、re-exec 不發生、rc 0 且 set 行正常——它在檔頭是邊界外的第一個反例）。白名單的內容由同步測試釘到 `Sources/` 裡
  `environment["…"]` 讀取點的每一個名字（拼法，另有一條斷言擋別的讀法；R14 版漏了 ltm 自己的 `LTM_DERIVED_ROOT` 這類，指向
  受控索引的量測會靜默量到真索引，R15）；白名單經 fd 3 到達要有頭尾標記，否則 70（R16：R15 版沒到就靜默量真索引）。哨兵
  `LTM_MB_CLEAN=$$` 擋的是殘留不是偽造（任何知道子行程 PID 的父行程都對得上，R16）。R10–R13 對這一族是逐名字關（`set +a`、
  `unset`、`builtin read`、readonly 只查一個名字），每輪再冒同名的下一個——R14 換成性質。
  **可比性**：`a1ec5ac`（R14）起 ltm 是在白名單環境下被量的（R14 那一版連 `TMPDIR` 都丟掉，SQLite 暫存因此換檔案系統；
  R15 起 `TMPDIR` 與 ltm 讀的名字都會到）；在那之前是呼叫端的完整環境。要跨這條線比較 `<ms>`，先把這件事寫進紀錄。
- 查詢檔本身是一般 tracked blob、**明文在 GitHub 伺服器上**；`-diff` 只擋 diff 生成，規則 1 又禁止 review agent
  讀內容。`-diff` 只擋會讀 attribute 的 diff 生成（上方那份例外清單裡的命令都繞得過）。有紀錄可查的曝露：R1 verify
  的 patch 產生於 `.gitattributes` 之前、含明文、在該輪被讀進 agent 逐字稿（規則 1）；R2 之後各輪 verify 的 patch 都印
  `Binary files … differ`（查法：對該輪的 patch 檔 `grep -c 'Binary files'`）。其餘 diff 生成路徑沒有機制擋、也沒有
  紀錄可查；`rrf-tie-queries.txt` 同樣 tracked 且 `-diff`。自動內容約束是 9 項（R23 統一——R22 版這裡與測試各寫一個互斥的「唯一」；R24 版寫「6 項」並把數釘在
  `QueryFileReport` 的欄位數上，R25 指出那是**儲存屬性數**不是約束數；R26 加一條、R27 換掉它、R28 再加一條）。**權威與查法**：
  測試裡的 `contentConstraints` 這份具名清單——每一項標明它經哪個出口回報（`QueryFileReport` 的一個欄位，或 `checkQueryFile`
  的 `throw`）；每個欄位型出口要在**兩條**測試裡各有一句斷言、角色不同：真檔測試的那句是 **smoke**（證明真檔今天過關，
  依建構不會紅），fixture 測試的那句是 **driven**（以合成輸入驅動、能紅的那一條）；`throw` 型只有 driven（R27——R26 版
  指名的是真檔測試，神經化一條約束只有 fixture 測試紅而 pin 全綠）。同步檢查的條數與各自買到什麼只寫在測試裡，這裡不
  複述（R28：R27 版這裡寫「三條」＋ R26 的「自己指名」機制，而那個機制與那個數都在同一個 commit 被換掉）。它自己寫明
  買不到什麼——那份清單每一條都帶「誰在哪一輪構造了什麼」，沒有構造紀錄的不寫；它**依建構不完整**（R27 版宣稱
  「每一條都量過」，R28 三家核出四條只有一條是；R28 DA 另構造了三種新的穿透）。實作與失敗史見 `checkQueryFile` 與 `contentConstraints`——
  **這裡不複述項目內容**（R26：R23 版寫「封閉的四條」、R24 版「6 項」、R25 版又把七項逐一列在這裡，於是同一份列舉
  一直有第二、第三份會漂移的複本；R25 改寫時還靜默掉了 R24 對「封閉的四條」那次錯誤列舉的更正紀錄，而
  `common-spec-prose-enumeration.md` 要求把失敗史寫進文件本身，理由正是防止後人把它總括回去）。
  三件仍然寫在這裡、因為它們是**這個檔的性質**而不是列舉：條數**只有下限、沒有上限**（R22；R24 改寫時掉了這句，
  R25 補回，R26 再保留一次），**註解行沒有長度上限、整份檔案沒有 bytes 上限、條目數沒有上限**——腳本會把整份檔案
  讀進一個變數再餵給多個 process substitution，每條查詢各起一次 python 與一次 `ltm`，所以那三個「沒有上限」的後果是
  記憶體與子行程數無界（R26，codex；此檔只由作者撰寫、不接受外部輸入，所以記錄而不修）。「不得重複」與「退役比對」
  共用一個正規化（空白摺疊成單一空白＋小寫，R24——R23 版只比逐位元相等），它**不與 judge 的 `norm()` 同形**，兩個
  方向都有：fold 本身較窄（`lowercased()` ≠ `casefold()`：ß／ς／相容分解字元，**fail-open**，測試裡以 `withKnownIssue`
  標成已知缺口），比對本身較寬（Swift String 的正則等價，NFC/NFD 判相等而 judge 判不等，fail-closed）——查法與後果在
  測試的 `foldLikeJudge` 說明裡（R25 寫進來、R26 改寫時掉了、R27 補回——同一段第三次掉前輪的句子）。它們擋不住整段
  文字（切成多條短行都過，codex R22；「或放進 `#` 註解都過」R26 以為第八條約束堵住了而刪掉、R27 實測仍為真而補回、
  **R28 起為假**——`headerFormerQueries` 擋住曾經是查詢的字串，R29 regression／DA 指出這一句與 `checkQueryFile` 的註解在 R28
  都沒跟著改；今天檔頭區塊仍不受約束的是**沒進過歷史也不在退役清單**的文字），更分不出一句第三方逐字短句與自行撰寫的
  短語；作者自審是這個檔的防線。
- 查詢原文**跨過**或落在 metadata 欄位 200 字元截斷之後的那種命令。完全落在之後：那段文字不在索引裡，
  `self` 看不到、它也不會靠那段文字排名。**跨過邊界**：查詢的前綴進了索引、會靠它排名，`self` 卻判
  `clean`——進索引的字元數 ＝ 上限（200 字元）− 查詢在該欄位裡的起始位置（`toolUseMetadata` 攤平換行後取
  前 200 字元），起始位置在「上限 − 查詢長度」到上限之間都是這個帶。#63 的 root cause 那種
  `for q in …` 一行多條查詢的命令，後面的查詢正好容易落在這個帶。
- #6 若把 tool payload 收進索引——現在 jsonl 裡至少 8 筆完整副本（規則 1 的計數與查法）**回溯**進索引，
  查詢集整份換掉，而且換的那一組要從第一天就只在 Claude Code 之外編輯。
- **同目錄另一組儀器沒有這套紀律**（兩支腳本、兩組查詢，不要混）：
  `scripts/measure-rrf-ties.swift` 讀 `scripts/rrf-tie-queries.txt`（104 條），失敗路徑會印出失敗的
  查詢字串；`scripts/rrf-tie-mechanism.sh` **不讀那個檔**——查詢走 argv、第 20 行寫死八條自己的預設
  查詢、輸出表第一欄就是查詢。兩者支撐 `2026-08-22-rrf-tie-rate.md`，量的是**聚合**平手率而不是
  「前 1 名是誰」，所以污染的傷害形狀不同——但 `measure-rrf-ties.swift` 在 session 裡跑到失敗就把
  失敗的那幾條印進 tool_result，`rrf-tie-mechanism.sh` 的八條則是**打開那支腳本看**就進 `text` block
  （R2 verify 期間就有 agent 為了核對這一段而讀了它）。第三個入口是**那份紀錄本身**：`2026-08-22-rrf-tie-rate.md`
  開頭就以相對連結指向這兩個檔、結尾附一條可直接複製、把 104 條餵給那支探針的命令——照這裡的指示去讀那份紀錄的 agent，
  一次 Read 就進語料（R13）。所以：**不要在 session 裡跑、顯示、或引述它們，也不要點那份紀錄裡的連結**
  （`rrf-tie-queries.txt` 已一併設 `-diff`）；把它們收進同一套紀律是獨立工作，追蹤於 #68。
- **目前的 8 條尚未在真實索引上驗過前 5 名**（條數由同步測試對照真檔；檔頭第 1 條寫明了原因與補驗方式）。在那之前，
  「乾淨」是宣稱不是量測。

### 退役清單（已污染，不得再用）

六條，全部來自同一次量測的命令列（`docs/measurements/2026-09-01-scan-parallelism.md` 的方法段，
before 用前三條、after 用全部六條）：

「tokenizer 討論」「flock inode 鎖」「資格考」「band 相關度」「memory strategy」「並行雜湊」

- **只有那一份紀錄寫下了它們**。查法（六條都已退役、已在語料裡，放上命令列不增加傷害）：
  `git grep -l -e 'tokenizer 討論' -e 'flock inode 鎖' -e '資格考' -e 'band 相關度' -e 'memory strategy' -e '並行雜湊' -- . ':!scripts/'`
  → 那份紀錄、本檔、測試檔，加上兩個 `openspec/` 檔——後者命中的是 "memory strategy" 這種通用詞組
  的散文用法，不是查詢（正是上一節「實質 turn」那一類）。
- 更早的紀錄（`2026-08-08-baseline.md`、`2026-08-27-query-latency-decomposition.md` 等）**是否**用了
  同幾條查詢，紀錄裡沒寫（後者寫的是 `ltm query <字串>`）；它們不受這次污染影響的理由是**時間**
  ——都在 2026-09-01T04:32:12Z 之前量的——而不是「沒把字串寫進紀錄」。寫進紀錄與否跟會不會污染
  無關；污染來自命令列。
- 後三條的污染時間點沒有紀錄可指（該紀錄只寫了 `"${QUERIES[@]}"`，陣列賦值那一行不在紀錄裡）；
  它們是**依同一機制推定**退役，不是實測到第一名被佔——這個不確定性寫在這裡，不預設它們乾淨。
- 那份紀錄的耗時欄位仍可讀；命中品質從 2026-09-01T04:32:12Z（污染 turn 的時間）起不可比。
  同日的 `2026-09-01-noop-build-attribution.md`：SQL 表不涉文字查詢，但它的 A/B 表 `query ×3` 欄與「1 秒以內」
  結論是端對端 `ltm query`、查詢字串未記、是否已污染無從判斷——註記在該檔檔頭（R10 之前這裡寫「不需要註記」，為假）。

### 與其他 issue 的關係

- #62（self-hit 的檢索層排除）：會讓工具殘影的第一名掉下去，但不會讓已污染的查詢恢復成乾淨基準——
  它的前後量測是本查詢集的第一個消費者。**新腳本的列不要與 2026-09-01 之前的表對齊**：
  語料範圍（`--all-projects`）、binary（`~/bin/ltm`）、輸出格式都不同。
- #6（tool payload 是否索引）：上表「今天不會」的兩列都繫在它身上。
- #33（評估集）：真正的解是 `(查詢, 應命中的 turn)`；本查詢集只是把儀器擦乾淨，說不出代表性。
