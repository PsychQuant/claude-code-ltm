## 1. 先量測，再決定 band 規則

- [x] 1.1 量測 channel-count 分層在真實語料上的帶內分佈，作為 design decision "Relevance band is the count of matched retrieval channels" 與 requirement "A candidate's relevance band is the number of retrieval channels it matched" 的採用前提：對真實語料建索引、跑一組查詢，記錄每個候選命中幾條通道、每一帶有幾個候選。Behavior：`docs/measurements/` 下多一份具名紀錄，說明帶內候選數的分佈。**若分佈退化**（幾乎全部只命中一條，或幾乎全部命中三條），本規則作廢、change 停下重新裁決，不得逕行實作。Verify：量測紀錄存在且被 retrieval spec 引用；分佈數字可從紀錄讀出。

## 2. Anchor 與 turn 身分

- [x] 2.1 `Anchor.source` 改為 project 指紋，實現 design decision "An anchor's source is a project fingerprint, not a session identifier" 與 requirement "Anchor addresses corpus text by content, not by index identity" 的修訂條款 "The source fingerprint SHALL be derived from a property of the corpus that does not change when the same turn is observed again through a different session file"：source 為 project 目錄名的 SHA-256 前 32 個小寫十六進位字元。Behavior：同一則 turn 經由兩個 session 檔觀察到時，anchor 相同；指紋符合 `OpaqueIdentifier`（實測 311 個 project 有 173 個名稱超過 64 字元，故不可直接存名稱）；canonical store 內不出現本機路徑。Verify：LTMCoreTests 的指紋穩定性與形狀測試。
- [x] 2.2 chunk 身分改為 `(project 指紋, turn 識別碼)`，實現 design decisions "Turn de-duplication is by content, and the uniqueness key follows" 與 "`sessionId` is demoted from identity to navigation"，對應 requirement "Chunk granularity is one conversation turn with full pointer metadata" 的修訂條款 "A turn observed through several session files … SHALL yield one chunk"：唯一鍵改掉、upsert 不再改寫身分欄位、`session_id` 降為導航 metadata。Behavior：同一 turn 出現在兩個 session 檔時索引只有一個 chunk。Verify：`LTMIndexTests` 的 resume 去重測試。（2026-08-22 由 #25 修正：本行原本另寫「並存最近觀察到的值」「其 pointer 報最新的 session」，且 Verify 指名 spec Example 的三列 fixture 與 `navigationTieBreakFollowsTheSpecExample`。那條規則從未生效並已於 layout 5 整條移除，該 Example 已從 spec 刪除，該測試已改名為 `identicalTimestampsKeepEverySourceAfterBuild` 並換了斷言——三個指涉都已不存在。去重本身仍然成立，故保留。）
- [x] 2.3 舊格式 anchor 的拒絕路徑，實現 design decision "Existing anchors are discarded, and this is the only moment that is free" 與 requirement "Anchors recorded under a superseded source-fingerprint form are refused, not reinterpreted" 與 ltm-cli 的 "An index built under a superseded anchor format is refused"：索引記錄 anchor 格式版本；不符時查詢非零結束並指名 `ltm build --full`，事件層對舊格式紀錄具名拒絕而非重新詮釋。Behavior：兩條路徑都拒絕、都指名補救方式，且不隱式重建。Verify：LTMServiceTests 的格式不符拒絕測試；LTMMemoryTests 的舊格式紀錄拒絕測試。
- [x] 2.4 跨 resume 的使用歷史存活測試，實現 memory-events 的 "Anchor survives a session resume"：fixture 為同一 turn 先後出現在兩個 session 檔（不同 sessionId）。Behavior：在只有第一個檔案時記錄的事件，在第二個檔案索引後仍解析得到，且被 projection 計入。Verify：具名的 LTMServiceTests 跨 resume 測試——這是 B3 的回歸鎖。

## 3. Band 與策略生效

