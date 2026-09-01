<!-- SPECTRA:START v1.0.2 -->

# Spectra Instructions

This project uses Spectra for Spec-Driven Development(SDD). Specs live in `openspec/specs/`, change proposals in `openspec/changes/`.

## Use `/spectra-*` skills when:

- A discussion needs structure before coding → `/spectra-discuss`
- User wants to plan, propose, or design a change → `/spectra-propose`
- Tasks are ready to implement → `/spectra-apply`
- There's an in-progress change to continue → `/spectra-ingest`
- User asks about specs or how something works → `/spectra-ask`
- Implementation is done → `/spectra-archive`
- Commit only files related to a specific change → `/spectra-commit`

## Workflow

discuss? → propose → apply ⇄ ingest → archive

- `discuss` is optional — skip if requirements are clear
- Requirements change mid-work? Plan mode → `ingest` → resume `apply`

## Parked Changes

Changes can be parked（暫存）— temporarily moved out of `openspec/changes/`. Parked changes won't appear in `spectra list` but can be found with `spectra list --parked`. To restore: `spectra unpark <name>`. The `/spectra-apply` and `/spectra-ingest` skills handle parked changes automatically.

<!-- SPECTRA:END -->

# CLAUDE.md

給在本 repo 工作的 Claude Code 的指引。

## 這是什麼

claude-code-ltm＝Claude Code 的長期記憶。在既有的 `~/.claude/projects/**/*.jsonl`
（immutable、帶時間戳的對話逐字記錄）之上建可拋棄的索引與**可插拔的記憶策略**。

定位見 [README.md](README.md)；量測基線見 [docs/measurements/](docs/measurements/)；
記憶策略的比較框架見 [docs/memory-systems/](docs/memory-systems/)。

## LTM 類比（設計判準；完整版在 `.claude/rules/ltm-analogy.md`）

專案要達成的是**類似人類長期記憶的功能**，而「想起來」的性質可以當設計判準用。
遇到設計決定時問兩個問題：

1. **如果這是人類的長期記憶，這樣做合理嗎？** 不合理的話，是違反哪一條性質？
2. **這條性質是「LTM 功能的必要條件」，還是「human-like 這個策略的特徵」？**
   若是後者，它屬於策略，不屬於共用層。

第二問是閘門：把某條性質當成唯一正確而寫死進共用層，等於把一個策略偷渡成前提
——那正是 `pluggable-memory-strategy` 要拆掉的東西。

五條性質（各自導出的決定見 rules 檔）：內容定址而非位置定址／相關度主導提取而
使用強度只做微調／多重編碼提高可提取性／同一段經歷不因被重述而變成兩段記憶／
**可以遺忘，不可以編造**。

最後一條是類比的**邊界**而非延伸：人類記憶會重構，這個系統刻意不重構。不變式 3
與「LLM 提取只能用於 routing」的推論都源自它。

**「內容定址」這條已經被違反三次**（chunk id、`sessionId` 當 anchor 分量、
`chunks.session_id` 這個「代表來源」欄位），三次都是同一個形狀：拿一個**會變的
東西**當定址的一部分。判準是「會不會變」這個性質，不是「哪些 id 不能用」這份
清單——清單會漏，性質不會。

第三次（#25）值得記細節，因為它偽裝得最好：那個欄位存的不是一個 id，而是**從
一組等價來源裡挑出來的代表**，挑選規則是 `source_key`（檔案路徑）的極值。它看
起來像一個穩定的純量，實際上**極值會隨集合成長而移動**——實測：一則內容從未
改動的 turn，其代表值因為另一個 resume 檔出現而改變。「挑一個代表」本身就是
位置定址的一種形式，即使被挑的東西看起來是內容。

## 三條不變式（動任何 code 前先讀）

1. **`~/.claude/projects/` 唯讀。** 不擁有 source of truth。出現任何寫入路徑就是 bug，
   不是特性。測試也不准寫進去——要 fixture 就自己造。
2. **索引是純衍生物。** `rm -rf ~/.claude-ltm/derived && ltm build` 必須等價。
   任何只活在索引裡、重建後會消失的東西都違規。
