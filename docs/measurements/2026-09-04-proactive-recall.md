# 主動回想 hook 的成本量測（proactive-recall-cued-hook，#64）

**日期**：2026-09-04。**機器**：M5 Max、128 GB。**binary**：本 change 的 `.build/release/ltm`
（release 建置，含 `--format recall`／`--exclude-session`／`--max-refresh-seconds`）。**索引**：
真實的 `~/.claude-ltm/derived`（約 64 萬 chunk；本 session `3a2ceb7e…` 佔 19,945 個）。
**anchor 密鑰**：由 `~/bin/ltm memory --export-key` 匯出到環境，不碰鑰匙圈
（`.claude/rules/anchor-key-in-probes.md`）。樣本數逐節標示（§1 的 hook 計時 n=20–30，§3 的命中率
每個 project 取最後 200 則），都是單機。

**本紀錄不宣稱任何「回答變好」**——沒有評估集（#33），量得到的只有延遲、context 成本、
命中率與落後次數。

## 1. hook 每輪牆鐘時間（R2 重構後）

**這一節在 verify R2 之後重量。** R2 之前的 hook 對**每一則** prompt 都跑 python 抽欄位、且把它包進
0.1 s 輪詢的守衛，未命中輪次因此被進位到 ~175 ms、越過規格的 100 ms（verify R2 logic N2）。重構後
**cued 模式先用便宜的 raw grep 擋一次**，未命中就直接退出、不啟動 python；python（剝
system-reminder、取 session/cwd/shape）只在 raw grep 命中的候選或 always 模式跑，守衛輪詢改 0.05 s。

驅動：`printf '{"session_id":…,"cwd":…,"prompt":…}' | plugin/hooks/ltm-recall-gate.sh`，
`CLAUDE_PLUGIN_ROOT` 指向 `plugin/`，計時含 bash 啟動；由 Python `subprocess` 連跑取 p50/max。

| 情境 | n | p50 | max | 說明 |
|---|---|---|---|---|
| 閘門未命中（prompt「幫我改這個函式」，raw grep 擋下、不跑 python） | 30 | **21 ms** | 26 ms | 規格 100 ms 上限有大餘裕；比 R1 出貨版（48 ms）與 R1-fix 版（175 ms）都低 |
| 命中候選（raw grep 命中 → python 抽欄位 → `LTM_BIN` 缺→通知） | 20 | **98 ms** | 104 ms | python 抽欄位的開銷約 77 ms，只在候選輪次付 |
| 命中且真的查詢 | — | — | — | 未在此節重量；命中查詢 ≈ `ltm query` 穩態（2026-09-03 §另記 p50 1.12 s），hook 只多守衛輪詢 |

- 未命中是絕大多數輪次（§3 命中率 0–2%），所以每輪的**期望**成本接近 21 ms。
- 命中候選裡還有一部分會被 python 對剝過的 prompt 再 grep 一次濾掉（system-reminder 內的線索），
  那些輪次付了 ~98 ms 卻不查詢——這是 raw grep 過近似的代價，換來未命中路徑不碰 python。
- **誠實邊界**：命中且真的跑查詢的那條路徑（含有界併入、排除後 refetch）沒有在交付版上重量；
  它與 `ltm query` 穩態同量級，但「hook 為自己設 `LTM_BUILD_BATCH_CHUNKS=200`＋守衛輪詢」的精確
  疊加成本沒有數字。要量的話設 `LTM_RECALL_STATS_FILE` 記結果標籤、再對 hit 輪次計時。

## 2. 併入預算的粒度（為什麼 hook 要設 200 一批）

第一版量測**二十輪全部逾時**（21.5 s，一行通知）：`--max-refresh-seconds 15` 的判定只在批次
邊界，預設 2,000 chunk 一批；本機嵌入速度由 2026-09-03 的 build 推得 11,935 chunk／152 s
≈ **78 chunk/s**，所以第一個邊界在 ~25 s 之後——預算永遠等不到。改成 200 一批（~2.6 s）後
逾時歸零，一輪最多併入約五批，大 backlog 跨幾輪回想慢慢消化。判準寫進 design decision 3。

## 3. 閘門命中率（線索表對使用者真正打字的 prompt）

**這一節在 verify R1 之後整段重寫。** 第一版的母體錯了：它把 `~/.claude/projects/<project>/*.jsonl`
裡所有 `type == "user"` 的紀錄都當成「prompt」，只靠文字前綴排除系統產生的形狀。那個母體混進了
subagent／headless 的 prompt（例如 76 則逐字相同的 review 模板，樣板文字含「先前」）與 slash 展開，
命中率因此被灌到 9–38%，而且那些數字**無法用文字前綴重現**——換一組前綴就換一組數字。

正確的母體鍵是紀錄上的 **`promptSource`** 欄位（Claude Code 對每則 user 紀錄標記來源：`typed`／
`sdk`／`system`／`queued`／`suggestion_accepted`；舊紀錄與 tool_result 紀錄沒有這個欄位）。
母體＝`promptSource == "typed"`、剝掉 `<system-reminder>`、依 timestamp 取最後 200 則；再套 hook
的五個前綴排除；對 `plugin/hooks/recall-cues.txt` 逐條 ERE 比對（Python `re`，與 hook 的
`grep -E` 語法在這份線索表上等價——線索表沒有用到兩者有差的語法）。