- [x] 3.1 band 改由命中通道數決定，實現 design decision "Relevance band is the count of matched retrieval channels"，對應 requirement "A query fuses lexical and semantic channels by reciprocal rank" 的修訂條款 "The fused rank SHALL NOT be used as the candidate's relevance band"：`LTMService` 停止用 `fusedRank` 建 band，改用 `ScoredChunk.channels` 的數量分層（三條 > 兩條 > 一條）。Behavior：命中同樣通道數的候選共享同一帶；命中較多通道者的帶較高。Verify：LTMServiceTests 對照 spec Example 的四列表格（A/B/C/D 的帶配置）。
- [x] 3.2 策略生效的端到端測試，實現 "A reordering strategy produces a different order from a non-reordering one when history exists"：測試必須穿過 `LTMService.query`，不是單獨測策略型別。Behavior：同一份候選 + 非空歷史，`human-like` 與 `archival` 產出不同順序，且至少一筆位移非零。Verify：具名的端到端測試——這是 B1 的回歸鎖，且刻意不走「單獨測策略」那條路，因為缺陷正是出在候選怎麼被建構。
- [x] 3.3 `--strategy` 與 `--record` 解耦，實現 design decision "Reading usage history is decoupled from writing it"，對應 requirement "Event recording is opt-in and off by default" 的修訂條款 "Reading usage history SHALL NOT be conditioned on `--record`"：策略消費事件時就開事件存放讀取，`--record` 只管附加 `shown`。Behavior：`--strategy human-like` 不帶 `--record` 時排序反映歷史且不寫入任何事件。Verify：CLI 測試斷言排序受歷史影響且事件檔未變動。

## 4. 寫入路徑的一致性

- [x] 4.1 查詢路徑取單寫者鎖：`refreshIncrementally` 與 `IndexBuilder` 共用同一把鎖，取得後重讀 state 與 meta。Behavior：`ltm build` 與 `ltm query` 重疊、或兩個並行 query，不會產生 `vector_row` 指向他人向量的索引。Verify：並行寫入測試（一方持鎖時另一方明確失敗或等待，不靜默交錯）。
- [x] 4.2 側車先落地再提交指標：`appendVectors` + fsync 完成後才提交 `vector_count`；啟動時驗證 `fileSize == vector_count * dimension * 4`，不符則拒答並指名 `ltm build --full`，絕不補零後續寫。Behavior：中止最多留下可截掉的多餘 bytes，不會出現「宣稱 N 個、實際 N−k 個」。Verify：截斷側車後查詢被拒的測試；並修正原本與程式碼相反的註解。
- [x] 4.3 來源消失與不完整尾行，實現 corpus-indexing 的 "A source file that disappears has its chunks invalidated" 與 "An incomplete trailing record is re-read on the next scan"：作廢集合納入「上輪有、本輪未見」；resume offset 不越過最後一個完整紀錄；不完整與 malformed 分開記帳。Behavior：刪檔後增量結果等於全量重建；並行寫入時的半行在下一輪被索引且不報為損壞。Verify：兩條具名測試（刪檔作廢、半行重讀）。
- [x] 4.4 upsert 前清 FTS 舊列、刪除錯誤不吞：`ON CONFLICT` 更新文字前先以舊文字送出 FTS5 `'delete'`；`deleteChunks` 的 FTS 錯誤外拋讓交易 rollback；無向量時明確寫入 `vector_row = NULL`。Behavior：改寫過的來源不再命中舊文字。Verify：SQLite 上的 upsert-then-search 測試（既有測試只覆蓋 delete 路徑，不覆蓋 upsert 路徑）。
- [x] 4.5 state 遺失的處置：DB 存在而 state 無法可靠讀取時丟出 `stateUnreadable`（該錯誤目前宣告了但從未被丟出）要求 full rebuild；`discardDerivedArtifacts` 的刪除失敗必須終止而非 `try?` 吞掉；查詢端在 state 讀不到時拒答而非假裝沒有新內容。Behavior：`--full` 保證真的從零開始。Verify：state 損壞後 build 與 query 各自的行為測試。

## 5. 守衛與輸入驗證

