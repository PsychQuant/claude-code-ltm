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

`~/.claude-ltm/memory/ltm.sqlite`（retrieval history、strength、links、pins）記的是
**jsonl 記不得的事**——使用歷史。它不適用第 2 條，但受一條獨立硬約束：

> **只存指標與統計，不存 chunk 原文。**

如此它即使被備份或同步也不含第三方逐字內容。**這條靠 schema 保證，不靠自律**；
新增欄位時若要存文字，先問這條。

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

## 工作流程

本專案走 IDD（issue-driven development）：先開 issue、診斷、實作、驗證，commit 引用 `#N`。
設計討論走 Spectra／superpowers 的 spec 流程，spec 落在 `docs/superpowers/specs/`。

## 誠實邊界

目前沒有評估集。在累積出一組 `(查詢, 應命中的 turn)` 之前，**任何「策略 X 比較好」
的說法都沒有根據**，包括文件裡的推薦。不要在 commit message 或文件裡寫沒量過的效能宣稱。