3. **回傳一律附指標。** 每個命中帶 `(project, sessions, uuid, timestamp)`，其中
   `sessions` 是**集合**——持有這則 turn 的每一個來源檔各一個 session id。
   **檢索負責導航，不負責當答案。**

   session 分量是集合而不是單值（#25，layout 5）：resume 讓一則 turn 常態性地
   活在多份檔裡，而沒有任何有依據的規則能從中挑一個。挑一個並把它呈現成「這個
   來源」，是導航層最接近編造的動作——它跨不過性質 5 的內容編造那條硬線，但
   它讓「檢索負責導航」這句話在它最該可靠的地方變得不可靠。**任何消費端都不得
   把集合的某個元素當成代表值**（排序只為顯示確定性）。

推論：LLM 提取只能用於 routing（決定讀哪一段），不能用於 answering（產生答案是什麼）。
同一個提取動作，用途決定它安不安全。

## 例外：記憶層不是衍生物

`~/.claude-ltm/memory/`（append-only 事件日誌：shown／opened／cited／pinned／
dismissed，一行一筆 JSON Lines）記的是
**jsonl 記不得的事**——使用歷史。它不適用第 2 條，但受一條獨立硬約束：

> **只存指標、統計、與封閉集合的類別標籤；不存 chunk 原文、query 原文、note 原文。**

如此它即使被備份或同步也不含第三方逐字內容。**strength、links 這些不落地**——
它們是從事件重算的 projection，改公式只要重跑一次，不必改任何一筆歷史。

這條由 schema 保證到什麼程度，要說清楚（#1 verify **四輪**都抓到宣稱過強）。
本節刻意**不列舉欄位**——那份清單前後漏了四次：

> **判準有兩層，而且判準的標的是落地的 bytes，不是 decode 之後的 Swift 值。**
>
> 1. **bytes 層（唯一涵蓋得完的一層）**：canonical 檔的每一行，解碼後重新編碼
>    必須與原始 bytes **逐字相同**，否則當作損壞。實作在
>    `CanonicalCoding.decodeCanonicalLine`。它不列舉任何入口，因此一次擋掉
>    巢狀未知鍵、陣列多餘元素、重複鍵、`\uXXXX` 逃脫、多餘空白、鍵序不同
>    ——包含還沒被想到的那些。
> 2. **型別層（防禦縱深）**：每一個**會被原樣序列化的東西**都要有形狀約束，
>    不論它是字串、陣列還是我們沒寫的 decoder。判準是「會不會被原樣序列化」，
>    **不是「它像不像識別碼」，也不是「它是不是字串欄位」**。

擋掉的是「不小心把原文塞進去」，**擋不掉刻意用 ASCII 編碼原文的人**；bytes 層
也**擋不掉一個合法值本身就是自然語言**（例如一個 60 字元的英文句子當
`GenerationID`）。

這段的每一句都是代價換來的，過程留著因為它是同一個錯的四次重演：
R1 列舉六個識別碼型別 → R2 三個 lens 各自重現漏掉的第七個（`ContentHash`）；
R3 判準縮成「字串欄位」→ 漏掉 `Anchor.span`（空 span 成為萬用 anchor）；
R4 加未知欄位檢查但只裝在頂層 → R5 從巢狀容器、`span` 陣列、重複鍵三條路徑穿透，
其中兩條是「補巢狀檢查」修不掉的（`Range<Int>` 的 decoder 在 stdlib、重複鍵的鍵名
在白名單內）。**每一次的修法都是再列舉一次入口，每一次都有下一種。**
**列舉會漏，判準不會**——而這句話我自己違反了四次，所以本節現在不放清單。

「封閉集合的類別標籤」是刻意寫進來的一條窄例外，也是它的邊界：**query class label**
（`cjk-2char` / `cjk-3char` / `cjk-4plus` / `latin-alnum` / `mixed`）可以存，query 原文
不行。判準是資訊量——五值集合對查詢內容幾乎不帶資訊，而原文帶全部。標籤在呈現當下從
query 算出、原文隨即丟棄，與「LLM 提取只能用於 routing」是同一條線：從內容導出一個決定，
但不把內容留下。

例外只涵蓋**封閉且極小**的集合。要新增一個類別軸，先問它的值域有多大——值域一開，
它就從統計變回內容。

## 隱私邊界

本機語料含第三方逐字內容（協調會逐字稿、學生資料、合作者未發表 IP）。因此：

