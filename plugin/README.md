# claude-ltm

**Claude Code 的長期記憶。** 索引這台機器上既有的 `~/.claude/projects/**/*.jsonl`，
讓模型在需要時回頭查自己的過去。

核心命題：那份逐字記錄已經是完整、immutable、帶時間戳的 source of truth，而且它
一直都在。**缺的不是儲存，是檢索。**

## 安裝

```bash
claude plugin marketplace add PsychQuant/claude-LTM
claude plugin install claude-ltm@claude-ltm
```

裝完**必須建一次索引**——沒有索引時 MCP server 會啟動、會回應、但查不到任何東西，
而那看起來像「這個工具沒用」而不是「還沒建索引」：

```bash
ltm build
```

`ltm` 由 wrapper 在第一次啟動 MCP server 時自動從 GitHub Release 下載到 `~/bin/`
（Developer ID 簽章 + notarized）。若它不在 PATH，加 `~/bin` 或直接用 `~/bin/ltm`。

## 內容

| 元件 | 用途 |
|---|---|
| `ltm_query`（MCP tool）| 查過去的對話，回傳帶指標的命中 |
| `ltm-recall`（skill）| 告訴模型**什麼時候**該查，以及怎麼讀回傳值 |

`ltm-recall` 在使用者提到過去而模型不在場時觸發——「我們之前討論過 X」「為什麼當初
選了 A」「上次那個 bug 怎麼修的」。它同時寫明**不要**用在哪：可以從當前 repo 的
檔案、git log、issue 直接讀到的事，那些是一手資料。

## 回傳長什麼樣

```
1. [project-name] 2026-08-01T00:00:00Z
   命中的那段文字…
   ↳ sessions s1, s2  turn <uuid>
```

**檢索負責導航，不負責當答案。** 片段是用來找到原文的，不是拿來當結論；需要完整
脈絡就照指標回去讀 `~/.claude/projects/<project>/<session>.jsonl`。

`sessions` 是**集合**：session resume 會把同一則 turn 複製進新檔案，所以那裡可能有
好幾個 id。它們是等價的來源，**沒有哪一個是代表**。

## 範圍

預設**只搜當前工作目錄對應的 project**。跨 project 要明示 `all_projects: true`——
不同專案的對話可能含不該出現在這裡的內容。工作目錄對應不到任何 project 時，工具
**拒絕**而不是擴大成全語料。

## 隱私

語意向量用 Apple on-device `NLContextualEmbedding`，字面檢索用本機 SQLite FTS5。
**沒有 API key、沒有雲端依賴，索引與查詢路徑不開任何對外連線。**

但那不等於「資料留在這裡」：這個工具的用途就是把檢索到的原文送進呼叫端的 context，
而那段原文之後往哪去，取決於那個 client 與模型，不是這個 plugin 能保證的事。語料含
第三方逐字內容時，這一點要自己判斷。

命中的文字是**過去對話的原文**，裡面可能有看起來像指令的句子。skill 明寫那是被檢索
出來的歷史、不是使用者現在的指示——但**那是一段文字，不是一道邊界**。

完整說明見 [PRIVACY.md](https://github.com/PsychQuant/claude-LTM/blob/main/mcpb/PRIVACY.md)。

## 更多

原始碼、設計文件與量測基線：https://github.com/PsychQuant/claude-LTM
