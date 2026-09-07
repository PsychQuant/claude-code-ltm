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
  一起改它；但只有欄位名、字母表、離開碼、退役清單四項由測試同步，規則本文沒有機制守（#63 verify R3
  就是檔頭漏改被抓到的）。
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
  的 sha256 前 48 bit：不含查詢文字、不會造成 self，但能讓持有候選的人確認一次完整猜測（那個對手本來
  就讀得到 jsonl 裡的副本，結論不變）。
  `#N` 是檔內第 N 條非註解行（去掉行首行尾的 **ASCII** 空白後，空行與 `#` 開頭不算——腳本與測試
  用同一個定義，而且刻意只認 ASCII：bash 的 `[:space:]` 對全形空白隨 locale 變、Swift 的不變，
  所以兩邊都不剝它，測試另外斷言查詢檔裡沒有非 ASCII 空白）。
  密鑰用命令替換餵進環境（`LTM_ANCHOR_KEY="$(~/bin/ltm memory --export-key)" scripts/measure-baseline.sh`），
  不落地；查詢檔的解析不依賴 cwd（腳本用自己所在的目錄）。
- verdict 是**封閉字母表**：`clean tool=<n>`／`self tool=<n>`／`empty tool=0`／
  `error(<rc>|sig<N>|blank|exec|json|shape|judge)`。「封閉」由 `Tests/LTMMCPTests/BaselineQueryFileTests.swift`
  的**同步測試**執行：它把腳本檔頭的 token 列、腳本裡 `ERROR_TOKENS`、本行的 token 列、測試自己的
  `errorTokens`、腳本程式碼裡實際的 `error(...)` 輸出點五個集合逐一比對，任一處多一個少一個都紅，
  輸出點寫成它認不出的形狀也紅（程式碼裡**每一個** `error(` 都算輸出點——`valid_row` 用變數比對、
  不寫字面，所以沒有被略過的區段；行尾註解先剝掉）；同一條測試也做一個**存在性**檢查：每個 token 在
  **別的**函式裡有一條帶「產生標記」、以 `#expect(` 開頭的活斷言行寫著它的 tail（要驗的 token 從
  `errorTokens` 導出；標記在檢查函式裡執行期拼出，且**斷言**該函式的行範圍內沒有那個字面）。它擋的是
  產生點被刪掉／改名／註解掉而清單沒跟著改；**它不證明那條斷言被執行**（`.disabled`、迴圈跳過看不到）
  ——執行由整份測試檔綠保證。這一條的版本史：R3 回頭 grep 含答案的本檔永遠綠；R4 把清單移走但標記字面
  仍在函式裡；R5（兩個 lens：requirements／logic）指出前提沒被守住；R6 三方指出「實際產生」是過度宣稱。
  同一條測試還同步了：退役清單（README 與測試）、七個 metadata 欄位名（`toolMetadataFields` 常數、
  README 表、查詢檔檔頭）、離開碼（腳本檔頭與程式碼裡的 `exit N`）。**其他任何複述都沒有機制守著**。任一列是 `error(…)` 腳本最後以 1 離開（每列照印；`empty` 不計入）。
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
  的四成（#67 的診斷有數字，**那是 chunk 表的份額、不是前 k 名的出現率**——檢索不是均勻抽樣，
  兩者不相等，實際的前 k 名出現率要在真索引上跑一次才知道，而那一次還沒跑），拿它當 dirty 會讓
  多數列不可比。它是 #62（self-hit 的檢索層排除）要移動的那個量，印出來給 #62 的前後比較看
  ——**所以 #62 前後 `self`／`tool` 的變化量的是 #62 的效果加上兩次量測之間語料的成長，不是語料
  變乾淨了**（#62 自己的實作 session 就在談 self-hit 與工具 chunk，特別容易排進這些查詢的前 k 名）。
  另外，`tool=<n>` 也會數到**談論**這個標記的散文——純字串 `message.content` 不截斷、整段進索引；
  這種紀錄幾乎全是 #63 自己的 session 寫的，而且**會隨討論儀器的 session 增加**（verify 的兩輪之間就
  多了一筆），所以這裡不給計數只給查法：掃 `~/.claude/projects/**/*.jsonl`，統計 user／assistant 紀錄裡
  `message.content` 是純字串且含 `⟨tool ` 的筆數（只印計數）。
  第一版的判準是「含 `⟨tool ` 或含 `ltm query`」就 dirty；#63 verify 的 devil's-advocate 指出那量的是
  「有沒有工具 chunk」不是「這條查詢被自己污染了沒有」，於是改成把命中拿去跟查詢比對。