- **零對外通道**：embedding 用 `NLContextualEmbedding`、LLM 用 `FoundationModels`，
  都在裝置上。不引入任何雲端 embedding／LLM 依賴，即使「只是測試」。
- **測試 fixture 用合成資料**，不從真實 `~/.claude/projects/` 複製片段進 repo。
  `fixtures/real/` 已在 `.gitignore`。

## 技術要點（踩過的坑）

- **中文必須用 `NLContextualEmbedding`**。舊的 `NLEmbedding.sentenceEmbedding(for:)`
  對 `.traditionalChinese` / `.simplifiedChinese` 回 `nil`——會靜默拿不到向量而不報錯。
- **向量不可跨 revision 比較**。`NLContextualEmbedding.revision` 變了（通常隨 macOS 更新）
  就必須重建全部向量，否則新舊向量混在同一個空間裡比距離，結果無意義且不會報錯。
- **不要加 ANN 索引**——但那份 baseline 的兩個前提都已被實測推翻，理由要換一份。
  「28 萬 chunk」實際是 **640,760**（2.29 倍），而「chunk 數逼近百萬再議」這個重議
  觸發**問錯了維度**：`docs/measurements/2026-08-27-query-latency-decomposition.md`
  量到向量檢索那一段在 6 秒的查詢裡小到量不出來，成本幾乎全在掃描。
  **誠實邊界**：那份紀錄只有一個規模點，所以它支持「現在不上 ANN」，**不支持**
  「答案與規模無關」——要判斷它何時會變成瓶頸，需要第二個規模點。
  #56（`docs/measurements/2026-09-01-scan-parallelism.md`）把掃描並行化後查詢
  降到 ~1.2s，成本大宗**仍在**共享 refresh/build 路徑——「不上 ANN」的結論
  不變；那份新紀錄一樣沒有元件級計時，不改變本條的誠實邊界。
- **jsonl 不假設 append-only，但利用它**。`scan_state` 表記 `prefixHash`，對得上就從
  `processedBytes` 續讀，對不上就整份重解。**游標與內容在同一個交易裡**——先前
  游標在一個獨立的 `state.json`，而那讓它成為第三份真相來源：WAL 回滾帶走內容
  卻留下超前的游標，於是那段語料永遠不再被解析而 build 印 ✓。那個檔現在既不寫
  也不讀；舊索引升上來時**不遷移**（游標與內容是否一致這個事實不在磁碟上），
  而是具名拒絕並要求 `ltm build --full`。
- **`FileManager` 的失敗常常不是回 `nil`，是安靜地回「空的」**。實測（#26）：對一個
  權限不足的目錄，`enumerator(at:includingPropertiesForKeys:options:)` **不回 `nil`**
  ——它回一個產出零個項目的 enumerator。所以 `guard let walker = … else { continue }`
  這種寫法**那條 else 根本不會 fire**，而失敗被當成「這個目錄是空的」。
  要被告知就得用帶 `errorHandler` 的多載。同理 `(try? contentsOfDirectory(…)) ?? []`
  把權限錯誤變成「零個項目」。**判準：問「這個 API 失敗時我怎麼知道」，而不是假設
  它會回 `nil` 或拋錯。**
- **`FileManager` 的路徑形式不一致，別用字串前綴算相對路徑**。實測（2026-08-17）：
  `temporaryDirectory` 與 `resolvingSymlinksInPath()` 都給 `/var/folders/…`，而
  `contentsOfDirectory` 對同一棵樹給 `/private/var/folders/…`。前綴比對因此落空，
  state 的鍵會退化成絕對路徑——換一台機器就整份語料重解，而且沒有任何錯誤訊息。
  相對鍵要在**遍歷當下**由起點目錄構造。
- **語料是外來資料，解析路徑一律不得 trap**。`Anchor` 與各識別碼型別對非法值是
  `preconditionFailure`（那是給呼叫端錯誤用的），所以 ingest 端必須先 `validate`
  再建構，不合法就跳過並記帳。跳過本身要能說出「跳了幾筆、為什麼」——沉默的跳過
  等於索引少了東西而沒人會發現。
- **band 是相關度分層，不是名次**。融合名次每筆都不同，拿它當 band 會讓每個候選
  自成一帶、任何策略都無處可移——而且**不會報錯**（沒有跨帶嘗試，guard 不 fire），
  `human-like` 與 `archival` 逐字相同。現行規則是命中的通道數（多重編碼），零參數，
  帶內分佈量測見 `docs/measurements/2026-08-17-band-population.md`。
