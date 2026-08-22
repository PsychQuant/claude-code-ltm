# Changelog

本檔記錄非衍生性、對讀者有意義的變更（doc comment、API、架構）。純衍生物（索引、測試覆蓋率報告）不記。

## Unreleased

### Added
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
