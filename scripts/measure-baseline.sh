#!/bin/bash
# 基準查詢量測（#63）：讀 scripts/baseline-queries.txt，逐條跑
#   ltm query --all-projects --k <k> --json -- <查詢>
# **stdout 第一行是 `set sha256:<12 hex> k=<k>`（非註解行內容的指紋與這次的 k——查詢集一換，指紋就換；
# verdict 全是「前 k 名」的性質，k 不同也不可比；紀錄要連這一行一起引，兩次量測這一行不同就不能逐列對齊，
# `#N` 只是檔內位置），之後每列 `#N <ms>ms <verdict>`**（例如
# `#3 812ms clean tool=1`；`<ms>` 是整數毫秒，後面緊接字面 `ms`）。
# 查詢文字與命中內容不進 stdout／stderr，包含 `bash -x`、
# `SHELLOPTS=xtrace`、`BASH_ENV` 裡的 `set -x`（第一行就關掉 xtrace；ltm 與 judge 的 stderr 都丟掉）。
# 擋不住的：`BASH_ENV`／`PS4` 裡刻意放一個會讀查詢檔的命令替換——trace 第一行 `set +x` 時 PS4 先展開；
# 或 PATH 上的 python3 被換成會印檔案的東西。這份例外會漏，判準是「這個動作等不等同操作者直接 cat 查詢檔」
# ——那是操作者的動作不是本腳本的洩漏面；寫在這裡是因為上一句是全稱。
# 指紋揭露什麼：未加鹽的 sha256 前 48 bit。它不含查詢文字、跟查詢原文對不上（不會造成 self）；它能讓
# 持有一組候選的人**確認**一次完整猜測——持有舊集合的人可用它驗證退役後換掉的那一條。這個對手本來就
# 讀得到語料（jsonl 裡已有整組副本），所以不改變結論，但它是性質不是零。
#
# 為什麼這麼小氣：這支腳本會在 Claude Code session 裡被跑。今天會進索引的是逐字稿裡的純字串
# `message.content`（使用者鍵入的 prompt 常是這一種，整段）、`text` block（使用者輸入、Claude 的散文）
# 與 tool_use 的七個 metadata 欄位（`CorpusScanner.toolMetadataFields`，含 Bash 的 `command=`／
# `description=`、`ltm_query` MCP 工具的 `query=`）。Bash 的 stdout 是 tool_result、
# 今天不被索引——但 Claude 引述輸出的那句散文一定被索引。印了查詢字串，就等著被引述（#63 的 root cause）。
#
# verdict（封閉字母表；只有這幾個，不得類推。四處列舉——本檔頭的「error tokens」行、`ERROR_TOKENS`
# 變數、docs/measurements/README.md、測試的 errorTokens——與程式碼裡實際的 `error(...)` 輸出點由
# Tests/LTMMCPTests/BaselineQueryFileTests.swift 的同步測試逐一對應：程式碼裡**每一個** `error(` 都當
# 輸出點（valid_row 用變數 E_OPEN 比對、不寫字面，所以沒有任何一行被略過），寫成它認不出的形狀
# （字面 token、`{rc}`、`sig{-rc}` 以外）測試直接紅）：
#   clean tool=<n>   前 k 名沒有任何一個 snippet 含**這條查詢的原文**（空白摺疊、大小寫摺疊後的子字串比對）。
#   self  tool=<n>   前 k 名至少一個 snippet 含這條查詢的原文——儀器看見了自己（量測命令列、
#                    `ltm_query query=…`、被引述的那句散文，都是這個形狀）。這一輪該條的命中品質不可比；
#                    耗時仍可比。
#   empty tool=0     零命中。查詢已經對不到任何東西——這不是 clean，但也不計入離開碼。
#   error(<token>)   這一列沒量到。token 是下面這一行的封閉集合：
#   error tokens：<rc> sig<N> blank exec json shape judge
#                    <rc>＝ltm 非零離開碼（不含 0、無前導零）；sig<N>＝ltm 被訊號 N 殺掉（N≥1）；blank＝這一行在 Unicode 空白摺疊
#                    後是空的（例如只有 U+3000；不跑 ltm，因為空針對任何命中都算 self）；exec＝ltm 起不來；
#                    json＝輸出不是 JSON；shape＝JSON 不是「每個都帶字串 snippet 的物件陣列」；
#                    judge＝judge 自己掛了或印了不合形狀的東西。
# `tool=<n>` 是前 k 名裡含 `⟨tool ` 的 snippet 數（工具 metadata chunk，加上引述這個標記的散文）。
# 它**不是**污染訊號——它量的不是這條查詢而是「前 k 名有沒有工具 chunk」；工具 metadata chunk 佔
# chunk 表約四成（#67；那是份額不是前 k 名出現率，實際出現率要在真索引跑過才知道），拿它當 dirty
# 會讓多數列不可比。它是 #62（self-hit 的檢索層排除）要移動的那個量的觀察值，印出來給 #62 的
# 前後比較看（差值含兩次量測之間語料的成長）。
# 第一版的判準是「含 `⟨tool ` 或含 `ltm query`」，#63 verify 的 devil's-advocate 指出它量的是
# 「前 k 名有沒有工具 chunk」而不是「這條查詢被自己污染了沒有」；現在的 self 是把命中拿去跟查詢比對。
#
# `self` 會漏什麼（這份清單必然不完整）：查詢原文**跨過** metadata 欄位 200 字元截斷的命令——前綴進了
# 索引、會靠它排名，self 卻判 clean（完全落在截斷之後的則不在索引裡、也不會靠它排名）；空白與大小寫
# 以外的改寫（全形／半形、標點、換序）；
# 反過來，語料裡本來就逐字含這串字的**實質** turn 會被判 self——那不是污染，是正常召回，self 分不出來。
# 要分，只能在 Claude Code 之外的 shell 讀命中內容。
#
# <ms>：ltm 行程 fork→exit 的 monotonic 牆鐘（含 process 啟動、查詢前的增量併入、檢索、輸出），
# 不含 judge。單一樣本、沒有暖身——第 1 列常帶冷啟動，比較各列前先看這點。跟舊紀錄的命令
# （`.build/release/ltm query "$q" --k 5`，單一 project、無 --json）量的不是同一件事，
# 不要把本腳本的列與 2026-09-01 之前的表對齊——見 docs/measurements/README.md。
#
# 離開碼（封閉集合，同步測試對照程式碼裡的 exit N）：0 1 64 65 66 69 70
#   0 全部量到（含 empty）；1 任一列 error(…)（每列照印完才離開）；64 k 不是 1–1000 的整數；
#   65 查詢檔沒有任何非註解行；66 查詢檔不是可讀的一般檔案；69 ltm 不是可執行的一般檔案；
#   70 沒有 python3、或算不出查詢集指紋。
#
# 「第 N 條非註解行」：去掉行首行尾的 **ASCII** 空白（空格、tab、CR、VT、FF；`read` 已吃掉 LF；刻意不用
# [:space:]，它隨 locale 變、Swift 的不變）之後，空行與 `#` 開頭的行不算。全形空白（U+3000）與 NBSP 不是
# 空白——測試同時斷言查詢檔裡沒有這類字元，所以這條定義在腳本、測試、檔案三邊一致（含 CRLF：測試用
# `components(separatedBy: "\n")` 切行，CR 留在行尾由同一個 ASCII 集剝掉）。
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
command -v python3 >/dev/null 2>&1 || { echo "需要 python3 計時與解析 --json" >&2; exit 70; }