- **`sessionId` 不是身分，是導航資訊，而且是複數**。session resume 會把同一則 turn
  複製進新檔案並換上新的 sessionId（全語料 8,324 檔 12,488 筆、內容 **100%** 相同、
  其中 98.9% 的 sessionId 不同——`docs/measurements/2026-08-18-resume-duplication.md`）。
  拿它當 anchor 的一部分，使用歷史會隨每次 resume 蒸發，而 orphan 原因會誤報成
  「turn 不見了」。anchor 的 source 用 project 指紋。
  **也不要退一步存「其中一個」**：那正是 #25 的病灶（見上方第三次違反）。人類記憶
  裡 source memory 與 content memory 本來就可分離——來源是複數或缺失都不損害記憶
  本身，會出問題的是硬把它壓成單值。導航的 session 一律走 `chunk_sources` 的全部
  來源。
- **讀歷史與寫歷史是兩件事**。把「要不要記錄」與「要不要讀取」綁在同一個旗標上，
  會讓策略在沒開記錄時安靜地拿到空投影，而輸出照樣宣稱跑了那個策略。
- **索引層不知道語料在哪，也不自己判斷路徑是否在語料內**。語料根由 facade 傳入；
  「這條路徑在不在語料裡」的判定（inode 身分、symlink、firmlink）住在 LTMMemory 的
  `CorpusLocation`，索引層只宣告 `CorpusContainmentPolicy` 這個需求，由 facade 注入。
  複製那份判定會漂移，而漂移的方向是「放行了不該放行的路徑」且不報錯。
- **同一件事有兩個寫者，就是兩份會漂移的規格**。`refreshIncrementally` 曾經自己算
  向量、自己配 row、自己 append 側車——與 `IndexBuilder` 做同一件事的第二份實作。
  修好其中一份不會修好另一份，而且**沒有任何訊號**：側車落地順序改了、只改了一份，
  崩在中間就留下「DB 宣稱 N 個向量、檔案只有 N−k 個」。修法是刪掉一份，不是把
  正確順序照抄過去。
- **`ftruncate` 對較短的檔案是補零延長，不是報錯**（POSIX）。所以「截斷回宣稱長度」
  這個動作在檔案**比宣稱短**的方向上是騙人的：缺掉的向量會被一堆零取代，而零向量
  與任何查詢的點積都是 0——向量通道靜默失效，筆數核對從此永遠通過。截斷只准縮。
  檔案比宣稱的短代表向量真的不見了，那是拒答的理由，不是修補的機會。
- **來源檔與 chunk 是多對多，刪除的粒度不可以是單一欄位**。session resume 讓同一則
  turn 活在多個檔裡（去重之後只有一列）。若那一列只用一個 `source_key` 欄位記住
  「我來自哪裡」，刪掉那個檔就會刪掉**另一個檔還持有的** turn，而另一個檔沒有變動、
  增量掃描不會重新產出它——增量與全量重建就此不等價（違反不變式 2），症狀只有
  「以前找得到的東西現在找不到」。
- **破壞性命令要問「在最常見的情境下，它做的事跟它的名字一樣嗎」**。
  `ltm memory --prune` 的名字與說明都是「丟掉讀不回來的紀錄」，而在它**主要的**
  觸發情境（定址規則換代，於是舊紀錄全部讀不回來）裡，它做的事是「清空整份歷史」。
  兩者在別的情境下不同，在主要情境下恰好相同——所以審視危險操作時，要拿它最常見
  的輸入去看，不是拿它的一般描述。判準不是「這個操作危險嗎」（它一直都危險），
  是「使用者照著我給的指示走一次，最可能發生什麼」。
- **`flock` 綁在 inode 上，所以「原子替換」會讓別人的鎖失效**。用
  `write(to: temp)` + `replaceItemAt` 落地是資料寫入的常見正確做法，但它換掉 inode
  ——另一個行程持有的 `LOCK_EX` 從此守著一個已被 unlink 的舊 inode，它接下來的
  `write(2)` 沒有任何錯誤地消失。實測過：持鎖期間 replace 照樣成功。
  **判準：要與既有的 `flock` 協定共存，就不能換 inode**（改用 `ftruncate` + 就地
  覆寫，並自己拿同一把鎖）。原子性與鎖的正確性在這裡是二選一，而並發靜默丟資料
  比崩潰窗口糟——前者無聲、日常可達，後者有備份且要剛好崩在幾毫秒內。
