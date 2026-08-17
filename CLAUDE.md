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
- **索引層不知道語料在哪，也不自己判斷路徑是否在語料內**。語料根由 facade 傳入；
  「這條路徑在不在語料裡」的判定（inode 身分、symlink、firmlink）住在 LTMMemory 的
  `CorpusLocation`，索引層只宣告 `CorpusContainmentPolicy` 這個需求，由 facade 注入。
  複製那份判定會漂移，而漂移的方向是「放行了不該放行的路徑」且不報錯。

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
