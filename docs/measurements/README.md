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
  （檔頭六個必備短語）；規則本文沒有機制守（#63 verify R3 就是檔頭漏改被抓到的）。
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
  它看不到（R13）——以及 process substitution 餵指紋與迴圈、腳本前兩行就是 `builtin set +x` 與 re-exec 那一行（R14）、
  字元守衛不用任何 `[X-Y]` range。這份清單是**摘要**，會漂移；權威是查法：讀那條測試的每一個 `#expect`——不在那裡的
  複述就沒有機制守著。任一列是 `error(…)` 腳本最後以 1 離開（每列照印；`empty` 不計入）。離開碼 0 的意義是「0 **且**
  stdout 第一行是 set 行」——`SHELLOPTS=noexec` 這類讓腳本一行都不跑的選項會給零輸出、rc 0（腳本檔頭的擋不住段，R14）。
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
  多了一筆），所以這裡不給計數只給查法：掃 `~/.claude/projects/**/*.jsonl`，統計 user／assistant 紀錄裡
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
   **編輯查詢檔在 Claude Code 之外的編輯器做**。在 session 裡用 Write／Edit 工具是**今天**索引安全
   的（`content`／`old_string`／`new_string` 不在那七個欄位裡），但它不守本規則劃的 jsonl 邊界：
   Write 的 `content`、Edit 的 `toolUseResult.originalFile`（**整份檔案**，不是改到的那幾行）、Read／
   Edit 之後的 `attachment` 紀錄，每一次都把完整查詢集存進 jsonl 一份——而**印**與**讀**也會：一個 Bash
   命令把整份檔案印進 stdout 是一筆 `toolUseResult.stdout`，一次 `Read` 是一筆 `toolUseResult.file.content`。
   判準是「這個動作會不會把整份檔案送進 jsonl」，上面是例子不是清單。#63 實作與 verify 期間就這樣存了
   **至少 8 筆**含全部查詢的紀錄（2026-09-07 R3 verify 全語料數的：Write 2、Edit 3、attachment 1、
   Bash stdout 1、Read 1；R1 verify 的 `diff.patch` 另在該輪被讀進 agent 逐字稿）。這個數字**只會
   往上走**——R2b 寫「六份」的九分鐘前，另一個 session 剛 `Read` 過一次；所以它是下界不是計數，
   要現值就跑查法。查法（只印計數、執行期讀查詢檔、不上命令列）：掃
   `~/.claude/projects/**/*.jsonl`，對每筆遞迴走訪所有字串葉節點，數「同時含全部 N 條查詢」的紀錄與其
   json 路徑。所以 **#6 一旦把 tool payload 收進索引，這一組查詢集就整份作廢**——這是已經發生的曝險，
   不是 if。第一版把 Write／Edit 與外部編輯器並列，理由是索引層的；本規則的邊界在 jsonl，兩者不等價。
   （本段與檔頭的第二版是在 session 內用 Bash 跑一支只改註解行的 python 改的——檔案內容沒有經過任何
   工具的 input 或 result，所以沒有再多一筆。）
   要把 diff 交給 review agent，**給檔案路徑讓它自己 Read**，不要把 diff 內嵌進 prompt——agent 的
   prompt 是它逐字稿裡的 `text` block；而且 diff 要在設了 `-diff` 的 commit 之後產生（R1 verify 的
   `diff.patch` 產生於 `.gitattributes` 存在之前，查詢檔在裡面是明文）。唯獨查詢檔——**以及它的任何副本或備份**
   （變異測試 `cp` 出來的 `.good`、job tmp 裡的中間檔；判準是內容不是路徑）——review agent 只准讀檔頭
   （`grep '^#'`）與統計非註解行（條數、長度、重複），不准讀內容；含查詢的備份還原後立刻刪。
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

