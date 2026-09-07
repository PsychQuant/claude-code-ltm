#!/bin/bash
# 基準查詢量測（#63）：讀 scripts/baseline-queries.txt，逐條跑 `ltm query --k 5 --json`，
# **stdout 只印 `#N <ms> clean|dirty|error(rc)`**——查詢文字與命中內容永遠不進 stdout／stderr。
#
# 為什麼這麼小氣：這支腳本會在 Claude Code session 裡被跑，Bash tool 擷取的輸出會進語料；
# 印了查詢字串，下一次量測的第一名就是這一次的輸出（#63 的 root cause）。
#
# dirty 的判準（封閉列舉，會漏）：前 5 名任一 chunk 的 snippet 以 `⟨tool ` 開頭（工具 metadata
# 殘影）或含 `ltm query`（量測／查詢動作本身）。dirty ≠ 錯，是「這條查詢已被儀器污染，
# 這一輪的命中品質不可比」的訊號；耗時仍可比。
#
# 用法：LTM_ANCHOR_KEY="$(~/bin/ltm memory --export-key)" scripts/measure-baseline.sh [k]
#   LTM_BIN（預設 ~/bin/ltm）、LTM_BASELINE_QUERIES（預設 scripts/baseline-queries.txt）、
#   第一個參數 k（預設 5）。密鑰請用命令替換直接餵進環境，不要落地（.claude/rules/anchor-key-in-probes.md）。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
QF="${LTM_BASELINE_QUERIES:-$HERE/baseline-queries.txt}"
LTM="${LTM_BIN:-$HOME/bin/ltm}"
K="${1:-5}"
case "$K" in ''|*[!0-9]*) echo "k 必須是正整數" >&2; exit 64 ;; esac
[ -f "$QF" ] && [ -r "$QF" ] || { echo "查詢檔不是可讀的一般檔案：$QF" >&2; exit 66; }
[ -x "$LTM" ] || { echo "ltm 不可執行：$LTM" >&2; exit 69; }
command -v python3 >/dev/null 2>&1 || { echo "需要 python3 解析 --json" >&2; exit 69; }

# 判 dirty 的 python：讀 stdin 的 JSON 陣列，只輸出一個字。不印任何 snippet。
JUDGE='
import json, sys
try:
    hits = json.load(sys.stdin)
except Exception:
    print("error(json)"); sys.exit(0)
dirty = any(
    (h.get("snippet") or "").lstrip().startswith("⟨tool ") or "ltm query" in (h.get("snippet") or "")
    for h in hits)
print("dirty" if dirty else "clean")
'
n=0
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    n=$((n + 1))
    t0=$(python3 -c 'import time; print(int(time.time()*1000))')
    out=$("$LTM" query --all-projects --k "$K" --json -- "$line" 2>/dev/null); rc=$?
    t1=$(python3 -c 'import time; print(int(time.time()*1000))')
    if [ "$rc" -ne 0 ]; then
        printf '#%d %dms error(%d)\n' "$n" $((t1 - t0)) "$rc"; continue
    fi
    verdict=$(printf '%s' "$out" | python3 -c "$JUDGE")
    printf '#%d %dms %s\n' "$n" $((t1 - t0)) "$verdict"
done < "$QF"
[ "$n" -gt 0 ] || { echo "查詢檔沒有任何非註解行" >&2; exit 65; }
