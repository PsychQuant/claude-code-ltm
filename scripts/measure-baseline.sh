#!/bin/bash
# 基準查詢量測（#63）：讀 scripts/baseline-queries.txt，逐條跑
#   ltm query --all-projects --k <k> --json -- <查詢>
# **stdout 只印 `#N <ms> <verdict>`**——查詢文字與命中內容不進 stdout／stderr，包含 `bash -x`
# （第一行就關掉 xtrace；ltm 與 judge 的 stderr 都丟掉）。
#
# 為什麼這麼小氣：這支腳本會在 Claude Code session 裡被跑。今天會進索引的是逐字稿裡的 `text` block
# （使用者輸入、Claude 的散文）與 tool_use 的七個 metadata 欄位（`CorpusScanner.toolMetadataFields`，
# 含 Bash 的 `command=`／`description=`、`ltm_query` MCP 工具的 `query=`）。Bash 的 stdout 是 tool_result、
# 今天不被索引——但 Claude 引述輸出的那句散文一定被索引。印了查詢字串，就等著被引述（#63 的 root cause）。
#
# verdict（封閉字母表，由 Tests/LTMMCPTests/BaselineQueryFileTests.swift 釘住；只有這幾個，不得類推）：
#   clean          前 k 名沒有下面兩種殘影。**不代表沒有別種污染**——判準是列舉，會漏（例如查詢原文
#                  被貼進對話的那則 turn，兩種殘影都不含）。真的要知道乾不乾淨，只能在 Claude Code
#                  之外的 shell 讀命中內容。
#   dirty          前 k 名任一 snippet 含 `⟨tool `（工具 metadata 殘影）或含 `ltm query`（量測／查詢動作本身）。
#                  dirty ≠ 錯，是「這條查詢的命中品質這一輪不可比」；耗時仍可比。
#   empty          零命中。查詢已經對不到任何東西——這不是 clean。
#   error(<rc>)    ltm 非零離開（rc 為數字；被訊號殺掉為 sig<N>）
#   error(exec)    ltm 起不來；error(json) 輸出不是 JSON；error(shape) JSON 不是物件陣列；error(judge) judge 自己掛了
# 任一列不是 clean／dirty／empty → 每列照印，最後以 1 離開。
#
# <ms>：ltm 行程 fork→exit 的 monotonic 牆鐘（含 process 啟動、查詢前的增量併入、檢索、輸出），
# 不含 judge。單一樣本、沒有暖身——第 1 列常帶冷啟動，比較各列前先看這點。跟舊紀錄的命令
# （`.build/release/ltm query "$q" --k 5`，單一 project、無 --json）量的不是同一件事，
# 不要把本腳本的列與 2026-09-01 之前的表對齊——見 docs/measurements/README.md。
#
# 用法（在 repo 根目錄）：LTM_ANCHOR_KEY="$(~/bin/ltm memory --export-key)" scripts/measure-baseline.sh [k]
#   LTM_BIN（預設 ~/bin/ltm）、LTM_BASELINE_QUERIES（預設 scripts/baseline-queries.txt）、k 1–1000（預設 5）。
#   密鑰請用命令替換直接餵進環境，不要落地（.claude/rules/anchor-key-in-probes.md）。
set +x
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
QF="${LTM_BASELINE_QUERIES:-$HERE/baseline-queries.txt}"
LTM="${LTM_BIN:-$HOME/bin/ltm}"
K="${1:-5}"
case "$K" in ''|*[!0-9]*) echo "k 必須是 1–1000 的整數" >&2; exit 64 ;; esac
[ "$K" -ge 1 ] && [ "$K" -le 1000 ] || { echo "k 必須是 1–1000 的整數" >&2; exit 64; }
[ -f "$QF" ] && [ -r "$QF" ] || { echo "查詢檔不是可讀的一般檔案：$QF" >&2; exit 66; }
[ -f "$LTM" ] && [ -x "$LTM" ] || { echo "ltm 不是可執行的一般檔案：$LTM" >&2; exit 69; }
command -v python3 >/dev/null 2>&1 || { echo "需要 python3 計時與解析 --json" >&2; exit 69; }

# 一條查詢一個 python：起 ltm、用 monotonic 計時、解析 --json、只印「<ms> <verdict>」。
# 不印任何 snippet；ltm 的 stdin 接 /dev/null（避免它吃掉查詢檔剩下的行）、stderr 丟掉。
RUN='
import json, subprocess, sys, time
ltm, k, query = sys.argv[1], sys.argv[2], sys.argv[3]
t0 = time.monotonic_ns()
try:
    p = subprocess.run([ltm, "query", "--all-projects", "--k", k, "--json", "--", query],
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
except OSError:
    print("0 error(exec)"); sys.exit(0)
ms = (time.monotonic_ns() - t0) // 1_000_000
rc = p.returncode
if rc != 0:
    print(f"{ms} error({rc})" if rc > 0 else f"{ms} error(sig{-rc})"); sys.exit(0)
try:
    hits = json.loads(p.stdout)
except Exception:
    print(f"{ms} error(json)"); sys.exit(0)
if not isinstance(hits, list) or not all(isinstance(h, dict) for h in hits):
    print(f"{ms} error(shape)"); sys.exit(0)
if not hits:
    print(f"{ms} empty"); sys.exit(0)
def snip(h):
    s = h.get("snippet"); return s if isinstance(s, str) else ""
dirty = any(("⟨tool " in snip(h)) or ("ltm query" in snip(h)) for h in hits)
print(f"{ms} " + ("dirty" if dirty else "clean"))
'
n=0; bad=0
while IFS= read -r raw || [ -n "$raw" ]; do
    # 「第 N 條非註解行」的定義與測試一致：去前後空白（[:space:] 含 CR）後，空行與 # 開頭的行都不算。
    line="${raw#"${raw%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|\#*) continue ;; esac
    n=$((n + 1))
    row=$(python3 -c "$RUN" "$LTM" "$K" "$line" 2>/dev/null) || row=""
    case "$row" in
        *' clean'|*' dirty'|*' empty') ;;
        *' error('*')') bad=$((bad + 1)) ;;
        *) row="0 error(judge)"; bad=$((bad + 1)) ;;
    esac
    printf '#%d %sms %s\n' "$n" "${row%% *}" "${row#* }"
done < "$QF"
[ "$n" -gt 0 ] || { echo "查詢檔沒有任何非註解行" >&2; exit 65; }
[ "$bad" -eq 0 ] || exit 1