- [x] 5.1 統一服務建構路徑，實現 design decision "The shipped path and the test path stop diverging"，對應 requirement "Roots are containment-checked before anything is created" 的條款 "The CLI and its tests SHALL construct the service through the same code path"：移除只有 production 用的 `LTMService.standard` 死碼，CLI 與測試共用同一個以 roots 參數化的建構子。Behavior：出貨的 containment policy 真的被測試執行到。Verify：至少一條測試走出貨守衛而非注入的 stub。
- [x] 5.2 建立前先檢查 containment，實現 "Roots are containment-checked before anything is created" 與 "Containment follows an overridden corpus root"：memory root 與 derived root 在任何 `createDirectory` 之前都對**當下使用中的**語料根做檢查。Behavior：`LTM_MEMORY_ROOT` 指進語料時非零結束且語料下沒有任何目錄被建立；`LTM_CORPUS_ROOT` 與 `LTM_DERIVED_ROOT` 指向同一處時被拒。Verify：兩條 CLI 測試，各自斷言「沒有東西被建立」而不只是「回了錯誤」。
- [x] 5.3 `--k` 驗證，實現 "Numeric options are validated before use"：範圍 1…1000，越界或非數值都非零結束並指名範圍，不得靜默改用預設。Behavior：`--k -1` 不再以 stdlib precondition 中止行程。Verify：負值與非數值兩條 CLI 測試。
- [x] 5.4 SQLite 綁定改用明確 byte 長度：`sqlite3_bind_text` 傳入 UTF-8 byte count、讀取用 `sqlite3_column_bytes`，修正內嵌 NUL 造成的截斷。Behavior：含內嵌 NUL 的文字，其索引內容與 anchor 的 contentHash 一致。Verify：內嵌 NUL 的 round-trip 測試。

## 6. 測試證明力與誠實邊界

- [x] 6.1 換掉不會失敗的測試：RRF 測試改為呼叫 `search()` 而非在測試檔內重算公式；隱私測試的斷言改為真正出現在事件檔內的字串；revision 作廢測試的 stub 輸出必須依賴 revision。Behavior：每條被指認為恆真的測試，在其所述行為被刻意破壞時會失敗。Verify：逐條刻意破壞一次確認測試轉紅（結果記入 PR 描述或 commit message）。
- [x] 6.2 CLI 測試隔離真實 HOME：測試行程不得因為環境變數缺漏而落到使用者的真實語料或真實 `~/.claude-ltm/`。Behavior：測試在任何機器上都只碰臨時目錄。Verify：測試在 `HOME` 被指向臨時目錄時仍全綠。
- [x] 6.3 清除誠實邊界違規：移除 design.md 未指名量測的效能宣稱；修正把 `docs/measurements/2026-08-10-fts5-tokenizer.md` 的數字引到它沒有涵蓋的比較上的註解；補正所有與程式碼相反的註解（提交順序、守衛範圍、尾行重讀、`Segmentation.cjkTokens` 宣稱放進輸出但未放）。Behavior：repo 內每個效能數字都能指名一份涵蓋該比較的紀錄。Verify：對照 `docs/measurements/` 逐條檢查並在 PR 描述列出。

## 7. 文件

- [x] 7.1 更新 README 與 CLAUDE.md 的行為描述，使其與修正後的行為一致：band 的語意、turn 去重、`--strategy` 不再需要 `--record`、舊索引需要 `ltm build --full`。Behavior：文件所述與 CLI 實際行為一致，且不含任何無量測支撐的效能宣稱。Verify：對照 design.md 的 Implementation Contract 逐項核對。

## 8. round-2 verify 的補做（2026-08-18）

上面的勾勾在第一次打上時**有兩個是假的**。`/idd-verify #24` 第二輪抓到，這一節
記錄補做了什麼——保留這段而不是默默改掉勾勾，因為「勾勾曾經是假的」本身是
這個 change 最該被記住的事實。

- [x] 8.1 **2.3 的事件層那一半從未實作。** 索引層的拒絕有實作也有測試，事件層
  兩者皆無——而 requirement 講的正是事件層。`anchorSourceRule` 在 LTMMemory 與
  LTMMemoryTests 是零命中，Verify 欄卻寫著一個不存在的測試。補上
  `ProjectFingerprint.hasCurrentRuleShape` 與 `EventStoreError.supersededAnchorRule`
  （具名到行號），三條 LTMMemoryTests。
- [x] 8.2 **3.1 的 band 改動讓 `ltm query` 直接失敗。** 通道數 band 與 RRF 分數
  不單調相關，而候選仍按分數降冪送進 seam → `bandsOutOfOrder`，真實語料 15 個
  查詢中 1 個炸掉。加 `LTMService.layered(_:)` 依 `(band, fusedRank)` 排序。
  回歸鎖含 `unlayeredCandidatesAreRejectedBySeam`，證明主要那條不是恆真式。
