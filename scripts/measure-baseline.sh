#!/bin/bash
# 基準查詢量測（#63）：讀 scripts/baseline-queries.txt，逐條跑
#   ltm query --all-projects --k <k> --json -- <查詢>
# **stdout 只印 `#N <ms> <verdict>`**——查詢文字與命中內容不進 stdout／stderr，包含 `bash -x`、
# `SHELLOPTS=xtrace`、`BASH_ENV`（第一行就關掉 xtrace；ltm 與 judge 的 stderr 都丟掉）。
#
# 為什麼這麼小氣：這支腳本會在 Claude Code session 裡被跑。今天會進索引的是逐字稿裡的 `text` block
# （使用者輸入、Claude 的散文）與 tool_use 的七個 metadata 欄位（`CorpusScanner.toolMetadataFields`，
# 含 Bash 的 `command=`／`description=`、`ltm_query` MCP 工具的 `query=`）。Bash 的 stdout 是 tool_result、
# 今天不被索引——但 Claude 引述輸出的那句散文一定被索引。印了查詢字串，就等著被引述（#63 的 root cause）。
#
# verdict（封閉字母表，由 Tests/LTMMCPTests/BaselineQueryFileTests.swift 釘住；只有這幾個，不得類推）：
#   clean tool=<n>   前 k 名沒有任何一個 snippet 含**這條查詢的原文**（空白摺疊後的子字串比對）。
#   self  tool=<n>   前 k 名至少一個 snippet 含這條查詢的原文——儀器看見了自己（量測命令列、
#                    `ltm_query query=…`、被引述的那句散文，都是這個形狀）。這一輪該條的命中品質不可比；
#                    耗時仍可比。
#   empty tool=0     零命中。查詢已經對不到任何東西——這不是 clean。
#   error(<rc>)      ltm 非零離開（rc 為數字；被訊號殺掉為 sig<N>）
#   error(exec)      ltm 起不來；error(json) 輸出不是 JSON；error(shape) JSON 不是物件陣列；error(judge) judge 自己掛了
# `tool=<n>` 是前 k 名裡含 `⟨tool ` 的 snippet 數（工具 metadata chunk）。它**不是**污染訊號——工具
# metadata chunk 佔語料的比例高到「前 k 名有一個」幾乎恆真（#67），拿它當 dirty 會讓每一列都不可比；
# 它是 #62（self-hit 的檢索層排除）要移動的那個量的觀察值，印出來給 #62 的前後比較看。
# 第一版的判準是「含 `⟨tool ` 或含 `ltm query`」，#63 verify 的 devil's-advocate 指出它量的是
# 「前 k 名有沒有工具 chunk」而不是「這條查詢被自己污染了沒有」；現在的 self 是把命中拿去跟查詢比對。
# 任一列是 error(…) → 每列照印，最後以 1 離開。
#
# `self` 會漏什麼：查詢原文超過 metadata 欄位的 200 字元截斷之後才出現的那種命令（那段文字根本
# 不在索引裡，所以也不會靠它排名）；以及語料裡本來就逐字含這串字的**實質** turn——那不是污染，
# 是正常召回，但 self 分不出來。要分，只能在 Claude Code 之外的 shell 讀命中內容。
#
# <ms>：ltm 行程 fork→exit 的 monotonic 牆鐘（含 process 啟動、查詢前的增量併入、檢索、輸出），
# 不含 judge。單一樣本、沒有暖身——第 1 列常帶冷啟動，比較各列前先看這點。跟舊紀錄的命令
# （`.build/release/ltm query "$q" --k 5`，單一 project、無 --json）量的不是同一件事，
# 不要把本腳本的列與 2026-09-01 之前的表對齊——見 docs/measurements/README.md。
#
# 用法：LTM_ANCHOR_KEY="$(~/bin/ltm memory --export-key)" scripts/measure-baseline.sh [k]
#   LTM_BIN（預設 ~/bin/ltm）、LTM_BASELINE_QUERIES（預設本腳本旁的 baseline-queries.txt，不依賴 cwd）、
#   k 1–1000（預設 5）。密鑰請用命令替換直接餵進環境，不要落地（.claude/rules/anchor-key-in-probes.md）。
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
    print(f"{ms} empty tool=0"); sys.exit(0)
def snip(h):
    s = h.get("snippet"); return s if isinstance(s, str) else ""
def norm(s):
    return " ".join(s.split())
tool = sum(1 for h in hits if "⟨tool " in snip(h))
q = norm(query)
selfhit = bool(q) and any(q in norm(snip(h)) for h in hits)
print(f"{ms} " + ("self" if selfhit else "clean") + f" tool={tool}")
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
        *' clean tool='*|*' self tool='*|*' empty tool=0') ;;
        *' error('*')') bad=$((bad + 1)) ;;
        *) row="0 error(judge)"; bad=$((bad + 1)) ;;
    esac
    printf '#%d %sms %s\n' "$n" "${row%% *}" "${row#* }"
done < "$QF"
[ "$n" -gt 0 ] || { echo "查詢檔沒有任何非註解行" >&2; exit 65; }
[ "$bad" -eq 0 ] || exit 1