| project | `typed` 總數 | 母體（最後 N 則） | 前綴排除 | 命中 | 命中率 |
|---|---|---|---|---|---|
| `-Users-che-Developer-Akashic-Library` | 591 | 200 | 0 | 2 | 1.0% |
| 同上 worktree 分身（`…idd-cluster-253-254…`） | 41 | 41 | 0 | 0 | 0.0% |
| `…teaching-educator` | 691 | 200 | 0 | 4 | 2.0% |
| `-Users-che-Developer-claude-code-ltm`（本 repo） | 70 | 70 | 0 | 1 | 1.4% |

命中的線索合計：`之前` 3、`記得` 2、`過去` 2、`recall` 1；其餘 0。四個 project 的 `promptSource`
分佈裡 `typed` 佔 user 紀錄的 2–5%，其餘是 `(absent)`（舊紀錄與 tool_result）、`sdk`、`system`。

**兩個推論，各有邊界**：

- 線索表對真正打字的 prompt 命中 0–2%，比第一版宣稱的低一個量級。這是「閘門很少開」，**不是**
  「閘門開得對」——沒有評估集，命中的那幾則是不是真的在指過去，沒有量。
- 五個前綴在 `typed` 母體裡排除掉 **0** 則：它們針對的是 `system`／`sdk` 來源的 prompt。hook 看不到
  `promptSource`（hook 輸入沒有這個欄位），文字前綴是它唯一的把手；`sdk` 來源的 prompt（`claude -p`、
  Agent SDK）**會不會**經過 `UserPromptSubmit` hook，本紀錄沒有量——它們的模板含「先前」，若會，每個
  headless review 都會多跑一次查詢（約 1 s）與一行通知。要量實際放行率，設 `LTM_RECALL_STATS_FILE`，
  hook 會逐次寫 `<unix 秒> <off|synthetic|miss|hit|notice>`（只有封閉集合的標籤，沒有文字）。

查法（整段可重跑；只讀 `~/.claude/projects`）：

```python
# 閘門命中率的查法（docs/measurements/2026-09-04-proactive-recall.md §3）。只讀 ~/.claude/projects，不寫。
# 母體＝ promptSource == "typed" 的 user 紀錄（Claude Code 自 2026 中起在每則 user 紀錄標記來源：
# typed／sdk／system／queued；沒有這個欄位的舊紀錄與 tool_result 紀錄不進母體）。
import json, re, sys, glob, os, collections
cues = [l.strip() for l in open(sys.argv[1], encoding="utf-8") if l.strip() and not l.lstrip().startswith("#")]
pats = [re.compile(c) for c in cues]
SYN = ("Base directory for this skill", "This session is being continued", "(Re-invocation of", "Stop hook feedback:")
def records(project):
    src = collections.Counter(); typed = []
    for f in glob.glob(os.path.expanduser(f"~/.claude/projects/{project}/*.jsonl")):
        for line in open(f, encoding="utf-8", errors="replace"):
            try: d = json.loads(line)
            except Exception: continue
            if d.get("type") != "user": continue
            src[d.get("promptSource", "(absent)")] += 1
            if d.get("promptSource") != "typed": continue
            c = (d.get("message") or {}).get("content")
            if isinstance(c, list): c = "\n".join(b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text")
            if not isinstance(c, str): continue
            c = re.sub(r"<system-reminder>.*?</system-reminder>", "", c, flags=re.S)
            head = c.lstrip()[:40]
            gate_synthetic = head.startswith("<") or any(head.startswith(p) for p in SYN)
            typed.append((d.get("timestamp", ""), gate_synthetic, c))
    typed.sort(key=lambda t: t[0])
    return src, typed
for project in sys.argv[2:]:
    src, typed = records(project)
    last = typed[-200:]
    admitted = [p for p in last if not p[1]]
    hits = [p for p in admitted if any(r.search(p[2]) for r in pats)]
    per = collections.Counter(c for p in admitted for i, c in enumerate(cues) if pats[i].search(p[2]))
    print(f"{project}\n   promptSource 分佈：{dict(src)}\n   最後 {len(last)} 則 typed：閘門的前綴排除掉 {len(last)-len(admitted)}，放行 {len(admitted)}，命中 {len(hits)}（{100*len(hits)/max(1,len(admitted)):.1f}%）\n   命中線索：{dict(per)}")
```

呼叫：`python3 hitrate.py plugin/hooks/recall-cues.txt <project 目錄名…>`。

## 4. 基線（重述，#64 diagnosis）

本 repo 之外，2,313 個 session 檔中真正的 `ltm_query` tool_use 為 **0**——先前算出的 44 是工具名
出現在 deferred-tools 清單訊息裡，不是呼叫。

## 誠實邊界

- 單機、單日、n=20；沒有負載對照；索引是活的（量測期間本 session 自己的 jsonl 也在成長）。
- 命中率的四個 project 都是使用者自己的語料，不代表別人的用語；線索表本來就是列舉。`typed` 母體最多 200 則、
  一個 project 只有 41 則，命中 0–4 則——分母小到任何一則都能移動百分比，這些數字只支持「很低」，不支持比較。
- 量測用的查詢字串已進本 session 的 transcript，之後同字串的查詢會先召回這裡（#63）。
- `all_projects` 未量；`always` 模式未量（開關存在，數字沒有）。
- 沒有任何一個數字能說「回答變好」。