- 人手在 session 裡貼了查詢原文，或 Claude 自己引述了、`git blame` 了——規則靠人守，沒有機制擋
  （`-diff` 屬性只擋 diff 生成這一條路，見上）。同類是腳本檔頭「擋不住的」那份**封閉列舉**（六項，各附後果，不得類推第七項；
  這裡不複述——R14 把它寫成一句總括判準、R15 抓到判準涵蓋不了自己列的第五項、還與本節下一條互相矛盾）：PS4／BASH_ENV
  的命令替換、叫 `builtin` 的函式或 alias、從自己的 shell 以 `exec` 對上哨兵、noexec／onecmd、白名單傳進去的 PATH 上的
  python3、re-exec 之前就改變且跨 exec 保留的行程狀態。
- 語料裡本來就有恰好逐字含該字串的**實質** turn（例如退役查詢裡的「資格考」有一則真的使用者 turn）——
  那不是污染，是正常召回；`self` 會把它標成 self，分不出來，讀結果時要在 session 之外看命中。
  反過來，空白與大小寫以外的改寫（全形／半形、標點、換序）`self` 看不到。
- 查詢原文在執行期在 `python3` 與 `ltm` 的 argv 上（CLI 的查詢就是位置參數），同一帳號的行程 `ps -ww`
  看得到（容器 PID namespace、Linux `hidepid` 下更窄），存活時間是那一列的 wall clock——這是作業系統的
  可見面，不是本腳本的輸出通道；密鑰不在任何 argv 上（R14 版把它寫成 `env` 的 argv、execve 稽核會永久記下，R15 改走繼承的
  fd 3）；列在這裡是因為上一節的第一句是全稱。對照：呼叫端 shell 的環境**透過繼承生效**的那一面（`SHELLOPTS`、`BASH_ENV`
  帶進來的 `set -x`／`set -a`／readonly／同名函式／DEBUG trap、`export -f`、已 export 的 `QF_CONTENT`、`PYTHONPATH`）**不在**
  擋不住之列——腳本第三行以空環境加白名單重新啟動自己，那些一次全掉；同一個名字用在 re-exec **之前**（`PS4` 作為 trace 前綴
  展開、`BASH_ENV` 定義一個叫 `builtin` 的函式）仍在上一條的列舉裡。白名單的內容由同步測試釘到 `Sources/` 讀環境變數的每一個
  名字（R14 版漏了 ltm 自己的 `LTM_DERIVED_ROOT` 這類，指向受控索引的量測會靜默量到真索引，R15）。R10–R13 對這一族
  是逐名字關（`set +a`、`unset`、`builtin read`、readonly 只查一個名字），每輪再冒同名的下一個——R14 換成性質。
  **可比性**：`a1ec5ac`（R14）起 ltm 是在白名單環境下被量的（R14 那一版連 `TMPDIR` 都丟掉，SQLite 暫存因此換檔案系統；
  R15 起 `TMPDIR` 與 ltm 讀的名字都會到）；在那之前是呼叫端的完整環境。要跨這條線比較 `<ms>`，先把這件事寫進紀錄。
- 查詢檔本身是一般 tracked blob、**明文在 GitHub 伺服器上**；`-diff` 只擋 diff 生成，規則 1 又禁止 review agent
  讀內容。`-diff` 只擋會讀 attribute 的 diff 生成（上方那份例外清單裡的命令都繞得過）。有紀錄可查的曝露：R1 verify
  的 patch 產生於 `.gitattributes` 之前、含明文、在該輪被讀進 agent 逐字稿（規則 1）；R2 之後各輪 verify 的 patch 都印
  `Binary files … differ`（查法：對該輪的 patch 檔 `grep -c 'Binary files'`）。其餘 diff 生成路徑沒有機制擋、也沒有
  紀錄可查；`rrf-tie-queries.txt` 同樣 tracked 且 `-diff`。內容約束只有測試的每條純量上限，它擋的是整段文字的量級，
  分不出一句第三方逐字短句與自行撰寫的短語；作者自審是這個檔的防線。
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
