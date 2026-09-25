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
  ——**執行沒有機制保證**：綠不區分 passed 與 skipped／cancelled（`.disabled`、`Test.cancel()`、同 target 鄰檔的 `exit(0)` 都讓
  run 綠，#63 R34），見測試檔「買不到什麼」第 4 條。這一條的版本史（哪一輪、哪個 lens 抓到什麼）不在這裡複述——查 issue #63
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
   **編輯查詢檔在 Claude Code 之外的編輯器做**——**且沒有任何讀過這個檔的 session 還會再跑**（在線、之後被 resume、或之後還會 compaction——
   R40 requirements：這句原寫「沒有在線的 session 讀過這個檔」，R39 只在下面改了措辭）：Claude Code 對它讀過的檔（以絕對路徑為鍵、
   記在那個 session 的 read-state 裡）的任何改動——外部編輯器、Bash、背景行程都算——會在**那個** session 的下一次 model call 落一筆
   `attachment.type = "edited_text_file"`。**帶不帶內容看檔案被讀的當下有多大**（R37 security 量、DA 從 2.1.281 的程式碼確認；R38 logic
   在 2.1.282 的程式碼再確認是 `Buffer.byteLength ≤ 4096`——以 **bytes** 計、含等號。R38 security 用 CJK 檔量過：以 bytes 計，不是字元；
   真檔 4,402 B 只有 2,436 個字元，以字元計的話今天就會帶內容）：
   ≤ 4096 bytes 時 `snippet` 帶改動**前後各 8 行**（R36 security 用拋棄式 headless session 量：48 行檔改第 1 行 → 1–9、改第 38 行 → 30–46；
   `bashEditDiff` 只有 ±3。單檔 snippet 上限 8192 個字元、每一輪累計 16384 個字元之後其餘清空——這兩個常數是 R37 DA 讀程式碼得到的，
   R38 更正了 R37 版把它們標成 R36 security），> 4096 bytes 時 snippet 是空字串、只記檔名。今天的查詢檔是
   4402 bytes（查法：`git cat-file -s HEAD:scripts/baseline-queries.txt`，只印大小），所以**今天這條管道不帶內容**——但檔頭只要少
   306 bytes 就會安靜地回到 ±8，所以下面的設防照 ±8 寫。語料對得上：查詢檔的 `edited_text_file` 恰好 2 筆、都在檔案 ≤ 3,996 B 時，
   超過 4096 B（d427dd9）之後 0 筆（R37 security；R36 版把 ±8 寫成無條件）——這只證明之後沒有東西觸發，不證明門檻本身；
   門檻的證據是程式碼（R38 logic）。
   **哪些讀會打開這條管道**（R37 security：合成檔、headless session、2.1.281；量到的行為，不是規格。R39 更正標題：原寫「哪些讀會把
   檔案放進 read-state」，但 `head`／`tail`／`sed -n` **會**進 read-state，只是帶範圍、不產生 attachment——R39 logic／DA 讀程式碼）：**會**——`cat`、不帶管線
   或重導的 `grep '^#' <f>`（含絕對路徑、含 `-n`——R38 security 量到 `grep -n '^#'` 也會，R37 版寫「單純的」涵蓋得比實際少）、Read 之後 Edit；**不會**——Read（完整或帶 offset／limit 都不會；Read 預設帶 offset，DA 從程式碼確認）、
   `grep '^#' <f> | cat`、`grep -c`／`-q`／`-vc`、`grep … | wc -l`、`head`、`sed -n`、`awk`、`wc -l`、`python3 open()`（代表同步測試在
   `swift test` 裡讀檔）、`git diff`、`git show HEAD:… | wc -l`、Grep 工具；語料 1,885 筆 `edited_text_file`（R37 當時的數；會漲，
   R38 security 2026-09-25 重數是 1,939）裡沒有一筆的前置接觸只有 Read。R38 security 在 2.1.282 把「不會」這 16 種逐一重跑、0 筆；
   另外量到也**不會**的：`grep '^#' <f> 2>/dev/null`、`> /dev/null`、`{ grep '^#' <f>; printf …; } > out`（worktree 配方的替身行）、
   `cp`、`cmp -s`（就地配方自己的讀）、`tail`、`cat <f> | wc -l`、`wc -c < <f>`、`grep -rlF`。R39 security 在 2.1.282 再量到：**會**——
   `true && cat <f>`、`cat <f>; cat <f>`、`cd <session cwd> && grep '^#' <f>`（只有這個目標，見下）、`LC_ALL=C grep '^#' <f>`、`egrep`、`grep -F`／`-h`／`-E`、`cat -n`、`nl`、
   `rg`；**不會**——`grep '^#' <f>; echo done`、`grep … && wc -l <f>`、`grep '^#' a b`、`sed -n '/re/p'`、`cat <f> 2>&1`、`grep … || true`、
   `grep -m1`、`rg -c`、`F='…'; grep '^#' "$F"`、`git hash-object`。R40 security 再量到**不會**：`cd <別的目錄> && grep '^#' <f>`
   （相對與絕對路徑各一，0/2）、`timeout 5 grep …`、`cat <f> > /dev/null`、`head -n 50`。**2.1.282 的登記規則**（R38 logic、R39 logic／security／DA 讀程式碼，
   與上面的量測一致；讀程式碼得到的、綁在這一版，不是規格）：命令字串含 `|`、`<`、`>` 就不登記；環境變數前綴不算一段；`cd` **只有一種形狀**會被剝掉——恰好是
   `cd <session cwd> && ` 的前綴（不加引號、不含特殊字元的絕對路徑；在執行與登記之前就剝掉，逐字稿裡也看不到），其他 `cd` 都是一段，整條命令
   因此不登記；`cat`（只准 `-n`／`--number`）、`nl`（不准旗標）、`bat`／`batcat`（`-n`／`-p`／`--number`／`--plain`）、`head`、`tail`、`sed -n` 的行號
   範圍可以與 `echo`／`printf`／`true` 的段並列（正則寫的是 `(echo|printf|true|:)\b`，但 `:` 後面沒有字母時 `\b` 不成立，所以 `:` 實際上不行）；`grep`／`egrep`／
   `fgrep`／`rg` **只在整條命令只有一段時**才算，而且旗標要在白名單（`-[niwxEFGPHh]+`、`-A`／`-B`／`-C N`、部分長選項；`rg` 有自己的一組 `-[iSswxFnNHUP]+`）、
   恰好一個 pattern 與一個檔、路徑不含 `*?[{`、命令以 0 結束（其他讀取命令非零結束時整個 call 算出錯，也不登記）；`head`／`tail`／`sed -n` 登記成帶範圍的項目、不產生 attachment；已經在 read-state 的項目
   不會被之後的讀覆寫；被中斷或轉背景的 call 不登記。（R39 五個 lens：R38 版把這段寫成「其餘每一段都要是已知的讀取命令…單獨成命令的
   grep 家族」，照字面會推出 `grep -c`／`-q` 會登記、`cat <f>; echo x` 不會，與量測相反。DA 讀程式碼推 `cd … && grep` 不登記，security
   量到會，以量測為準——R40 logic／security／DA 更正：兩個都對，差在 `cd` 的目標；`:` 與 `cd` 兩句也是 R40 改的。）
   **第三條管道：compaction**（R40 DA 讀 2.1.282 的程式碼並用合成檔量過）：full compaction 先把 read-state 整份快照、清空，再依
   timestamp 取最新的 5 個檔，對每個檔**不帶 offset／limit** 走 Read，把**整份**內容寫成 `{type:"file", content}` attachment（單檔約
   5,000 tokens 上限）——**不看**這個項目當初帶不帶範圍，而那次 Read 又會重新登記這個檔，所以之後每次 compaction 都可能再寫一次。DA 量到：
   帶 offset／limit 的 Read、或 Bash `head -3` 之後 `/compact`，都出現含**全部**行的 `file` attachment。**語料裡已經發生過一次**：
   `3a2ceb7e…` 在 2026-09-07T00:25:35Z 的 auto compaction 之後，有一筆查詢檔的 `file` attachment（19 行註解＋8 行查詢；那份 jsonl 本來就在
   內容鍵的 5 筆預期命中裡，所以命中數沒變）。所以上面「不會」清單裡的 Read、`head`、`tail`、`sed -n`（任何帶範圍的讀）只是不發
   `edited_text_file`，**仍然登記進 read-state**，compaction 時會被整份重讀——**要避開兩條管道，只能用不登記的讀法**（命令含 `|`、`<`、`>`，
   例如 `grep '^#' <f> | cat`；或 `git`、`python3 open()` 這類不是讀取命令的形式）。R37–R39 只量了「讀檔之後改檔」會帶出什麼，沒有人量過
   compaction。
   所以**規則 1 原本寫的檔頭讀法 `grep '^#'` 就會打開這條管道**，改成 `grep '^#' <f> | cat` 就不會（依賴 harness 怎麼解析命令；
   規則 1 下面那句現在寫的是後者——R38 四個 lens：R37 只改了這一段，規則句沒跟著改）；允許的
   計數類讀法今天量到的都不會（R37 requirements：R36 版寫「規則 1 唯一允許的 `grep '^#'`」，與規則 1 自己「與統計非註解行」矛盾）。
   R36 security 最先量到的是：`grep '^#' A` 之後、下一個 call 對 A `sed -i` → 寫下 attachment；只 `sed -i`、`wc -l` 之後 `sed -i`、
   `grep` 之後接一個 call 內的 `cp; sed; cp` 往返 → 都沒有——也就是這條建議原本帶著一個沒寫出來的前提（沒人讀過），而規則 1
   自己允許的讀法就會打破它；當時其他讀法沒量，R37 補齊上面那份清單。
   前提寫「在線，**或之後被 resume 或 compact**」：照字面「沒有任何 session 讀過」在這個 repo 已不可能滿足（37 輪的 reviewer 都 grep 過）。
   **resume 會重建 read-state，但只從 Read／Write／Edit**（R39 security 讀 2.1.282 的程式碼並量過：重建 read-state 的那個函式在 resume
   與 print 模式啟動時從逐字稿播種，每個檔只取最近的一次工具呼叫）：Bash 讀不重建（R38、R39 security 各一個資料點，0 筆）；Read 重建但帶
   offset、不產生 attachment（R39 requirements 一個資料點，0 筆）；Edit 在 resume 當下讀磁碟，今天 4,402 B、只記檔名；**Write 用逐字稿裡的
   舊 `content`**——≤ 4096 B 就保留內容、diff 從 Write 起整段累積、時間戳舊所以 resume 後第一次 model call 就發（不必再有改動），**4096 門檻
   與 ±8 距離兩道防線都擋不住**（R39 security 用合成檔量到 8 條替身全在 snippet 裡；再 resume 一次會再寫一次）。今天的語料：Read／Write／
   Edit 過查詢檔的 session 有 3 個，唯一有 Write 的 `3a2ceb7e…` 最後一次碰是 Edit，所以只記檔名——**今天沒有實際外洩**，但它是一個
   resume 了就重新在線的讀者，**而且 resume 之後的 compaction 可能把今天那份全檔寫回**（它若排在 read-state 最新的 5 個檔之內；R40 DA，見上「第三條管道」）——不要 resume 它（R39 security 報 MEDIUM，DA 以今天的語料更正為 LOW。R38 版寫「resume 之後沒有重建 read-state」，只對 Bash 讀成立；R37 版寫「沒量」）。**task 1b 的寫回**：它改的是檔頭**第 1 條**（第 5–12 行，會過時的句子在第 7–10 行——R39 requirements 更正「7–9」）與第 24 行（R39 #13
   加的），離終止符（第 43 行）分別 ≥ 31 行與 19 行，在下面的 ≥ 8 行界之外——這對 `edited_text_file` 成立（前提：沒有 Write 播種的 resume
   讀者，今天沒有）；**對 compaction 不成立**：外部編輯之後，任何 read-state 裡有這個檔的 session 會重讀它、把它排到最新，下一次 compaction
   就把整份新檔寫回，距離不相干。所以 task 1b 的前提是**沒有任何 read-state 含這個檔的 session 之後會再 compact 或被 resume**（R40 DA；
   R39 版寫「即使有在線讀者、即使檔案縮到 4096 以下也一樣」，R38–R39 只算了 ±8，也沒提第 24 行——R40 requirements）（R38
   regression／requirements／security：R37 版寫「檔頭第 1 行、約 40 行」，第 1 行是標題）。R35 以前這裡寫的前提是「Claude Code 沒在跑、或那個 session 不在這個 project」；R36 把整句說成「不對」說過頭
   （R37 regression）——它量到的是觸發條件在 read-state，這讓「不在這個 project」變得不相干（一個在別的 project、以絕對路徑讀過這個檔
   的 session 算不算，沒量）；「沒在跑」那一半與上面的「在線」同義。那時的實例（R31 security：全語料含 ≥1 條的 11 筆裡有一筆是它，
   1,752 個字元長、2/8 條，2026-09-07T04:52:11Z）是一次外部編輯，兩種寫法都解釋得了。在 session 裡用 Write／Edit 工具是**今天**索引安全
   的（`content`／`old_string`／`new_string` 不在那七個欄位裡），但它不守本規則劃的 jsonl 邊界：
   Write 的 `content`、Edit 的 `toolUseResult.originalFile`（**整份檔案**，不是改到的那幾行），每一次都把完整查詢集存進 jsonl 一份；
   讀過之後的 `attachment` 紀錄帶多少見上方（≤ 4096 B 時前後各 8 行、否則只有檔名；Read 會進 read-state（帶 offset），平時不發 `edited_text_file`，但 compaction
   會把它整份重讀——R40 regression／requirements：R38 版寫「Read 本身不進 read-state」。R38 regression：這一句
   原寫「Read／Edit 之後的 `attachment` 紀錄，每一次都把完整查詢集」，R37 改上方時沒跟著改）——而**印**與**讀**也會：一個 Bash
   命令把整份檔案印進 stdout 是一筆 `toolUseResult.stdout`，一次 `Read` 是一筆 `toolUseResult.file.content`。
   **Bash 對 project root 底下檔案的編輯也會落一筆**：Claude Code 把那次 Bash call 對 project root 底下檔案造成的變更記成
   unified diff 進 `toolUseResult.bashEditDiff`。量到的觸發條件（R30 自檢、R31 security、R32 verify-fix 各重量一次，**每個數字都標單位**——
   R30 版把本 project 的 hunk 數放在「全語料」開頭的句子裡，R31 抓到；R31 verify-fix 版又把**紀錄**數放進以 **file entry**
   為單位的句子裡，R32 三家抓到）。單位有三層：**紀錄**（一筆 `toolUseResult.bashEditDiff`）⊇ **file entry**（`files[]` 的一個
   元素）⊇ **hunk**。2026-09-22T11:16+08:00 的快照：
   帶 `bashEditDiff` 的**紀錄** 1,986（主 session 1,504／subagent 482，`isSidechain` 欄位；subagent 逐字稿在
   `<session>/subagents/**`，走訪要遞迴——只掃頂層 `*.jsonl` 會數到 0 筆 subagent）。**「都會產生」只對鍵成立，對 hunk 不成立**：
   564 筆的 `files[]` 是**空的**（subagent 436／主 session 128——subagent 的 482 筆裡只有 46 筆帶 file entry）；**其中** 34 筆帶
   `unavailable` 旗標（Claude Code 算不出 diff 的情況——R33 DA 量到帶旗標的**全部**落在空 `files[]` 這一桶，不是「另有」）。
   `files[]` 最多 5 個元素，285 筆帶 `moreFiles > 0`——這 285 筆裡也有 `files[]` 是空的（R33 重數 2026-09-23T04:54：292 筆裡 35 筆），
   所以 `moreFiles` 不等於「帶滿 5 個 entry」。
   **file entry** 2,847 筆**全部**在 project root 底下（2,754 在該筆 `cwd` 底下、93 不在 `cwd` 底下但在 jsonl 目錄名解回的
   project root 底下——目錄名把非字母數字都編成 `-`，比對時要把路徑同樣編碼）、`/tmp`／`$TMPDIR`／`/private/var/folders` 0 筆。
   **hunk** 5,321 個，context **最多 3 行**（unified diff 預設）：前置 {0: 708, 1: 20, 2: 171, 3: 4,422}、**後置**
   {0: 942, 1: 58, 2: 56, 3: 4,265}（檔首、新檔、EOF 的 hunk 少於 3），本 project 565/565 前置都是 3。
   語料會長，重跑只會變大，**宣稱的是形狀**（全在 root 底下、tmp 0、兩種 session 都有、≤3 且 <3 存在、有空 `files[]`）。終止符那個威脅靠的是**後置** context（終止符是檔頭最後一行、第 1 條在後），所以「編輯點離
   終止符 ≥ 3 行」這個上界成立、「都是 3 行」不成立。查法（只印計數）：遞迴走訪 `~/.claude/projects/**/*.jsonl`，取 `toolUseResult.bashEditDiff.files[].hunks[].lines[]`，
   數每個 hunk 前置／後置以空白開頭的連續行數；file entry 的路徑對該筆 `cwd` 與 jsonl 目錄名解回的 project root 比前綴（目錄名把非字母數字都編成 `-`，比對時要把路徑同樣編碼）。所以「只改註解行」不保證不帶查詢（R30，security＋DA）。**一次 call 內改完又還原
   → 零筆**——與「記錄的是這個 call 進入與離開時的差」一致，而且同一個 session 裡有**反面對照**（R33 重量；**截止點**是 jsonl 的 `timestamp` ≤ `2026-09-22T20:53:30Z`（字串比較，即 04:53:30+08:00——之後這個 session 還在長，
   不帶截止點重跑只會變大；R34 requirements 就是因為截止點與下面的 root 內規則都沒寫而重打不出 159／39），
   實作者的主 session `~/.claude/projects/-Users-che-Developer-claude-code-ltm/61707b35-201e-4d2b-9cd2-0a578445d3f1.jsonl`）：
   - **往返**＝一次 Bash call 的命令裡 `cp X Y` 與其後的 `cp Y X` 都在（regex 逐字：`\bcp\s+(?:-\w+\s+)*("?[^\s";&|]+"?)\s+("?[^\s";&|]+"?)`，
     兩組捕獲互換都出現）。**R32 版的 regex 讓路徑吃進 `;`**（`cp $F $B;` 捕到 `$B;`），於是對不上而漏掉兩個——R33 修正後 20 個。
     再依「第一個 `cp` **之前**有沒有就地寫入」分兩群：**純往返 17 個、17 個都沒有紀錄**；**備份前先有一個真的修改**的 3 個裡
     2 個各落一個 hunk（+4/−0、+3/−2，正是備份之前那次修改的大小——離開時檔案確實不同於進入時），1 個沒有紀錄。
     「正是那次修改」的查法（只用計數）：兩個 hunk 的 `+` 行都是**下一個** commit 那份檔案的子集、與**上一個** commit 那份不交
     （R34 security 照此驗過成立）；另一種：變動行以子字串出現在命令裡第一個 `cp` **之前**的條數 vs 變異段裡的條數（R34 DA：7 條裡 5／0）。
   - **正向對照**＝命令含就地寫入（regex 逐字：`open\([^)]*['"]w['"]|sed -i |\btee\b|>>? *"?(?:Tests|docs|Sources|scripts)/`）
     而不是往返。再依命令文字分兩群，**root 內**＝配得上 `(?:^|[\s"'(=])(?:Tests|docs|Sources|scripts)/|CLAUDE\.md|/Developer/claude-code-ltm/`
     （regex 逐字；R33 版沒寫出這條，R34 用三種自然讀法最接近的是 169／40）：**root 內** 159 個——117 個帶非空 `files[]`、0 個只有鍵、42 個沒有紀錄；
     **其餘** 39 個（4／2／33）——寫在 root 之外的檔依建構永遠不會被記（上面量到 file entry 全在 root 底下），
     所以它們不該進基準率（R33 security 指出 R32 版把這一群混進去、低估了「有改就記」）。
   - 判定一律是「`toolUseResult.bashEditDiff.files[]` **非空**」——`files[]` 空與沒有這個鍵同算「沒記」（R33 logic：R32 版的
     基準率用「沒有紀錄」桶、判定卻用「非空」，兩桶不一致）。查法：在該 jsonl 裡由 assistant 的 `tool_use.id` 對回 user 的
     `tool_result.tool_use_id`，兩條 regex 如上，只印計數。
   **怎麼讀**：root 內的就地編輯扣掉結構上本來就記不了的 3 個（1 個出錯、1 個逾時轉背景、1 個明確 `run_in_background`——見下方
   (a)(c)）之後，117/156（75%）留下紀錄，所以在「記不記與有沒有改無關」的虛無假設下，17 個純往返全部沒記的機率約
   (39/156)^17 ≈ 5.8×10⁻¹¹（R36 requirements／regression／security：R35 版只扣 2 個、寫 117/157，這裡還寫著 117/159 與
   (42/159)^17 ≈ 2×10⁻¹⁰——後者實為 1.5×10⁻¹⁰）；而那 2 個「備份前先改」的往返**正好**記下了先前那次修改——這是同一個機制的正反兩面，比
   R31／R32 的單邊計數強。**仍然只是一致**：正向對照是用命令文字挑的（那 42 個「root 內卻沒記」其餘 39 個沒有逐一查原因——可能是
   沒改到任何東西的替換、或改了又改回），往返規則只涵蓋 `cp`，而且**不驗還原真的跑了**（`cp F B && 改 && swift test && cp B F`
   在測試如預期變紅時 `&&` 鏈中斷、永不還原；今天 20 個全是無條件還原的寫法，但規則本身不要求）。
   **call 出錯或被轉到背景時，「同一個 call 內還原」擋不住 diff**（R34 security／DA；R33 版這裡寫「`&&` 中斷時 0 筆會是反證」，是假的）。
   量到的三件事（只印計數；遞迴走訪 `~/.claude/projects/**/*.jsonl`，由 Bash 的 `tool_use.id` 對回 `tool_result`）。**分母只算會寫
   `bashEditDiff` 的版本**——2.1.269 以前沒有任何一筆 Bash 結果帶這個鍵，算進去會把證據說大（R37 DA；R36 版寫的全語料 5,688／435／2,451
   含了那些版本，說大 3.5／3.1／5 倍）。(a) 的 1,628、(c) 的 140／494 與下面的分母都截至 `timestamp` ≤ 2026-09-23T17:13:17Z、版本 ≥ 2.1.269
   （量於 2026-09-24T22:26+08:00；與往返那段的截止點不同）：成功的
   前景 call 49,769 筆裡 3,364 筆帶鍵（6.8%），所以在「帶不帶鍵與出錯／轉背景無關」的虛無假設下，下面三類的期望約是 110／9.5／33，實際
   都是 0。以下的 harness 行為都是在 2.1.269–2.1.281 量的，不是規格；Claude Code 升版之後要重量。
   (a) **出錯（`is_error`）的 Bash call 不帶 `bashEditDiff`**——1,628 筆、帶這個鍵的 0 筆；出錯的 `toolUseResult` 一律是字串。實作者主
   session 截至往返那段的截止點（`2026-09-22T20:53:30Z`）是 8 筆、0 筆帶鍵（R34 版寫「9 個」而沒寫時間點，照往返那段的截止點重跑是 8——R35 四家）。實例：R33 fix
   的一個變異 call 出錯，測試檔留在變異狀態而沒有紀錄；之後的還原 call 記下 +1/−1 的 hunk 連同 context（R34 INFO 確認）——對測試檔無害，
   **對查詢檔就是一筆受限內容**。**「出錯」不等於「非零結束」**（R36 DA）：Claude Code 對某些指令的 exit 1 加 `returnCodeInterpretation`、
   不算出錯——全語料 951 筆（2026-09-24T01:13+08:00）、`is_error` 全 false、其中 26 筆帶非空 `bashEditDiff`（`grep -q` 未命中、`diff -q` 兩檔
   不同屬這一類；`cmp -s` 不同、`exit 1` 算出錯）。
   (b) **記的是這個 call 視窗內 project root 底下的變化，不論是誰改的**——不是「下一個碰／改回那個檔的 call」（R34 版這裡寫「碰」、
   CLAUDE.md 寫「改回」，兩種都不對）。查法：對往返那段截止點前每筆非空 `bashEditDiff`，看 `files[].filePath` 的 basename 有沒有出現在該 call 的
   命令文字裡——125 筆裡「沒有任何一個出現」2 筆、「至少一個沒出現」3 筆。3 筆裡的 2026-09-22T08:31:18Z 是一支 Python patch 腳本改測試檔
   自己（路徑在 .py 裡）；**另 2 筆是外來寫者**：2026-09-21T19:55:25Z（命令只改 job tmp 檔，記下測試檔 +1/−1）與 19:57:53Z（兩個 file
   entry——README.md 在命令裡、測試檔不在，測試檔記下 +2/−2；命令是一段只寫 `.md` 的 inline python；19:55:25Z 那筆最早由 R35 DA
   找到，R36 更正過一次）。兩筆都落在 19:41:11Z 的變異 call
   逾時轉背景（結果在 19:51:16Z 回來）、19:52:09Z 又有一個明確背景的變異 run 之後，所以無法歸給其中哪一個；19:51:29Z–19:54:04Z 的七個
   前景 call 與 19:52:09Z 那個背景 call 都**沒有**這個鍵（不是空 diff；R38 requirements：R37 版寫「八個前景」，其中一個是明確背景）。（R37 requirements：R36 版只解讀了「沒有任何一個出現」那 2 筆、寫「1 筆」；R36 requirements／
   security／regression：R35 版寫「144 筆裡 2 筆」而沒寫時間點與讀法，而且查法分不出外來寫者。）
   (c) **轉背景不殺行程；已知至少五條路會把 call 轉到背景**（R35 DA、R36 security、R37 DA）：harness 逾時、明確的 `run_in_background`
   ——這兩條語料裡有（同上的版本與截止點：帶 `timedOutAfterMs` 140 筆、明確背景 494 筆，帶鍵都是 0）；使用者中斷（預設是轉背景而不是
   殺掉）、使用者手動轉背景、主 agent 執行中有訊息進來——這三條只有原始碼層級的證據（R37 DA 讀 2.1.281 binary 的字串；語料裡沒觀測到），
   而且**這份列舉不封閉**。探針：`trap …; sleep 20` 配 3 秒 timeout，轉背景、跑完、trap 照樣執行。風險都一樣：剩下的變異／測試／還原在背景
   跑、被記到之後某個不相干的前景 call 上。真正殺掉的路徑對 process group 與列舉到的子孫送 TERM、1.5 秒後 SIGKILL（同上，原始碼層級）。
   **所以**，變異一律這樣寫：
   `F='<file 的絕對路徑>'; B=$(mktemp) && cp "$F" "$B" || exit 1; trap "cp '$B' '$F' && rm -f '$B' || echo 'restore or cleanup failed; backup at $B' >&2" EXIT && trap 'exit 130' INT && trap 'exit 143' TERM && trap 'exit 141' PIPE || exit 1`
   → 改 → `cmp -s "$B" "$F"; [ $? -eq 1 ] || { echo 'FAIL: 變異沒生效或 cmp 出錯'; exit 1; }` → 跑（`timeout -s INT -k 10 N /usr/bin/swift test`）
   ——還原與刪備份由 EXIT trap 做。前提與逐項理由：
   - **一個 shell 只有一個 EXIT trap**：`trap … EXIT` 是取代，不是疊加（R38 logic／requirements／security）。所以**一個 call 只用一次這一行**：
     同一個 call 裡用第二次，第二次備份時檔案還是第一次的變異，call 結束時被「還原」成變異 1，原檔只剩在第一次的備份裡——`cmp` 抓不到
     （logic 在 zsh 5.9.1 量）；在下方 worktree 配方的 call 裡直接用，它會取代那裡的清除 trap，檔案有還原、樹卻留下來（requirements／security
     在 zsh 與 bash 重現：`git worktree list` 多一筆）——**worktree 裡不要用這一行**（下一條）。要迴圈，每一輪包進 subshell `( … )`；要同時保護
     **兩個檔**，用巢狀 `( 配方 f1; 改 f1; cmp f1; ( 配方 f2; 改 f2; cmp f2; 測試 ) )`——每個檔在自己的配方之後改、之後 `cmp`（R40 requirements：
     R39 版寫成 `( 配方 f1; ( 配方 f2; 變異; 測試 ) )`，兩個變異都在配方 f2 之後，`cmp` 只驗 f2）；平鋪用兩次會讓第一個檔安靜地停在變異，
     變異後的 `cmp` 只比第二個檔（R39 DA）。
     子 shell 的 EXIT trap 在子 shell 結束時觸發、不動外層的（R38 logic 驗過迴圈每輪都還原、不留備份；實作者自己驗過子 shell 與外層的 EXIT
     trap 在 zsh 與 bash 各觸發一次）。**用 subshell 時（迴圈與巢狀都算），call 開頭要先放 `trap 'exit 130' INT; trap 'exit 143' TERM`，
     而且要放在跑迴圈的那一個 shell**——bash 在 `( … )` 裡會重設已設的 trap，把整個迴圈再包一層 `( … )`，bash 5.3 與 3.2 收到 INT 會跑完所有輪
     （R40 logic）：配方的訊號 trap 裝在子 shell 裡，外層
     shell 沒有——沒有外層 trap 時，bash 收到 INT 迴圈會繼續跑下一輪，zsh 與 bash 收到 TERM 外層在 0 秒就死、檔案還在變異、子 shell 約 2 秒後
     才以孤兒身分還原，已不在這個 call 裡；加了之後三種 shell（zsh 5.9.1、bash 5.3、bash 3.2）都會停，而且等子 shell 還原完才離開（R39 logic
     量；R38 版寫「被訊號中斷時外層迴圈會不會繼續，沒量」）。逾時預算算的是**整個 call**：迴圈 K 輪要 K×（N＋10＋餘裕）低於工具逾時，超過就拆成
     多個 call、每個 call 一輪（R39 DA：超過的 call 會被轉到背景，也就是 (c) 的風險）。**不要把配方的子 shell、群組或迴圈接進會提早結束的讀者**（`| head -N`、
     `| grep -m1`）：只 pipe 測試命令本身。這一行加了 `trap 'exit 141' PIPE` 就是為了這個——見下面 zsh 訊號那條。
   - **只保證單一寫者**（R37 DA：兩個 reviewer 同時變異同一個檔——A 備份原檔、B 在 A 還原前備份到 A 的變異——最後檔案停在 A 的變異；
     `mktemp` 在那種情形沒作用，固定路徑也一樣。最容易留下的正好是 0 條紅的變異，而那種沒人會發現）。verify 本來就是多個 reviewer 同時跑，
     所以**reviewer 一律在自己的 worktree 裡變異**（下方「要建 worktree 就**三步**」那段的配方），不在共用樹就地變異；**worktree 裡不用這一行**：
     那棵樹用完即丟，變異之間用 `git checkout HEAD -- <指名路徑>` 還原；照抄 `F='…'` 在那裡只寫得出**共用樹**的路徑（`$W` 是同一個 call 裡才
     產生的，單引號也不展開），結果變異打在共用樹上、worktree 的測試看不到變異——「0 條紅 → 無臂」的假結論，加上並發的單一寫者問題（R39 DA
     在拋棄式 repo 量到；requirements 量到照抄成 `F='$W/…'` 會 fail-closed）。共用樹只給實作者一個人用。
     確認回到原樣要對**變異前**的身分比，不是對 HEAD：變異前印一次 `git hash-object "$F"`（只印雜湊），**EXIT trap 跑完之後**再印一次、兩者
     相同——也就是下一個 call，或包住配方的 `( … )` 關閉之後；同一個 call 的最後印的是**變異後**的雜湊，必定不同（R39 logic／requirements／
     security／DA 各自量；R38 版寫「跑完再印一次」，沒寫要在還原之後）。第二次要寫出**字面路徑**：`F` 是配方那一行在子 shell 或那個 call 裡設的，
     那兩個位置都已經沒有它，照抄 `"$F"` 會變成 `git hash-object ""`、rc 128；而「下一個 call」只在上一個 call 是在前景跑完時成立——被轉到
     背景的 call，trap 還沒跑（R40 logic／requirements）
     （R38 四個 lens：R37 版寫「對 HEAD 的 blob `cmp`」——未 commit 的檔還原正確也一定不等於 HEAD，而對 mismatch 最自然的補救
     `git checkout` 正是本節開頭禁的；R37 #1 的建議原文就這樣寫，修法照抄）。`git hash-object` 不在登記規則裡，不會打開 attachment 管道。
   - **沒有其他讀過這個檔的 session 在線、之後也不會被 resume**：attachment 管道看的是每一個讀過它的 session（上方「編輯查詢檔」那段），不只執行還原的那一個
     （R37 requirements／logic，由觸發條件推得、沒跨 session 量過；今天的查詢檔 > 4096 B，那筆只帶檔名）。
   - 全部在**同一個前景** Bash call 裡、**不要 `run_in_background`**（它字面上滿足「同一個 call」，而 Bash 工具自己的說明會把長的 `swift test`
     導過去——R36 security）；**不要把這一行包進 zsh 函式**（EXIT trap 會在函式返回時就觸發，還原發生在變異之前——R37 logic）。
   - `F` 用**加引號**的絕對路徑（`F='…'`：不加引號時空白會切字、`$x` 在 `cp` 之前就展開——R38 logic）、trap 用雙引號在**設的當下**綁定
     兩個路徑、`&&` 讓**還原成功才刪備份**，還原失敗時印出備份路徑（R38 logic：R37 版什麼都不印，隨機檔名從沒出現過）（R37 logic／regression：R36 版
     `trap 'cp "$B" <file>; rm -f "$B"'` 用 `;` 串——相對路徑之後 `cd`、路徑含空白或 `$`、`$B` 被重用、目的檔唯讀，都讓還原失敗而備份照刪；
     R35 版的固定路徑只還原不刪，在這些情形反而留著）。四個 trap 用 `&&` 串、失敗就 `exit 1`（R37 DA：寫錯引號時 trap 沒裝上、變異照樣
     執行）——擋得到的是**回非零**的 `trap`（訊號名寫錯、zsh 解析不了的動作）；**擋不到**的是 zsh 對**單一參數**的 `trap` 回 0 卻什麼都
     沒裝：把收尾的雙引號放到 `EXIT` 後面就是這個形狀，鏈照走、變異執行、沒有還原（R38 logic 在 zsh 5.9.1 量；bash 會拒絕，rc 2）。zsh 的 `$(trap)` 與管線
     會 fork、列不出外層的 trap（bash 3.2 與 5.3 的 `$(trap)` 都列得出來——R40 regression／requirements：R39 版拿掉了「zsh 的」）；重導到檔案的 `trap > f` 在當前 shell 執行、列得出，單參數寫錯之後則什麼都不寫——所以正向檢查做得到
     （R39 logic／requirements／DA；R38 版由前半推出「沒有便宜的正向檢查」，推論錯了），但在 zsh 它要一個還得清掉的暫存檔，沒有加進這一行：
     **照抄這一行，不要手打**（R37 版寫「沒裝上就不變異」，只對 bash 成立）。
     路徑不得含單引號：直接貼上的話整條命令在解析時就失敗、什麼都沒跑、不留備份；跳脫過的 `'` 在 zsh 安裝 trap 時被拒（鏈 exit 1、沒有
     變異、備份留著），在 bash 則 trap 裝得上、變異照跑、還原時只印語法錯誤、不印備份路徑（R39 logic／security／requirements；R40 logic 更正 R39 版的
     「什麼都不印」）。**會留下整份備份
     的情形**（對查詢檔就是 repo 外的受限內容，只有內容鍵掃得到——R38 logic；**這份列舉不封閉**——R37 版只列 `cp` 失敗那一種，R38 版補成四種並寫成完整清單，R39 又找到三種）：
     EXIT trap 因訊號名寫錯而裝不上（`|| exit 1` 在 trap 存在之前就離開）；跳脫過的 `'`；上面那個 zsh 單參數 trap；trap 裡的還原 `cp` 失敗
     （刻意保留，會印出路徑）；還原成功但刪備份失敗（也會印那句訊息，所以訊息寫「還原或刪備份失敗」——R39 logic：R38 版寫「restore
     failed」，這種情形是假訊息）；同一個 call 裡不包 subshell 用第二次（第一次的備份，路徑從不印出）；kill 路徑（SIGKILL，連變異都留下，
     見下）；R40 之前的寫法在 zsh 下接進提早結束的讀者（SIGPIPE，**連原檔都丟**，見下）。收到那句訊息之後怎麼還原，看下面「還原方式的紀錄量不同」那段。`cp` 失敗時留下的是空檔——trap 不能放在 `cp` 之前（那會把
     空備份蓋回原檔）。
   - 變異後的 `cmp`：確認變異真的改了檔（R37 logic：`sed -i ''` 沒命中也回 0，no-op 變異讀起來就是「0 條紅 → 無臂」）。只有「不同」（rc 1）
     才算生效，相同（0）與出錯（2，例如變異把 `F` 刪掉或改名）都停（R38 logic：R37 版的 `! cmp -s … ||` 在 rc 2 時判成生效）。**紅要是某一條
     具名測試失敗**，不是非零 rc：逾時 124、kill-after 137、找不到 `timeout` 127 都會讓 call 非零結束（R37 DA；這台的 `timeout` 是
     Homebrew 的 GNU coreutils 9.11，不是 macOS 自帶）。
   - 備份路徑用 `mktemp`（R36 security：固定的 `/tmp/x.good` 讓並發、目標**不同**的 reviewer 互相還原對方的檔）、trap 裡刪備份（「用完
     立刻刪」；R35 版的配方只還原不刪）。
   - 在 Claude Code 的 zsh（`/opt/homebrew/bin/zsh -c`，5.9.1）下 `trap '<還原>' EXIT` 遇 SIGINT、SIGTERM、**SIGPIPE** 都**不執行**，要轉成 exit
     才會。SIGPIPE 是 R40 找到的（logic；DA 更正歸屬：只有 zsh，bash 3.2／5.3 有 EXIT trap 時會接住它、照樣還原）：把配方的子 shell 或
     迴圈接進 `| head` 這類提早結束的讀者，裡面的 builtin 再寫就以 141 結束、EXIT trap 不跑——單一子 shell 時檔案停在變異、備份留著；迴圈
     形式時第二輪把第一輪的變異當成原檔備份，**原檔就丟了**。加了 `trap 'exit 141' PIPE`，三種 shell 都還原、不留備份（R40 logic 量；實作者
     在 zsh 5.9.1、bash 3.2、bash 5.3 重現：沒有它時 zsh 停在變異，有它時還原）。（R35 security：送給 shell 或整個 process group 都一樣；bash 會執行；R34 版寫「不一定跑（SIGKILL 一定不跑）」說輕了。R36 logic 量過：
     INT、TERM、正常結束、`exit 3` 下 EXIT trap 都恰好執行一次；trap 會等前景 job 結束才跑）。
   - `timeout -s INT -k 10 N`（R36 logic：預設的 SIGTERM 碰不到 SwiftPM 放在自己 process group 的 `swiftpm-testing-helper`，rc 124 之後它
     變成孤兒繼續跑；SIGINT 讓 SwiftPM 自己收掉它）。**牆鐘上限是 N＋10**（kill-after），所以**整個 call 的 N＋10＋備份還原的餘裕要低於 Bash 工具的
     逾時**（迴圈就乘上輪數，見上）——外層才拿得到 rc、trap 照樣執行、call 不被轉到背景（R37 DA；R36 版寫「N 低於工具逾時」）。**兩個外部訊號的殘留**（R37 logic
     量過）：TERM 送到 `timeout` 本身時它轉送的是 TERM 不是 INT——helper 又成孤兒；`timeout` 會 setpgid，送給 shell process group 的 TERM
     碰不到它，shell 的 TERM trap 要等內層 N 到期才跑（N=25 時 group TERM 在第 2 秒送出、trap 在那之後 23 秒——約第 25 秒——才跑；INT 同樣
     被延後——R38 logic）。遇上 (c) 那條真正殺掉的路徑（TERM 之後 1.5 秒 SIGKILL），前景 job 沒在 1.5 秒內結束的話，trap 還沒還原就被殺
     ——就是下面「SIGKILL 下 trap 仍不執行」的一個具體情形（R38 logic：兩段原本沒接起來）。
   - `set -e` 在這個 harness 裡**無效**（使用者命令是 `eval '…' && pwd -P` 的左邊，R36 logic），所以用 `|| exit 1`；還原不要接在 `&&`
     後面（測試如預期變紅時 `&&` 鏈中斷、永不還原）。**SIGKILL 下 trap 仍不執行**——對查詢檔的那一個 call 裡不要放可能逾時或被中斷的東西。
   **還原方式的紀錄量不同**（R35 security；R34 版寫「一旦發生就沒有不留紀錄的還原路徑」，是假的——出錯的還原 call 依 (a) 就不留）。
   **以下排序只對沒有讀過這個檔的 session 成立**（R36 security：讀過的 session 裡，**回來時檔案仍在變異狀態**的 call 會在下一次 model call、
   任何還原之前寫下 attachment，之後的 Bash 還原再多一筆。R37 security：同一個前景 call 內由 trap 還原成功的變異，即使以 `exit 1` 結束也不留
   ——R36 版寫「出錯或轉背景的變異 call」說寬了）：
   沒有**在線**的 session 讀過這個檔、也沒有 Bash call 在跑時，由使用者在外部還原 → 零 Claude Code 紀錄（Spotlight 對它有內容索引，與 repo
   本身一樣——R36 security）；session 內用 Bash `cp` → 一個 hunk（變動行連同前後 ≤3 行 context）；`git checkout -- <file>`／`git restore <file>`
   的紀錄量與 `cp` 相同，**但變異測試不用它們**——它們還原到 HEAD，不是你手上那一份（CLAUDE.md「工作流程」開頭那條——那條唯一的例外是拋棄式 worktree 裡的**測試檔**；未 commit 的修法、task 1b
   待寫回的檔頭都會被安靜丟掉——R37 regression）；`git stash` 之後再 `drop` 會在 `.git/objects` 留一個含變異內容的懸空 blob，壓縮、不在掃描根、
   gc 前都在（R36 DA）；**不要用 Write／Edit**——Write 的 tool_use 帶整份 `content`、toolUseResult 帶 `content`／`originalFile`／`structuredPatch`，
   Edit 帶 `originalFile`，都落在 jsonl（依上面「什麼會進索引」不進索引，但在磁碟上），**而且會在 `~/.claude/file-history/<session>/`
   留改動前的快照**（每個檔多版，R36 security：v1 413 個、v2 2,927 個…v8 103 個；headless `-p` session 不寫）——變異過的查詢檔
   不等於任何 commit 過的 blob，下面的 size＋`cmp` 掃描結構上找不到它（見掃描那段）。17 個純往返裡 `is_error` 為 0、也沒有轉背景，
   所以不影響 17/17。
   要真的隔離，得在 project root 內建合成檔、同一 call 內改回去並對照不改回去的版本。這件事在 R30／R31 都寫「推論、未證」：兩處探針
   都在 project root 之外，settle 不了；R31 security 在 project root 建了合成檔驗，而那是在 **Workflow-harness 的 subagent
   session** 裡——那種逐字稿**不寫結構化的 `toolUseResult`**，所以驗不了（R32 security／regression 更正 R31 verify-fix 寫的
   「根本不寫 `toolUseResult`」那句全稱：它**會**寫，只是只在 `is_error` 的結果上、而且值是**字串**，沒有 `bashEditDiff` 這個
   欄位——4,087 個 workflow 逐字稿（在 `<session>/subagents/workflows/**`）345,035 筆裡 2,015 筆有，全是字串、0 筆是 dict；本輪五個 agent 逐字稿 11/11 個 `is_error`
   結果有、0/221 個 OK 結果有。那些字串是失敗命令的 stdout／stderr 副本，所以**錯誤路徑不是隱私豁免**）。
   「主 session 與 subagent 都會產生」沒區分這第三種 session。
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
   除非編輯點離終止符 ≥ 3 行——**在讀過這個檔的 session 裡、且檔案被讀時 ≤ 4096 bytes，是 ≥ 8 行**（±8 的 attachment：今天的真檔終止符在第
   43 行、第 1 條查詢在第 44 行，改第 35 行的 snippet 是 27–43、第 36 行起就含第 44 行；R36 security 寫 9，以行號核是 8——R37 logic 同意；
   今天的檔是 4402 bytes，所以今天這個界沒有作用，但檔頭少 306 bytes 就會有）。**推論**：變異測試的「`cp` 備份 → 改 → 跑 → 還原」若分成多次 Bash call，每一次
   call 結束時檔案是 modified 狀態、就會落一個帶查詢的 hunk——所以**備份、改、跑、還原必須在同一個前景 Bash call 內完成**，寫法照
   上方「所以，變異一律這樣寫」那一行與它的前提（一個 call 一次、單一寫者、絕對路徑、還原成功才刪、變異後 `cmp`、訊號轉 exit、
   `timeout -s INT -k 10`、不用 `run_in_background`）。
   CLAUDE.md 同步寫了這條（R35 regression：R34 版只把 trap 寫在後面的括號裡，照這一行做的人寫不出它；R36 logic／security／regression：R35 版的 CLAUDE.md
   副本寫成五個箭頭卻說「四步」、固定備份路徑、不刪備份）。R28／R29 的真檔盲測沒留下這種紀錄，與「都在單一 call 內完成」一致；R31 verify-fix 在主 session 直接量到 0 筆（見上、n = 3）。）
   要把 diff 交給 review agent，**給檔案路徑讓它自己 Read**，不要把 diff 內嵌進 prompt——agent 的
   prompt 是它逐字稿裡的 `text` block；而且 diff 要在設了 `-diff` 的 commit 之後產生（R1 verify 的
   `diff.patch` 產生於 `.gitattributes` 存在之前，查詢檔在裡面是明文）。唯獨查詢檔——**以及它的任何副本或備份**
   （變異測試 `cp` 出來的 `.good`、job tmp 裡的中間檔、reviewer 的私有 worktree；判準是內容不是路徑）——review
   agent 只准讀檔頭（`grep '^#' <f> | cat`——不加管線的 `grep '^#'` 會把檔案登記進 read-state，見上方「編輯查詢檔」那段；R38 四個 lens：
   R37 只改了那一段，這句沒跟著改）與統計非註解行（條數、長度、重複），不准讀內容；含查詢的備份還原後立刻刪。
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
   （查法：對每條 fold 後的查詢，在 fold 後的檔頭連接文字裡找最長已存在的前綴／子串，只印長度差）。檔頭會長，這個邊際不是常數。取不到歷史時真檔測試**具名紅在環境那一側**、其餘八條照跑——**兩個例外**：(1) 把那段 do／catch 收成
   `try?`，這句會安靜地變假；(2) 線上的 blobless／promisor clone 裡 `git show` 會自己去抓物件、可能卡在憑證提示，症狀是測試**掛住**
   而不是具名紅（見 `historicalQueryFolds` 的射程）。另一種接線錯誤——抽成區域變數卻沒傳給 `checkQueryFile`——不讓這句變假（do／catch
   還在），它破壞的是上面「檔頭不得含曾經是查詢的字串」：`headerFormerQueries` 恆空（使用者決定這兩種接線錯誤寫進清單、不加鍵；見測試檔
   「買不到什麼」第 4 條。R38 regression／requirements：R37 版把後者也歸給這句、又漏了 lazy fetch）
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
   **這段是 bash 寫法，在 zsh 下要改**（本機的 Bash 工具跑在 zsh）：把版本的 size 收成一趟 `find`（八趟掃 150 GB 太慢）時，
   `-size` 條件要放進**陣列**（`SIZES=(-size 1669c -o -size 2930c …)` 再 `find … \( "${SIZES[@]}" \)`）——zsh 不對未加引號的
   `$SIZES` 做 word-split，寫成純量會靜默回 0 個候選（R32 security 第一趟就這樣，與 CLAUDE.md 記過的 `$LOCK` 同一個坑）。
   **第二個坑**（R33 security 第一趟又踩到）：把路徑寫死成 `"$h:scripts/…"` 時，zsh 把 `$h:s` 讀成歷史修飾詞 `:s/…/…/`、報
   `bad substitution`，`git cat-file` 根本沒執行、pipe 餵空給 `cmp -s`——每個候選都安靜回「不是副本」。寫成 `"${h}:scripts/…"`。
   不只 `:s`：冒號後是 zsh 修飾詞字母的都會被吃（R37 requirements 在 5.9.1 逐一量：a A c e h l P q Q r s t u；其餘字母原樣保留——
   R36 版寫「任何字母」是假的全稱；R36 DA 的探針踩到的是 `$h:q.txt` 的 `:q`，每一版都安靜回 0）——一律寫 `${h}`。
   上面那個範例能跑只因冒號後面接的是 `$f`。
   **size 鍵找不到的一類**（R35 security）：Write／Edit 在 `~/.claude/file-history/` 留的是改動**前**的快照——若那是一份變異過的
   查詢檔，它不等於任何 commit 過的 blob，size＋`cmp` 結構上找不到；沒有檔頭的變異副本（例如只取非註解行做的探針）連短語鍵也
   躲得過。這一類用**內容鍵**：鍵是 `baseline-queries.txt` 的 8 條非註解行、門檻是「含 ≥ 1 條」，範圍是上面這些根目錄全部（不只
   file-history），逐檔在行程內比對、只印計數。**只開一般檔**：`find … -type f`，或 `lstat`＋`O_NONBLOCK|O_NOFOLLOW` 開、`fstat` 確認
   `S_ISREG` 再讀——`/private/tmp` 裡就有 FIFO（R37 量到頂層 30 個、socket 86–92 個），對 FIFO `open()` 會一直等（R36 fix 的掃描在那裡卡了
   約 6 小時）。**不要加大小上限**（那會看不到大檔裡的受限內容）。`~/.claude/projects/**/*.jsonl` 的命中是預期的（語料本身的逐字稿；
   R37 security：5 筆，其中 4 筆含全部 8 條）；報告要寫沒掃到的數量（權限不足、walk／open 錯誤——R37 security 那次三個根合計：1 個 lstat 錯、
   110 個 walk 錯、8 個 open 錯）。（R36 security：R35 版沒指名鍵集——拿 104 條姊妹行當鍵，file-history 5,528 個檔有 3,880 個至少含
   1 條，因為那些是短而常見的字串，所以姊妹檔不適用這把鍵。R35 以前的衛生掃描——R32–R34——都只跑了 size 鍵；R35 那一輪跑過內容鍵，只跑 `~/.claude/file-history`：round 後 5,433 個檔、fix 後 5,472 個，都是 0 個含查詢（R38 regression：這句在 R36 被刪；
   R39 regression：原句寫「R35 fix 時…5,433」，那個數字是 round 後那次）。R36 security 把 8 條
   基準行的內容鍵跑遍 file-history、todos、shell snapshots、`projects/**` 非 jsonl、`~/.claude/jobs`（529,788 檔）、plugins、`/private/tmp`、
   `/private/var/folders`：全部 0；R37 security 在 2026-09-24 20:34–20:46 對 `~/.claude`（全部 2,431,928 個一般檔）、`/private/tmp`、`/private/var/folders` 再跑一次：
   除了上面那 5 筆 jsonl，0。）
   根目錄至少含 `~/.claude`（含 `file-history`、`jobs`）、`/private/tmp`、`/private/var/folders`——**`$TMPDIR` 在它底下，
   不要兩個都列（每筆會報兩次），也不要只列 `$TMPDIR`**（R30 自檢：R30 verify-fix 一度為了去重砍掉大的那個，`/private/var/folders`
   底下有 39 個 per-user 的 `T/`，只掃自己那一個）；`/tmp` 是 symlink，`find` 不跟隨，列了等於沒列；`~/.claude/jobs` 是 150 GB 且含 FIFO／
   socket（`grep -r` 會卡住），要用 `find -type f` 餵 `xargs`——FIFO／socket 不只在 jobs，`/private/tmp` 也有，所有根都一樣處理
   （R37 requirements／security；這裡原寫「並加 size 界」，對 size 鍵無妨、對內容鍵會看不到大檔，見上）。第二把鍵是**檔頭的一句註解短語**（註解可以上命令列）：`grep -rlF "<檔頭第一行的一段>" <根目錄…>
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
   # 整段（含變異與測試）必須在**同一個 Bash call** 裡：這個 harness 每次 call 是新 shell，EXIT trap 在 call 結束就 fire，
   # 第二個 call 進去時樹已經被刪（fail-safe，但不寫出來會被當成配方壞了——R32 regression 實測）。
   W=$(mktemp -d)
   trap 'git worktree remove --force "$W" 2>/dev/null; rm -rf "$W"' EXIT   # **第一件事**：後面任何一步失敗都還清得掉；兩個命令都要——
                                                                           # 父 repo 先被刪時 `worktree remove` 跑不了、`rm -rf` 仍會跑
                                                                           # （R31 DA 找到一棵孤兒；R32 四家指出 trap 排在四個可失敗命令之後，防不到自己前面）
   trap 'exit 130' INT; trap 'exit 143' TERM   # zsh 下 INT／TERM 不觸發 EXIT trap（R35 security），轉成 exit 才會清
   git worktree add --no-checkout "$W" HEAD \
     && git -C "$W" sparse-checkout set --no-cone '/*' '!scripts/baseline-queries.txt' '!scripts/rrf-tie-queries.txt' \
     && git -C "$W" checkout -q HEAD || { echo 'FAIL: 建樹失敗，不要往下走'; exit 1; }
   # **在寫替身之前**先確認兩個查詢檔都沒落地：`sparse-checkout set` 若失敗（舊 git 沒有 `--no-cone`、打錯、少貼一行），
   # 上一行的 `checkout` 就是完整 checkout、兩個真檔都實體化；替身只蓋掉 baseline 那一個，而 S 位元與下面的自檢**照樣通過**
   # （R32 security 在合成 repo 逐字跑過：自檢印 S set、姊妹檔還在樹裡——自檢證的是「S 設上了」，不是「真檔沒落地」，
   # 也不是「替身寫進去了」：R33 security 在 `scripts/` 只含兩個被排除檔的合成 repo 裡量到寫替身失敗而 S 照設）。
   # （上一行在 R33 少了 `#`，在 bash 區塊裡會被當命令執行——R34 requirements／security／regression；那時寫的「`set -e` 下在建樹後
   # 中止」在 Claude Code 的 harness 裡不會發生：`set -e` 在那裡無效，R36 logic。）
   [ ! -e "$W/scripts/baseline-queries.txt" ] && [ ! -e "$W/scripts/rrf-tie-queries.txt" ] || { echo 'FAIL: 真檔落地了'; exit 1; }
   { grep '^#' scripts/baseline-queries.txt; printf 'ZQXJ-%d\n' 1 2 3 4 5 6 7 8; } > "$W/scripts/baseline-queries.txt"
   [ -s "$W/scripts/baseline-queries.txt" ] || { echo 'FAIL: 替身沒寫進去'; exit 1; }   # R33 security：`scripts/` 不存在時重導失敗，S 位元照樣設得上
   # 下面三步用 `&&` 串、失敗就中止（R40 codex：R39 以前最後一步只 echo、照常往下走，是這個區塊裡唯一 fail-open 的閘）。
   # 第一步沒有的話，第二步在 sparse worktree 裡是 rc 0 的靜默 no-op；`--worktree` 讓它不寫進共用 .git/config（R31 regression）
   git -C "$W" config --worktree sparse.expectFilesOutsideOfPatterns true \
     && git -C "$W" update-index --skip-worktree scripts/baseline-queries.txt \
     && git -C "$W" ls-files -v scripts/baseline-queries.txt | grep -q '^S ' || { echo 'FAIL: S 位元沒設上'; exit 1; }
   # S 位元只擋「從索引還原」——這棵樹裡一律不對 `.`／`scripts/` 做 checkout／restore，跨 rev 尤其不行（見下）
   # …變異、測試…（同一個 call 內。這棵樹用完即丟，變異之間用 `git checkout HEAD -- <指名路徑>` 還原**測試檔**；**替身**只能重跑上面那行
   # 替身寫入來還原，兩個查詢檔不得出現在任何 checkout／restore 裡（R40 security，見下）。**不要在這裡用規則 1 的就地配方**：
   # 照抄 `F='…'` 只寫得出共用樹的路徑，變異會打在共用樹上、這棵樹的測試看不到（R39 DA）；直接用還會取代上面的清除 trap（R38 requirements／security））
   ```

   **寫替身之後那個檔就不再是 sparse 的**（`ls-files -v` 從 `S` 變 `H`、`git status` 顯示 ` M`），此時 worktree 裡任何
   `git checkout -- .`／`git checkout .`／`git restore .`／`git checkout HEAD -- .` 都會把**真檔 blob 實體化到 repo 之外**
   ——而拋棄式 worktree 裡沒有未 commit 的工作，`git checkout .` 正是最自然的還原動作（R30 DA；R3／R16／R29 同形第四次）。
   **`update-index --skip-worktree` 在 `core.sparseCheckout=true` 的樹裡是 rc 0 的靜默 no-op**（R30 自檢逐字跑配方量到：
   `ls-files -v` 仍是 `H`、`checkout .` 之後真檔 blob 實體化；加 `sparse.expectFilesOutsideOfPatterns true` 之後 S 位元才設得上，
   四個還原命令全部保住替身——我在拋棄式 repo 重跑過一次，同）。**但 S 位元只擋「從索引還原」**（R31 DA 逐字跑配方、八個自然
   動作各用一棵新 worktree：`checkout .`／`checkout HEAD -- .`／`restore .`／`checkout HEAD -- scripts/`／`restore scripts/`／
   `reset --hard`／`stash`／切 commit 都保住替身；**`checkout <別的 rev> -- .`、`checkout <別的 rev> -- scripts/`、
   `restore --source=<別的 rev> .`／`scripts/`——只要那一版的 blob 與 HEAD 不同——就把真檔 blob 實體化**（R32 requirements
   在拋棄式 repo 兩種都跑過：blob 相同時這三個命令都保住替身、S 位元也還在，本輪比較的 `a3c7233..88f29fa` 正是這種；
   但這個檔有 7 個歷史版本，對更早的 rev 危險是真的，所以禁令照樣是「任何 rev 都不准」——fail-closed），前兩個還把 S 清成 H——指定別的 rev 是「先寫索引再寫工作樹」，
   位元擋不住；而 verify 每一輪的標題都是「對 `<上一個 fix>`」，`git checkout <prev> -- .` 正是最省事的對照寫法）。所以自檢那一行
   證明的只是「S 設上了」（R40 起它失敗會中止；R39 以前只 echo），**不是**「可以 checkout」；真正在守的是這句禁令：**還原測試檔只准指名路徑**（`git checkout HEAD -- Tests/…`），
   不准對 `.` 或 `scripts/` 做任何 checkout／restore，任何 rev 都不准；**兩個查詢檔也不得被指名**在任何 checkout／restore 裡（任何 rev、
   任何旗標，含 `--ignore-skip-worktree-bits`）——對 HEAD 指名時 skip-worktree 讓它 rc 1（`pathspec … did not match`）、替身維持變異、
   `git status` 什麼都不顯示，安靜地沒還原；指名別的 rev 或加那個旗標就把真檔 blob 寫到 repo 外面（R40 security 逐一量過）。替身變異了就
   重跑替身那一行。**不要**改用規則 1 的就地配方（見上一段配方裡的註解；R37 版這裡寫
   「改用 CLAUDE.md 指定的 `cp` 備份就地還原」，照做會讓樹留下來；R38 版改成「包進 subshell」，照抄的 `F='…'` 會讓變異打在共用樹上——R39 DA）。另：`sparse-checkout disable` 會讓從未 checkout 的 `rrf-tie-queries.txt` 實體化。
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
  看得到（容器 PID namespace、Linux `hidepid` 下更窄），存活時間是那一列的 wall clock（`ltm` 掛住時沒有上界：腳本不給 `ltm` 逾時，是 R37 使用者決定保留的取捨，見腳本檔頭；
  R40 codex／requirements）——這是作業系統的
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