- **Swift 的 `String.hashValue` 每個 process 隨機種子化**（實測同一字串三次得
  49 / 973 / 727）。任何用它產生測試資料的地方，行為都會在不同執行之間變動——
  而症狀不是「偶爾失敗」，是**偶爾成功**：實測某條回歸鎖在破壞實作後 10 次只紅
  5 次，而我宣稱過它「驗過會紅」。測試要用確定性的雜湊（SHA-256 或 FNV-1a）。
  這條**已經記在 `Sources/LTMEval/Interleaving.swift`**，卻沒有攔住我在測試用的
  embedder 上重犯——所以它現在也在這裡。
- **約束的執行點必須在不受約束的那一方**。`conservative` 的等分區段條件曾經由
  `conservative` 自己呼叫守衛執行——**被約束者執行自己的約束不是約束**。偵測方式是
  變異測試：把那一行換掉，67 條測試全綠，因為唯一覆蓋該約束的測試從不建構策略、
  只把手工排列餵給 helper。修法不是補測試（策略不會違反自己的條件，驅動不出違規），
  是把執行點上提到 seam，並讓策略只能**宣告**而不能**定義**約束——判準是「seam 能不能
  自己算出這個檢查需要的東西」：能，就宣告不帶資料、策略只選不定義；不能，那個洞就
  還開著（`displacementBound` 的值仍由策略提供，就是後者）。

  **但「洞已關」這句要收窄，#32 的 verify 可執行地證偽過一次。** 六處文件當時都寫著
  「策略只能選、不能弱化一條已宣告的約束」，並以此論證它與 `displacementBound`
  「種類不同」。實測推翻：`placementConstraints` 是 `{ get }`，可實作成 computed
  property，而 seam 每次呼叫**重讀**它、不記錄、不驗證——同一個 instance、同一組候選，
  第一次拋、第二次過。**成立的較窄陳述**是：策略無法**定義**約束的意思（切法由
  `RankingGuard` 擁有），但**能控制單次呼叫受不受檢**。所以它與 `displacementBound`
  的差別是**表面大小**（封閉詞彙子集 vs 連續值域），**不是種類**——兩者都是策略自報
  而無人驗證，追蹤於 **#34**。
  對照組讓這件事更清楚：緊接在約束檢查之後那個迴圈**確實**拿實際位置變化對照自報的
  `displacement` 與 `movement`。約束的自報沒有這道對照，而它本來可以有。

  **#34 關掉了其中一半，而「另一半為什麼關不掉」本身是這次的收穫。** 約束改由一張
  以**識別碼**為鍵的授權表決定，seam 取「表 ∪ 實例」——交替回值的 getter 因此拿不到
  任何東西（空集合減不掉表裡的約束），而這個保證來自**合成的方向**，不是靠記住上次
  讀到什麼。

  **但 verify 又抓到同一個形狀往下移了一層。** 那張表以 `id` 為鍵，而 `id` 也是
  `{ get }`、也每次重讀、也沒有跨呼叫比對。實測一個 `id` 在兩個**都被授權**的識別碼
  之間交替的 conformer：第一次拋、第二次過——**#32 那個探針輸出的逐字重現，對著新
  機制**。買到的是「冒用出貨識別碼的 conformer 逃不掉那個識別碼的約束」；買不到的是
  「策略被釘在一個身分上」。判準因此要再推一層：**關掉一個自報的洞時，先問「我用什麼
  當鍵」——那個鍵通常就是下一個同形狀的自報。**（追蹤於 #37）

  同一輪還抓到「seam 維持純函式」在七處 artifact 被宣稱而實作不滿足（授權查詢每次都
  經過一張有鎖的 process-lifetime 註冊表）。**那正是本次要修的病的完整重演**：一句寫在
  多處、沒人驗證的宣稱。成立的較窄陳述是「seam 不記錄任何策略宣告過什麼」。

  但 `displacementBound` 同一招行不通：spec 要求它可在建構時組態，所以
  `human-like(bound: 3)` 與 `human-like(bound: 1)` 是同一個識別碼的兩個實例——
  **識別碼鍵的表結構上承載不了它**。判準因此再推一層：問「這個東西由什麼決定」，
  再問「我的權威表以什麼為鍵」，兩者不同就別硬套。bound 的權威問題仍然未決。
