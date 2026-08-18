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

claude-LTM＝Claude Code 的長期記憶。在既有的 `~/.claude/projects/**/*.jsonl`
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

**「內容定址」這條已經被違反兩次**（chunk id 一次、`sessionId` 一次，後者是 #24
verify 抓到的），兩次都是同一個形狀：拿一個**會變的東西**當定址的一部分。判準
是「會不會變」這個性質，不是「哪些 id 不能用」這份清單——清單會漏，性質不會。

## 三條不變式（動任何 code 前先讀）

1. **`~/.claude/projects/` 唯讀。** 不擁有 source of truth。出現任何寫入路徑就是 bug，
   不是特性。測試也不准寫進去——要 fixture 就自己造。
2. **索引是純衍生物。** `rm -rf ~/.claude-ltm/derived && ltm build` 必須等價。
   任何只活在索引裡、重建後會消失的東西都違規。
3. **回傳一律附指標。** 每個命中帶 `(project, sessionId, uuid, timestamp)`。
   **檢索負責導航，不負責當答案。**

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
- **不要加 ANN 索引**。28 萬 chunk 的暴力 cosine 用 Accelerate 是毫秒級。理由與重議
  觸發見 `docs/measurements/2026-08-08-baseline.md`。
- **jsonl 不假設 append-only，但利用它**。`state.json` 記 `prefixHash`，對得上就從
  `processedBytes` 續讀，對不上就整份重解。
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
- **`sessionId` 不是身分，是導航資訊**。session resume 會把同一則 turn 複製進新檔案
  並換上新的 sessionId（實測 300 檔 5,722 筆、內容全同、其中 4,337 筆 sessionId 不同）。
  拿它當 anchor 的一部分，使用歷史會隨每次 resume 蒸發，而 orphan 原因會誤報成
  「turn 不見了」。anchor 的 source 用 project 指紋。
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

## 工作流程

本專案走 IDD（issue-driven development）：先開 issue、診斷、實作、驗證，commit 引用 `#N`。
設計討論走 Spectra／superpowers 的 spec 流程，spec 落在 `docs/superpowers/specs/`。

## 誠實邊界

**判準：本 repo 沒有量測支撐的效能宣稱，一律不得出現**——不在 code 註解、不在文件、
不在 commit message。「有量測支撐」指的是 `docs/measurements/` 底下有一份可指名的
紀錄，而該紀錄涵蓋你正在宣稱的那個比較。

寫成判準而不是「不得宣稱策略 X 比 Y 好」，是因為後者是列舉：#1 verify R7 就在
`QueryClass.swift` 與 design.md 找到「+1pp 增益」「100% 集中在中文雙字桶」這類數字，
它們不是策略比較（所以不在那句列舉的射程內），但同樣是效能宣稱。**判準涵蓋它們。**

判準的兩側都要說清楚：

- **策略比較目前沒有任何量測支撐**——沒有評估集，沒有一組 `(查詢, 應命中的 turn)`。
  所以任何「策略 X 比較好」的說法都不得出現，包括文件裡的推薦、包括方向性的預測
  （「很可能統計不可分辨」也是預測）。
- **檢索基線的量測有支撐**（`docs/measurements/2026-08-08-baseline.md`，issue #2），
  所以引用它的數字是可以的——**但必須指名出處**，讓讀者能查證那份量測涵蓋什麼、
  不涵蓋什麼。不指名出處的數字，讀者無法分辨它屬於哪一側。