- [x] 8.3 **4.2 只修了兩個寫者中的一個。** `refreshIncrementally` 仍是舊順序，
  也沒有 `truncateSidecar`。修法不是照抄順序而是**刪掉那份平行實作**、委派
  `IndexBuilder`——兩個寫者就是兩份會漂移的規格。
- [x] 8.4 **4.2 的「絕不補零後續寫」沒有實作。** `truncateSidecar` 對較短的檔案
  呼叫 `ftruncate` 正是補零延長（POSIX）。改成只縮不長，比宣稱短就丟具名的
  `sidecarShorterThanDeclared`。原本那條側車測試拆成兩條，分別鎖住兩道守衛
  守的**不同執行路徑**（持鎖時續讀整段跳過，建置端那道不會跑）。
- [x] 8.5 **2.2 的去重與刪檔作廢交互作用會刪掉還存在的 turn。** 兩個機制各自
  正確：去重把同一則 turn 收斂成一列，作廢刪掉消失來源的 chunk。但
  `chunks.source_key` 是一個欄位，而「這個 chunk 來自哪裡」是多對多。改成
  `chunk_sources` 連結表，只有失去最後一個持有者的 chunk 才真的刪掉。
  layoutVersion 2 → 3。
- [x] 8.6 **`unreadableSources` 算出來但沒有消費者**，而 spec 寫 SHALL be
  reported。加進 `BuildReport` 並由 CLI 印出——不作廢就必須說出來，否則索引
  少了這些檔的新內容而使用者看到一次成功的建置。

**未在本 change 處理、已開 follow-up**：sessionId「最近觀察到」的代理指標在
真實語料裡永遠平手（見 issue）；目錄列舉失敗被當成來源消失；`FileEventStore`
自己的語料根守衛只認固定預設；數條測試的判準仍過寬。

## 9. round-3 verify 的補做（2026-08-18）

- [x] 9.1 **不變式 2 從個案改成性質**。三輪裡有四個 findings 是同一條不變式的不同
  破法，四次都靠人臨場想到反例。`Tests/LTMIndexTests/IncrementalEquivalenceTests.swift`
  隨機生成語料變異序列（建立／改寫／追加／刪除／resume），增量與全量重建比對
  可觀察狀態。首次執行 24/24 種子失敗。
- [x] 9.2 **FTS 寫入改成冪等**。`insert` 只在文字有變時刪 FTS 列卻無條件往下插，
  於是同一則 turn 出現在多個來源時 postings 被加第二次——全域文件計數多算，
  而 bm25 的 idf/avgdl 是全域統計。實測 base `d6463ad` 與 HEAD 逐字相同，所以這是
  去重（task 2.2）引入的，不是 `chunk_sources`。
- [x] 9.3 **導航欄位改由 `chunk_sources` 重算**。`session_id` / `timestamp` 是
  「還被哪些來源持有」的函數。先前由 upsert 的 CASE 決定，於是一個來源被刪掉後
  值凍結在已不存在的檔案上。平手規則（時間戳相同時取 source key 最小者）——**此句已於 2026-08-22 由 #25 作廢**：那個方向後來被 `b5c099a` 改成 DESC、再於 layout 5 整條移除（session 不再有代表值），而「順帶解決 #25」的說法本身也已在 issue #25 上具名撤回（它只涵蓋決定性，不涵蓋正確性）——原文順帶讓
  #25 有了明確答案。layoutVersion 3 → 4。
- [x] 9.4 **band 分層從 facade 搬進 `RetrievalEngine`**。retrieval spec 的
  「SHALL NOT reorder outside that seam」是本 change 從未修改的既有 requirement，
  而 facade 的 `layered()` 正是在 seam 之外重排。分帶與排帶屬於檢索——seam 的
  前置條件 `requireBandsInOrder` 要求候選到達時已分好帶。同時把截斷改成走同一個
  順序（先前選集用融合分數、顯示用 band，兩個判準）。