- **一個 seam 要求它的輸入具備某個性質，那個性質就是輸入方的職責**。
  `MemoryStrategy` 的前置條件要求候選到達時 band 已非遞減，所以分帶與排帶屬於
  檢索層——先前在 facade 排序，那就是 spec 明文禁止的「在 seam 之外重排」，
  即使排序規則本身正確。判準可以反過來用：看到某一層在為下一層「準備」資料，
  先問那件事是不是本來就該由它做。
- **不可能失敗的測試比沒有測試更糟**。它在覆蓋率與閱讀上都算數，於是那個性質
  看起來有人守。判準不是「這條測試看起來合理嗎」，是**刻意破壞實作、確認它變紅**
  ——而且要確認它為**對的理由**變紅。踩過三次：測試名宣稱的性質從來沒被斷言
  （只斷言了策略對自己行為的自述）、回歸鎖全測在 helper 上而生產路徑那行可以整行
  刪掉、斷言的語料上根本不可能出現要防的那個情形。
- **SwiftPM 的增量建置會給假綠**。在 A 模組的 enum 加一個 case，依賴它的 B 模組裡
  非窮盡的 `switch` **不會**立刻報錯——`swift build` 回「Build complete」，要 `touch`
  B 的檔案才編得出那兩個 error。與 stale release binary 是同一個形狀：**你以為驗過
  的東西根本沒被重跑**。改跨模組的型別之後，別信第一次的綠燈。

- **依賴圖控制的是 API 可及性，不是 capability**。把一個型別移出下層模組、或改成
  `internal`，擋掉的只是**便利型別**——在一個模組能開檔案的語言裡，「不要讀某個檔」
  沒有型別層的表達方式（`Data(contentsOf:)` 與 `JSONSerialization` 都在 Foundation，
  格式是 line-delimited JSON）。判準：**要判斷一條「SHALL NOT 讀 X」能不能靠依賴圖
  執行，先問「不用那些要被移走的型別，還做不做得到」**——做得到，那個改動就交不出
  它承諾的編譯期事實，而代價（動依賴圖底層、波及所有模組）是真的。

  **問法要精確到這個程度，這條的第一版就是問錯而寫錯的**（#14 R3）：初版寫「#14
  那兩條 SHALL NOT 的反例正是這樣寫的，移走型別不會讓它們失敗」——假的。其中一個
  反例**用了** `CorpusReader`，變 internal 會讓它編不過。正確的問法不是「現有的
  反例有沒有用到那個型別」（那是關於一段程式碼），是「**不用它還做不做得到**」
  （那是關於 capability）。兩個問題的答案在這裡剛好相反，而只有後者支撐結論。
  **沒有執行點的 SHALL NOT 要拆成它實際保護的東西並各自指名執行點，不要靠移型別
  假裝它有。**

## 工作流程

本專案走 IDD（issue-driven development）：先開 issue、診斷、實作、驗證，commit 引用 `#N`。

**變異測試的還原一律用檔案備份，不要用 `git checkout -- <file>`。** 本 session
踩了三次，每次都丟掉未 commit 的真實工作。第三次特別值得記，因為它發生在已經
學到「變異前先 commit」之後：那次要變異的**就是還沒 commit 的修法本身**，於是
「先 commit」這條規則在它最該生效的地方剛好不適用，而 `git checkout` 把工作還原
到了**上一版的實作**——測試照樣全綠，因為綠燈來自舊版而不是新版。

正確做法：`cp <file> /tmp/x.good` → 改 → 跑 → `cp /tmp/x.good <file>`。判準不是
「有沒有 commit」，是**還原的目標是不是我手上這一份**。

**變異測試要驗的是「這條測試由誰扛」，不只是「它會不會紅」。** #40 的第一版修法
加了一個守衛、測試也綠，但退掉那個守衛**零測試變紅**——真正在扛的是同一次改動裡
的另一行。驅動不了的守衛要拆掉，不是留著加註解（同 `conservative` 自檢那次的
處置）。做法是**逐一退掉**每個新增的機制，而不是整批退。