# 查詢集指紋：對「第 N 條非註解行」的同一個定義（ASCII trim、跳過空行與 #）逐行 sha256，只印 12 個 hex。
# 檔案內容留在 python 行程裡，不上 stdout。
SETID=$(python3 - "$QF" <<'PY'
import hashlib, sys
ws = " \t\r\v\f"
h = hashlib.sha256()
# 只在 LF 切行（跟 bash 的 read 與測試的 components(separatedBy: "\n") 一樣）：text-mode 逐行迭代連
# 單獨的 CR 也會切，那會讓兩個不同的查詢集算出同一個指紋。newline="" 是為了讓 read() 不把 CRLF 翻譯掉。
with open(sys.argv[1], encoding="utf-8", errors="surrogateescape", newline="") as f:
    data = f.read()
for raw in data.split("\n"):
    line = raw.strip(ws)
    if not line or line.startswith("#"):
        continue
    h.update(line.encode("utf-8", "surrogateescape")); h.update(b"\n")
print(h.hexdigest()[:12])
PY
) || SETID=""
# 指紋必須恰好 12 個小寫 hex：逐字元對字面集合比對，不用 [0-9a-f] 這種 range（bash 3.2 隨 locale 排序而變）。
fp_ok=1
case "$SETID" in ????????????) ;; *) fp_ok=0 ;; esac
i=0; while [ $fp_ok -eq 1 ] && [ $i -lt 12 ]; do
    case "${SETID:$i:1}" in [0123456789abcdef]) ;; *) fp_ok=0 ;; esac; i=$((i + 1))