- [x] 9.5 **band 分層在生產路徑上的回歸鎖**。先前三條測試全測在 helper 上，把
  `query()` 裡呼叫 `layered` 那一行整行刪掉、293 個測試全綠。改成在**刻意構造的
  跨帶反轉語料**（55 則；純融合序的反轉落在第 35 位）上鎖 `query()` 的輸出，並
  分別對「不排」與「用分數截、用 band 排」兩種錯法驗過會紅。
- [x] 9.6 **`ScoredChunk.fusedRank` 更名 `emittedRank`、新增 `band`**。輸出順序是
  band-major 之後，「融合名次」這個名字裝的已經不是那個意思。band 規則收斂成
  `ScoredChunk.band(matching:)` 單一定義處。
- [x] 9.7 **刪掉一條不可能失敗的測試**（`queryOutputBandsAreNonDecreasing`）。它的
  語料上不可能出現跨帶反轉，把引擎排序整個拿掉照樣綠。不可能失敗的測試比沒有測試
  更糟——它在覆蓋率與閱讀上都算數。
- [x] 9.8 **`defaultStrategyLeavesRetrievalOrderIntact` 改成真的比對兩份順序**。
  它的名字一直宣稱「順序等於純檢索順序」而斷言只有 displacement 與 band 值域；
  位移為零是策略對自己行為的自述，見證不到呼叫端做的重排。

## 10. round-3 verify 的其餘 findings（2026-08-18）

- [x] 10.1 **`truncateSidecar` 的守衛被 `fileExists` 早退整個繞過**。「側車檔整個
  不見」是「向量真的不見了」的極端情形，卻是唯一沒被涵蓋的：`vectorRow` 仍從
  `vector_count` 起算、`appendVectors` 重建新檔，舊 chunk 的 `vector_row = 0`
  於是指到新檔第 0 列——**A 的相似度用 B 的向量算**，而 CLI 印「✓ 索引完成」。
  改成 `rows == 0` 才允許早退。
- [x] 10.2 **`supersededAnchorRule` 回報的是事件序號不是檔案行號**。空行每出現
  一次就讓後面的行號往前偏一位，而同一個偏移在 `corruptLines` 上已經修過一次
  （#1 verify R5），也有測試在守。改成逐行掃描時記錄真實行號。
- [x] 10.3 **兩條讀取路徑都不得把舊規則 anchor 原樣交出去**。spec 的條款主語是
  reading 而不是某一個方法，而 `allEvents(skippingCorrupt:)` 先前完全不檢查。
  參數更名 `skippingUnusable`（舊規則紀錄並不損壞，兩類分開回報）。
- [x] 10.4 **加 `ltm memory` 修復命令**。先前的錯誤訊息指名不出補救方式，因為
  修復路徑只有測試在呼叫、沒有任何使用者可達的入口——而 anchor 規則換代後，
  任何在換代前寫過事件的人第一次用會讀歷史的策略就必然撞上。一個必然觸發又沒有
  出路的錯誤，實際效果等同「歷史從此鎖死」。`--prune` 先備份再原子替換。
- [x] 10.5 **`EventStoreError` 在 CLI 有 handler 了**。先前以裸 enum 逸出。
- [x] 10.6 **查詢路徑不再丟掉診斷資訊**。委派之後它跑的是與 `ltm build` 完全
  相同的那段掃描，所以「走 build 會說出讀不到哪些檔、走 query 一個字都不說」
  沒有任何理由——而 query 是使用者最常走的那條。`QueryOutcome.refresh` 帶回
  `sourcesUnreadable` / `skipped` / `sourcesInvalidated`。
- [x] 10.7 **「查詢路徑不可能觸發整份重建」從註解變成前置條件**。原本的推理有個
  洞：`query` 讀 stamp 時不持鎖，而 `build` 拿到鎖後會重讀；兩次之間若有另一個
  行程改了 `layout_version`，`discardDerivedArtifacts()` 會從查詢路徑刪掉 DB、
  側車與 state。`build(refusingFullRebuild:)` 讓那個前提可以被強制。
- [x] 10.8 **補上「300 檔 5,722 筆」的量測紀錄**。那個數字散在七處，是整個
  turn-identity 改動的承重證據，而 `docs/measurements/` 下沒有任何紀錄——不合
  誠實邊界。改成全語料量測（8,324 檔、12,488 筆、內容 100% 相同、98.9%
  sessionId 不同），記錄在 `docs/measurements/2026-08-18-resume-duplication.md`，
  七處全部改成引用它。