**`/idd-verify` 的 codex leg 會間歇性因額度用完而失敗——是額度，不是設定問題。**
所以**照常傳 `codexEnabled: true`**（上一版寫「傳 `false`」，那是額度全滿時的權宜，
會讓能跑的輪次白白失去跨模型盲驗）。

**每一輪的跨模型狀態要看那一輪的 `stats.reviewers`，不要照抄上一輪的結論**：

查法：那一輪 workflow 結果的 `stats.reviewers[].ok` 與 `stats.integrity`；
落地在該輪 master comment 的 Engine 段。**不要從別輪推。**

| 輪次 | 完成的 lens | `integrity` |
|---|---|---|
| R14 / R15 | 全部六個（含 codex）| 0 |
| R16 | 四個（codex + DA 掛）| 2 |
| R17 | **兩個**（只有 requirements + regression）| 4 |

codex leg 失敗那幾輪，結論要以「同一家族的 N 個視角都沒看到」來理解，不是「兩個
家族都沒看到」——而 N 要照實數（R16 是 4、R17 是 2）。**N 越小，該輪「沒發現問題」
的資訊量越低**：R17 只有兩個 lens 卻仍找出 8 個 CRITICAL，所以低 N 不代表乾淨。

設計討論走 Spectra／superpowers 的 spec 流程，spec 落在 `docs/superpowers/specs/`。

## 誠實邊界

**判準：本 repo 沒有量測支撐的效能宣稱，一律不得出現**——不在 code 註解、不在文件、
不在 commit message。「有量測支撐」指的是 `docs/measurements/` 底下有一份可指名的
紀錄，而該紀錄涵蓋你正在宣稱的那個比較。

寫成判準而不是「不得宣稱策略 X 比 Y 好」，是因為後者是列舉：#1 verify R7 就在
`QueryClass.swift` 與 design.md 找到「+1pp 增益」「100% 集中在中文雙字桶」這類數字，
它們不是策略比較（所以不在那句列舉的射程內），但同樣是效能宣稱。**判準涵蓋它們。**

**同族的第二條判準（#39）：可查證的宣稱要把查法寫在旁邊。**

不是「不要寫錯」——那是勸告，不是判準。是**寫下取得那個值的方法**：

> ❌ 「一個寫進 spec 的已知缺口有**兩天**完全沒有落點」
> ✅ 「…有約 8 小時沒有落點（`cfa8841` 03:04 → `97a827c` 10:50，同一天）」

前者讀起來與一個查過的數字**沒有差別**；後者讓下一個讀者不必重查，而且**寫不出查法
的人會在當下發現自己其實沒查**。

**最壞的一種是宣稱自己完整的列舉**（#14 verify，第七個實例，也是第一個標的是文件
自身的）。`memory-strategy` spec 列了 seam 的違規名並寫「每個從公開入口可達的
`throw` 都在這份清單裡」——那句話讀起來就是一次查證的結果。**它不是。** 漏了三個：
`nonFiniteBaseScore` / `bandsOutOfOrder` / `malformedStatistics` 是公開入口在進到
被檢查的方法**之前**跑的前置檢查，而我只從那個方法往內數。修法不是補上三個名字就
算了（那只是再列舉一次，下次一樣會漏），是**把查法寫進 spec 本身**：三個集合
（列舉的名字、enum 的 case、可達的 `throw` 站點）必須逐一對應——一條下一個讀者
三十秒就能重跑的檢查。

**這是慣例不是機制，執行點在 verify 的獨立讀者**——而那個限制是量出來的，不是讓步：
掃 spec 散文裡 backtick 指名的識別碼比對 `Sources/`，**零命中**，且 #39 記錄的六個
實例**沒有一個**會被它抓到（它們斷言的分別是系統狀態、程式屬性、文件內部矛盾、
一條沒具名的測試、一個數量、一個約束是否存在——**六種不同的查法**）。#14 的兩輪
又添三種：一份列舉是否完整、一句全稱是否真的無條件、一個宣稱與**同一個檔案裡的
另一則註解**是否矛盾。**九次，九種查法。**

九次全部由 verify 抓到，**作者自審零次**。`common-spec-prose-enumeration.md` 記過為
什麼：**規格散文的自我矛盾要靠另一個讀者，不能靠作者自己再讀一遍。**