done
[ $fp_ok -eq 1 ] || { echo "算不出查詢集指紋" >&2; exit 70; }
# k 也印在同一行：verdict 全是「前 k 名」的性質，兩份紀錄 k 不同就不能逐列對齊（requirements R4-1）。
printf 'set sha256:%s k=%s\n' "$SETID" "$K"

# 一條查詢一個 python：起 ltm、用 monotonic 計時、解析 --json、只印一行「<ms> <verdict>」。
# 不印任何 snippet；ltm 的 stdin 接 /dev/null（避免它吃掉查詢檔剩下的行）；stderr 由外層整個丟掉。
RUN='
import json, subprocess, sys, time
ltm, k, query = sys.argv[1], sys.argv[2], sys.argv[3]
def norm(s):
    return " ".join(s.split()).casefold()
q = norm(query)
if not q:
    print("0 error(blank)"); sys.exit(0)
t0 = time.monotonic_ns()
try:
    p = subprocess.run([ltm, "query", "--all-projects", "--k", k, "--json", "--", query],
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
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
if not isinstance(hits, list) or not all(isinstance(h, dict) and isinstance(h.get("snippet"), str) for h in hits):
    print(f"{ms} error(shape)"); sys.exit(0)
if not hits:
    print(f"{ms} empty tool=0"); sys.exit(0)
tool = sum(1 for h in hits if "⟨tool " in h["snippet"])
selfhit = any(q in norm(h["snippet"]) for h in hits)
print(f"{ms} " + ("self" if selfhit else "clean") + f" tool={tool}")
'
# judge 印出來的那一列在執行期也要合形狀（不只靠測試釘）：<ms> 全數字、verdict 在字母表內、
# error token 只能是數字、sig＋數字、或 ERROR_TOKENS 裡的字面（不是「像 token 的字元」——bash 3.2 的
# [a-z] 隨 locale 排序而變，字面比對不會）。不合就整列換成 error(judge)——寧可少一列量測，也不讓不明
# 字串上 stdout。多行的列不必另外擋：每個位元組都落在 ms（只准數字）或 rest（各臂完整限制到結尾）裡。
ERROR_TOKENS="blank exec json shape judge"
# valid_row 裡刻意不寫 error( 的字面（連這個變數的定義也拆開寫）：同步測試把程式碼裡每一個 error( 都當
# 輸出點，這裡是比對不是輸出。
E_OPEN="error"'('
valid_row() {
    local ms="${1%% *}" rest="${1#* }"
    case "$ms" in ''|*[!0-9]*) return 1 ;; esac
    case "$rest" in
        'clean tool='*|'self tool='*) case "${rest#* tool=}" in ''|*[!0-9]*) return 1 ;; esac ;;
        'empty tool=0') ;;
        "$E_OPEN"*")")
            local tok="${rest#"$E_OPEN"}"; tok="${tok%)}"
            case "$tok" in
                ''|0*|sig0*) return 1 ;;
                sig*) case "${tok#sig}" in ''|*[!0-9]*) return 1 ;; esac ;;
                *[!0-9]*) case " $ERROR_TOKENS " in *" $tok "*) ;; *) return 1 ;; esac ;;
            esac ;;
        *) return 1 ;;
    esac
    return 0
}
ws=$' \t\r\v\f'
n=0; bad=0
while IFS= read -r raw || [ -n "$raw" ]; do
    line="${raw#"${raw%%[!$ws]*}"}"
    line="${line%"${line##*[!$ws]}"}"
    case "$line" in ''|\#*) continue ;; esac
    n=$((n + 1))
    row=$(python3 -c "$RUN" "$LTM" "$K" "$line" 2>/dev/null) || row=""
    valid_row "$row" || row="0 error(judge)"
    case "${row#* }" in "$E_OPEN"*) bad=$((bad + 1)) ;; esac
    printf '#%d %sms %s\n' "$n" "${row%% *}" "${row#* }"
done < "$QF"
[ "$n" -gt 0 ] || { echo "查詢檔沒有任何非註解行" >&2; exit 65; }
[ "$bad" -eq 0 ] || exit 1