## 11. round-4 verify 的補做（2026-08-18）

- [x] 11.1 **測試用的 embedder 從 `String.hashValue` 換成 SHA-256 導出的種子**。Swift
  的 `Hashable` 每個 process 隨機種子化（實測同一字串三次得 49 / 973 / 727），所以
  任何依賴向量順序的測試都在不同執行之間變動。實測代價：舊 embedder 下把 band-major
  排序拿掉，`truncationFollowsTheSameOrderAsDisplay` **10 次只紅 5 次**——它不是偶爾
  失敗，是偶爾成功。修好後破壞 6/6 紅、正常 8/8 綠。同一條教訓
  `Sources/LTMEval/Interleaving.swift` 已經記過，沒有轉移過來。
- [x] 11.2 **平手規則的方向被我反轉了**。9.3 的註解宣稱「現在結果一樣，只是把副作用
  寫成規則」——實測 base 給 `b.jsonl`、改動後給 `a.jsonl`，**剛好相反**，而 spec 的
  Example 逐字要求指標報 `s-B`。改回 `source_key DESC` 並補上鎖住 Example 的測試
  （ASC↔DESC 互換時先前 301 個測試沒有一條會紅）。
- [x] 11.3 **`rewrite(keeping:)` 換成 `pruneUnusable()`**。前者有兩個問題：它不取
  `append` 的 `flock`、且用 temp+rename 落地會**換掉 inode**（實測：持鎖者的後續
  write 落進已 unlink 的舊 inode，資料無聲消失）；而且它是「刪掉任意一筆事件」的
  公開 API，與 append-only requirement 正面衝突。新形狀在同一個 fd 的 `LOCK_EX` 內
  完成讀→篩→寫、就地覆寫不換 inode，篩選規則寫死在 store 裡。
- [x] 11.4 **`ltm memory` 補上語料 containment 驗證**。它會寫（備份與就地覆寫）卻
  不建 `LTMService`，所以拿不到 `make()` 那道守衛——實測會把 canonical 檔寫進語料根。
- [x] 11.5 **診斷資訊補到零命中與 `--json` 兩條路徑**。`printHuman` 在零命中時
  early return，而零命中正是「讀不到的來源」最需要被說出來的那一刻。`--json` 走
  stderr（spec 逐字要求 stdout 是 JSON 陣列）——**誠實邊界：這只解決「不沉默」，
  沒解決「機器讀得到」**，後者是 Stage 2 的介面決定。
- [x] 11.6 **`refusingFullRebuild` 的生產接線有測試了**。先前只測被呼叫者，把 facade
  傳的 `true` 改成 `false` 全綠。用 revision 會在第二次讀取時改變的 embedder 模擬
  TOCTOU，從 facade 進入。
- [x] 11.7 **`ltm memory` 與修剪操作補上 spec**。先前零 requirement 覆蓋，且與已歸檔
  的「The event store is append-only … SHALL NOT expose an operation that updates or
  deletes an individual event」直接衝突。MODIFIED 那條寫明唯一例外的邊界（只能刪
  讀不回來的、不得接受呼叫端指定、鎖內完成、不得換 inode），ltm-cli 補三條 scenario。
- [x] 11.8 **量測腳本進 repo**（`scripts/measure-resume-duplication.py`），紀錄補上
  語料快照的說明——語料每天在長，應該對照的是比例不是絕對數字。`CorpusScannerTests`
  殘留的舊抽樣數字 4,337 一併清掉。
- [x] 11.9 **刪掉一條不可能失敗的測試**（`pruneDoesNotSwallowConcurrentAppends`）。
  新簽章沒有參數可以交進過期清單，所以那個回歸在型別上不可達；實測把寫入依據換成
  鎖外快照它照樣綠。真正在守它的是簽章與鎖，型別層的保證比測試強。

**未做、已記錄**：`--json` 的機器可讀診斷通道（需要改輸出形狀，屬 Stage 2）；
真正的並發修剪測試（時序相依，本 repo 已為此付過代價）。