**#14 R2 另外量到一件事：作者的「我查過了」本身也會用列舉的方式失敗。** 我為了確認
沒有殘留而 grep 了「七項檢查 / seven checks」，實際文字是「七**道**檢查」——五處活的
註解因此逃過那次掃描。**修法不是多背一種拼法**（那只是把列舉加長），是把那個數字
從註解裡整個拿掉、只留 spec 一份：一個數字被複述 N 次就是 N 份會漂移的規格，而
漂移不會報錯。

**而「拿掉」這個動作本身又漏了一處，兩輪都漏**（#14 R3 在 `Package.swift` 抓到）。
更難看的是我當時的兩份產物互相矛盾：commit message 說「四處」，同一次 commit 新寫進
`Module.swift` 的註解說「五個地方」——**沒有一份對，也沒有任何東西比對它們**。
所以真正的結論是下一層：**把一份規格收斂到單一位置，不等於它從此不會漂移，只是把
漂移搬到一個沒人看守的地方。** 收斂之後要補的是一個會變紅的檢查，不是一句「現在
只有一份了」。#14 補的是 `StrategyViolationSpecSyncTests`。

判準的兩側都要說清楚：

- **策略比較目前沒有任何量測支撐**——沒有評估集，沒有一組 `(查詢, 應命中的 turn)`。
  所以任何「策略 X 比較好」的說法都不得出現，包括文件裡的推薦、包括方向性的預測
  （「很可能統計不可分辨」也是預測）。資料集本身追蹤於 **#33**（#16 把它劃為「獨立
  蒐集」，而那條線劃出去後一度沒有落點）。

  **#33 之後這句話仍然成立，而且要說清楚它變了什麼、沒變什麼**：變的是**機具**
  ——`ltm query --compare` 會走交錯器、落地 `PresentationRecord`，所以
  `ComparisonScorer` 從此有輸入可讀（在此之前它的事件全部落進
  `presentationNotTracked`）。

  **沒變的是資料。** #33 的 verify 抓到我在這裡寫過一句假話：原文說「交錯比較
  要的是真實使用累積出來的互動事件，**而那需要時間**」——那讀起來像一個等得到的
  bootstrap 期。事實是：淨強度只由 deliberate 事件（`opened`／`cited`／`pinned`／
  `dismissed`）推動，而當時**這個系統裡沒有任何介面寫得出它們**（全 repo 只有
  `.shown` 一個寫入端，而 `shown` 被 `Projection` 明確排除在 reinforcement 之外、
  只計 impressions）。所以每一次比較都是 null comparison，跑一萬次也一樣。缺的
  不是時間，是一個**把互動記成 deliberate 事件的產生端**。

  **那個產生端現在存在了**（`ltm mark`，#24／#35）。所以上面那段的時態要看清楚：
  「沒有任何介面寫得出它們」描述的是 2026-08-26 之前的狀態。

  **但結論一個字都沒變**，而這正是這一段要防的誤讀：能寫事件不等於有事件。資料
  仍然要靠實際使用累積，而在累積夠之前，比較仍然是 null。差別只在於**現在它累積
  得起來**——先前連累積的路徑都沒有。「有機制」與「有資料」是兩件事，而策略比較
  要的是後者。

  **機制存在 ≠ 有量測支撐。** 要寫策略比較的結論，仍然得先有一份涵蓋那個比較的
  `docs/measurements/` 紀錄，而它還不存在。
- **檢索基線的量測有支撐**（`docs/measurements/2026-08-08-baseline.md`，issue #2），
  所以引用它的數字是可以的——**但必須指名出處**，讓讀者能查證那份量測涵蓋什麼、
  不涵蓋什麼。不指名出處的數字，讀者無法分辨它屬於哪一側。
- **有第三側，而它最容易被誤讀**：`docs/measurements/2026-08-22-rrf-tie-rate.md`（#18）
  量的是 `conservative` **有沒有可動的空間**（精確平手多常發生），**不是**它動得對不對。
  它是一份合格的可指名紀錄，但引用它**不能**推出任何策略優劣——那仍然落在第一側。
  這份紀錄自己在兩輪 verify 裡各被抓到一次過度宣稱（從觀測到的段長推「結構上限」、
  把某桶的零觀測寫成斷言），所以它的衍生文件現在**一個數字都不複述**，只留定性結論
  與指標。要數字就去讀那份紀錄的分桶表與它自己寫明的涵蓋範圍。