- `<ms>` 是 `ltm` 行程 fork→exit 的 monotonic 牆鐘（含 process 啟動、查詢前的增量併入、檢索、
  輸出；不含 judge），單一樣本、無暖身——第 1 列常帶冷啟動。

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
   Bash stdout 1、Read 1；R1 verify 的 `diff.patch` 另被一個 reviewer 讀進逐字稿）。這個數字**只會
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
   （DA R2 D2）；第二版用三個例子當判準、把例外當預設（DA R3 DA1）——兩次都是列舉代替性質。

### 它擋不住什麼（誠實寫下；這一節必然不完整——它列的是想到的，不是全部）

- 人手在 session 裡貼了查詢原文，或 Claude 自己引述了、`git blame` 了——規則靠人守，沒有機制擋
  （`-diff` 屬性只擋 diff 生成這一條路，見上）。同類：`BASH_ENV`／`PS4` 裡刻意放一個會讀查詢檔的
  命令替換，腳本第一行的 `set +x` 來不及擋（trace 那一行時 PS4 先展開）——那等同直接 cat。
- 語料裡本來就有恰好逐字含該字串的**實質** turn（例如退役查詢裡的「資格考」有一則真的使用者 turn）——
  那不是污染，是正常召回；`self` 會把它標成 self，分不出來，讀結果時要在 session 之外看命中。
  反過來，空白與大小寫以外的改寫（全形／半形、標點、換序）`self` 看不到。
- 查詢原文**跨過**或落在 metadata 欄位 200 字元截斷之後的那種命令。完全落在之後：那段文字不在索引裡，
  `self` 看不到、它也不會靠那段文字排名。**跨過邊界**：查詢的前綴進了索引、會靠它排名，`self` 卻判
  `clean`——進索引的字元數 ＝ 200 − 查詢在該欄位裡的起始位置（`toolUseMetadata` 攤平換行後
  `prefix(200)`），起始位置在 200 − 查詢長度 到 200 之間都是這個帶。#63 的 root cause 那種
  `for q in …` 一行多條查詢的命令，後面的查詢正好容易落在這個帶。
- #6 若把 tool payload 收進索引——現在 jsonl 裡至少 8 筆完整副本（規則 1 的計數與查法）**回溯**進索引，
  查詢集整份換掉，而且換的那一組要從第一天就只在 Claude Code 之外編輯。
- **同目錄另一組儀器沒有這套紀律**（兩支腳本、兩組查詢，不要混）：
  `scripts/measure-rrf-ties.swift` 讀 `scripts/rrf-tie-queries.txt`（104 條），失敗路徑會印出失敗的
  查詢字串；`scripts/rrf-tie-mechanism.sh` **不讀那個檔**——查詢走 argv、第 20 行寫死八條自己的預設
  查詢、輸出表第一欄就是查詢。兩者支撐 `2026-08-22-rrf-tie-rate.md`，量的是**聚合**平手率而不是
  「前 1 名是誰」，所以污染的傷害形狀不同——但 `measure-rrf-ties.swift` 在 session 裡跑到失敗就把
  失敗的那幾條印進 tool_result，`rrf-tie-mechanism.sh` 的八條則是**打開那支腳本看**就進 `text` block
  （R2 verify 有兩個 reviewer 為了核對這一段而讀了它）。所以：**不要在 session 裡跑、顯示、或引述
  它們**（`rrf-tie-queries.txt` 已一併設 `-diff`）；把它們收進同一套紀律是獨立工作，追蹤於 #68。
- **目前的八條尚未在真實索引上驗過前 5 名**（檔頭第 1 條寫明了原因與補驗方式）。在那之前，
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
  同日的 `2026-09-01-noop-build-attribution.md` 量的是 SQL 語句不是文字查詢，不需要註記。

### 與其他 issue 的關係

- #62（self-hit 的檢索層排除）：會讓工具殘影的第一名掉下去，但不會讓已污染的查詢恢復成乾淨基準——
  它的前後量測是本查詢集的第一個消費者。**新腳本的列不要與 2026-09-01 之前的表對齊**：
  語料範圍（`--all-projects`）、binary（`~/bin/ltm`）、輸出格式都不同。
- #6（tool payload 是否索引）：上表「今天不會」的兩列都繫在它身上。
- #33（評估集）：真正的解是 `(查詢, 應命中的 turn)`；本查詢集只是把儀器擦乾淨，說不出代表性。
