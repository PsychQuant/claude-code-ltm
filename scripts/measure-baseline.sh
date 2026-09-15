#!/bin/bash
# 基準查詢量測（#63）：讀 scripts/baseline-queries.txt，逐條跑
#   ltm query --all-projects --k <k> --json -- <查詢>
# **stdout 第一行是 `set sha256:<12 hex> k=<k>`（非註解行內容的指紋與這次的 k——查詢集一換，指紋就換；
# verdict 全是「前 k 名」的性質，k 不同也不可比；紀錄要連這一行一起引，兩次量測這一行不同就不能逐列對齊，
# `#N` 只是檔內位置），之後每列 `#N <ms>ms <verdict>`**（例如
# `#3 812ms clean tool=1`；`<ms>` 是整數毫秒，後面緊接字面 `ms`）。
# 查詢文字與命中內容不進 stdout／stderr，包含 `bash -x`、
# `SHELLOPTS=xtrace`、`BASH_ENV` 裡的 `set -x`、`set -a`／`SHELLOPTS=allexport`、以及繼承的 `set -e`／`SHELLOPTS=errexit`
# （第一行就關掉這三個——allexport 會把裝著整份查詢集的變數匯出給每個子行程；errexit 會讓 `read -d ''` 在 EOF 的正常回 1
# 直接殺掉腳本：零輸出、離開碼 1 與「任一列 error」撞號，R13）。判準是「每一個拿得到查詢內容的子行程，它的 stderr
# 都不是可能載內容的通道」：指紋 python、judge python、ltm 的 stderr 都丟掉，judge 與 ltm 的 stdin 都接 /dev/null；
# 兩個 process substitution 的子 shell 只跑 `builtin printf`，運算元不會上 stderr。讀查詢檔與逐列迴圈用 `builtin read`、
# 重設變數用 `builtin unset`：bash 解析名字時函式先於 builtin，呼叫端 `export -f read` 或 `BASH_ENV` 裡一個同名函式就能把
# 整份查詢檔接走（R13）；`unset` 失敗（呼叫端把 `QF_CONTENT` 設成 readonly）→ 70，不然 `read` 的賦值失敗會與正常 EOF 同樣回 1、
# 預設值冒充讀進來的內容（R13）。
# 擋不住的：`BASH_ENV`／`PS4` 裡刻意放一個會讀查詢檔的命令替換——trace 第一行 `set +x` 時 PS4 先展開；
# PATH 上的 python3 被換成會印檔案的東西；一個叫 `builtin` 的函式（它蓋掉的正是指名 builtin 的那個字）。另外，查詢原文在執行期會在 python3 與 ltm 的 argv 上（CLI 的查詢
# 就是位置參數、`--` 終止符用得對），同一帳號的行程 `ps -ww` 看得到（容器 PID namespace、Linux hidepid 下更窄）、
# 存活時間是那一列的 wall clock——那是作業系統的可見面不是本腳本的輸出通道。這份例外會漏，判準是「這個動作等不等同操作者直接 cat 查詢檔」
# ——那是操作者的動作不是本腳本的洩漏面；寫在這裡是因為上一句是全稱。
# 指紋揭露什麼：見 docs/measurements/README.md 的量測段（單一版本，這裡不複述——R8 抓到兩份漂移、R12 抓到這裡又複述了一半）。
#
# 為什麼這麼小氣：這支腳本會在 Claude Code session 裡被跑。今天會進索引的是逐字稿裡的純字串
# `message.content`（使用者鍵入的 prompt 常是這一種，整段）、`text` block（使用者輸入、Claude 的散文）
# 與 tool_use 的七個 metadata 欄位（`CorpusScanner.toolMetadataFields`，含 Bash 的 `command=`／
# `description=`、`ltm_query` MCP 工具的 `query=`）。Bash 的 stdout 是 tool_result、
# 今天不被索引——但 Claude 引述輸出的那句散文一定被索引。印了查詢字串，就等著被引述（#63 的 root cause）。
#
# verdict（封閉字母表；只有這幾個，不得類推。四處列舉——本檔頭的「error tokens」行、docs/measurements/README.md、
# 測試的 errorTokens、程式碼裡的 `error(...)` 輸出點——由 Tests/LTMMCPTests/BaselineQueryFileTests.swift 的同步測試
# 逐一相等，`ERROR_TOKENS` 變數等於它們扣掉 `<rc>`／`sig<N>` 兩個樣式 token 的子集。「輸出點」的判法是形狀：
# 程式碼裡**每一個** `error(` 出現（整行註解除外）都必須是兩種輸出述句形狀之一——python 的
# `print(…); sys.exit(0)` 且字面在雙引號裡、bash 的 `valid_row "$row" || row="0 error(<token>)"`——不然測試紅，
# **行尾註解裡的字面也紅**（valid_row 用變數 E_OPEN 比對、不寫字面，所以沒有任何一行被略過）。它擋的是
# 刪掉／改名輸出點而清單沒跟；不證明那一行可達或會執行，那由每個 token 的行為測試扛）：
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
# `tool=<n>` 是前 k 名裡含 `⟨tool ` 的 snippet 數。它**不是**污染訊號，只是給 #62 前後比較看的觀察值——
# 理由、誠實邊界、第一版判準為何被換掉，只有一份，在 docs/measurements/README.md 的 `tool=<n>` 段（這裡不複述）。
#
# `self` 會漏什麼（這份清單必然不完整）：查詢原文**跨過** metadata 欄位 200 字元截斷的命令——前綴進了
# 索引、會靠它排名，self 卻判 clean（完全落在截斷之後的則不在索引裡、也不會靠它排名）；空白與大小寫
# 以外的改寫（全形／半形、標點、換序）；
# 反過來，語料裡本來就逐字含這串字的**實質** turn 會被判 self——那不是污染，是正常召回，self 分不出來。
# 要分，只能在 Claude Code 之外的 shell 讀命中內容。
#
# <ms>：ltm 行程 fork→exit 的 monotonic 牆鐘（含 process 啟動、查詢前的增量併入、檢索、輸出），
# 不含 judge。單一樣本、沒有暖身；第 1 列是否系統性偏高**沒有量過**（要量：同一集合連跑兩次、比第 1 列），
# 比較各列前先看這點。跟舊紀錄的命令
# （`.build/release/ltm query "$q" --k 5`，單一 project、無 --json）量的不是同一件事，
# 不要把本腳本的列與 2026-09-01 之前的表對齊——見 docs/measurements/README.md。
#
# 離開碼（封閉集合，同步測試對照程式碼裡的 exit N）：0 1 64 65 66 69 70
#   0 全部量到（含 empty）；1 任一列 error(…)（每列照印完才離開）；64 k 不是 1–1000 的整數；
#   65 查詢檔沒有任何非註解行；66 查詢檔不是可讀的一般檔案、讀不了、含 NUL、或讀取中斷；69 ltm 不是可執行的一般檔案；
#   70 沒有 python3、算不出查詢集指紋、或查詢集變數被呼叫端設成 readonly。
#
# 「第 N 條非註解行」：去掉行首行尾的 **ASCII** 空白（空格、tab、CR、VT、FF；`read` 已吃掉 LF；刻意不用
# [:space:]，它隨 locale 變、Swift 的不變）之後，空行與 `#` 開頭的行不算。全形空白（U+3000）與 NBSP 不是
# 空白——測試同時斷言查詢檔裡沒有這類字元，所以這條定義在腳本、測試、檔案三邊一致（含 CRLF：測試用
# `components(separatedBy: "\n")` 切行，CR 留在行尾由同一個 ASCII 集剝掉）。
#
# 用法：LTM_ANCHOR_KEY="$(~/bin/ltm memory --export-key)" scripts/measure-baseline.sh [k]
#   LTM_BIN（預設 ~/bin/ltm）、LTM_BASELINE_QUERIES（預設本腳本旁的 baseline-queries.txt——「本腳本旁」照 bash 找腳本
#   運算元的順序解：`$0` 含斜線取其目錄；裸名先看 cwd、再沿 PATH 取第一個可讀的檔案）、
#   k 1–1000（預設 5）。密鑰請用命令替換直接餵進環境，不要落地（.claude/rules/anchor-key-in-probes.md）。
set +e +x +a
set -u
# 自己的目錄：仿 bash 找腳本運算元的順序——`$0` 含斜線就是那個目錄（尾端補 `/` 讓 `/x.sh` 解到根目錄；經 symlink 呼叫時是
# symlink 所在的目錄，不解 symlink）；裸名時 bash 先看 cwd，再沿 PATH 取**第一個可讀的檔案**（不要求可執行；空的 PATH 元素是
# cwd。「可讀就取」是拿一份 644 的複本實測的，bash 3.2.57 與 5.3.15 同；目錄與非一般檔案這裡以 `-f` 排除，bash 對它們怎麼處理
# 沒查）。這裡照同一順序自己走 PATH——R12 版用 `command -v`，它**偏好可執行檔**：PATH 前面一份 644、後面一份 755 時 bash 跑
# 前者、`command -v` 回後者，量到別棵樹的查詢檔而 rc 0（R13）；它對函式／builtin 還會回不含斜線的名字。都對不上 →
# HERE=/nonexistent → 66（R12 版的 `${d:-/}` 把「解不出來」與「根目錄」壓成同一值、落在 `/`，R13；這條退路實務上到不了——bash 找得到
# 腳本才跑得起來，而它找的就是同一條順序——所以沒有測試驅動它，寫在這裡是讓落點與註解一致）。`cd` 關掉 CDPATH（它會把解出
# 的路徑印進命令替換、也會選到別棵樹）。前三版各錯在一句沒查過的全稱：R10 `dirname`（缺席時 `cd ""` 回 0、退回 cwd）、R11 裸名
# 一律 cwd、R12「`command -v` 就是 bash 的順序」。測試五臂：經 PATH 的裸名、相對路徑＋CDPATH、cwd 裡的裸名、cwd 與 PATH 各一份時
# 取 cwd、PATH 上 644 排在 755 之前時取 644——指紋都必須是 bash 實際跑的那份旁邊的查詢檔。
d=
case "$0" in
    */*) d="${0%/*}/" ;;
    *) if [ -f "./$0" ]; then d=.; else
           p="${PATH-}"
           while :; do
               e="${p%%:*}"
               if [ -f "${e:-.}/$0" ] && [ -r "${e:-.}/$0" ]; then d="${e:-.}"; break; fi
               case "$p" in *:*) p="${p#*:}" ;; *) break ;; esac
           done
       fi ;;
esac
{ [ -n "$d" ] && HERE=$(CDPATH= cd -- "$d" 2>/dev/null && pwd); } || HERE=/nonexistent
QF="${LTM_BASELINE_QUERIES:-$HERE/baseline-queries.txt}"
LTM="${LTM_BIN:-${HOME:-}/bin/ltm}"   # HOME 沒設也不能讓 set -u 隱式地以 1 離開（那會與「1 = 任一列 error」撞號，R8）
K="${1-5}"   # 明確給了空字串是錯，不是「用預設」（R10）
# k：只准數字（字面集合不用 range——bash 3.2 的 `[0-9]` 隨 locale 排序而變，與下方指紋檢查同一理由，R13）；原始字串超過
# 20 個字元先擋（R13：R12 的逐字元剝零迴圈是 O(n²)，兩萬個零燒十幾秒——閘要在剝零之前；20 個字元以內的前導零仍合法）；再剝前導零
# （一次展開；`007`、`01000` 都合法，正規化後印進 set 行——R10 版直接印 `k=007`，R11 版 `$((K))` 當八進位）；再擋位數（剝完零還
# 有 5 位以上不可能在 1–1000；不先擋，`[ -ge ]` 對超過 intmax 的字串會多印一行 bash 診斷——查法
# `bash -c '[ 18446744073709551621 -ge 1 ]; echo $?'` → 2 加一行 `integer expression expected`，3.2 與 5.3 都不 wrap；R12 寫成
# 「靜默 wrap 成 5」，那是同一個 commit 已經刪掉的 `$((10#$K))` 才有的行為，R13）；再範圍檢查。順序由測試釘住（`01000` → k=1000；
# 21 個字元 → 64；`18446744073709551621` → 64 且 stderr 只有那一句）。
case "$K" in ''|*[!0123456789]*) echo "k 必須是 1–1000 的整數" >&2; exit 64 ;; esac
[ "${#K}" -le 20 ] || { echo "k 必須是 1–1000 的整數" >&2; exit 64; }
K="${K#"${K%%[!0]*}"}"; K="${K:-0}"
case "$K" in ?????*) echo "k 必須是 1–1000 的整數" >&2; exit 64 ;; esac
[ "$K" -ge 1 ] && [ "$K" -le 1000 ] || { echo "k 必須是 1–1000 的整數" >&2; exit 64; }
[ -f "$QF" ] && [ -r "$QF" ] || { echo "查詢檔不是可讀的一般檔案：$QF" >&2; exit 66; }
[ -f "$LTM" ] && [ -x "$LTM" ] || { echo "ltm 不是可執行的一般檔案：$LTM" >&2; exit 69; }
command -v python3 >/dev/null 2>&1 || { echo "需要 python3 計時與解析 --json" >&2; exit 70; }

# 查詢檔只開一次、用 `builtin read` 讀（不經 PATH 上的任何子行程、不落地；指名 builtin 是因為同名函式會先被解析到，R13）：
# `read -r -d ''` 讀到 NUL 回 0（bash 變數存不了它 → 66）、讀到 EOF 回 1（正常，尾端換行原樣保留）、其他（訊號中斷）→ 66；
# 重導失敗時 read 沒跑、變數維持 unset → 66。`unset` 失敗（變數被呼叫端設成 readonly）→ 70：不擋的話 `read` 的賦值失敗也回 1、
# `${QF_CONTENT+set}` 被預設值本身滿足，腳本會替那份預設值算指紋、逐條量測、rc 0（R13 實測；R12 的 pre-exported 臂只涵蓋 export
# 屬性）。指紋與逐列量測共用讀進來的這一份，中間換檔不會讓第一行的身分與列內容錯配。**沒有測試能驅動的**：
# 換檔的 race、「讀不了」那一臂（`${QF_CONTENT+set}` 只在 -r 檢查之後的 race 窗口可達；不能拆，拆了
# unset 變數會撞 `set -u` 的隱式 1）、以及短讀（I/O 錯誤中途停、rc 仍是 1、內容不完整）——最後這個偵測不到，只有
# 指紋會與完整集合不同、跨兩次量測比對得出來。R8 版用 `$(cat; printf x)` 加 tr／wc 的 NUL 檢查：那條 `|| exit 66` 不可達（命令替換的
# 離開碼是 printf 的），而三個 PATH 子行程各拿到整份查詢集、stderr 沒重導（R9）。
builtin unset QF_CONTENT 2>/dev/null || { echo "查詢集變數被設成 readonly，無法重設" >&2; exit 70; }
{ IFS= builtin read -r -d '' QF_CONTENT < "$QF"; } 2>/dev/null; rc=$?
[ "${QF_CONTENT+set}" = set ] || { echo "查詢檔讀不了：$QF" >&2; exit 66; }
case "$rc" in 1) ;; 0) echo "查詢檔含 NUL：$QF" >&2; exit 66 ;; *) echo "查詢檔讀取中斷（read 回 $rc）：$QF" >&2; exit 66 ;; esac
# 查詢集指紋：對「第 N 條非註解行」的同一個定義（ASCII trim、跳過空行與 #）逐行 sha256，只印 12 個 hex。
# 內容經 process substitution 的管線給 fd 3（不上命令列、不進環境、不落地——herestring 在 bash 3.2 會寫 $TMPDIR
# 暫存檔，R9），留在 python 行程裡，不上 stdout；stderr 也丟掉——它是唯一整份讀進查詢集的行程，
# 檔頭那句「不進 stdout／stderr」的全稱曾漏了它（R7）。
SETID=$(python3 - 3< <(builtin printf '%s' "$QF_CONTENT") 2>/dev/null <<'PY'
import hashlib, sys
ws = " \t\r\v\f"
h = hashlib.sha256()
# 只在 LF 切行（跟 bash 的 read 與測試的 components(separatedBy: "\n") 一樣）：text-mode 逐行迭代連
# 單獨的 CR 也會切，那會讓兩個不同的查詢集算出同一個指紋。newline="" 是為了讓 read() 不把 CRLF 翻譯掉。
with open("/dev/fd/3", encoding="utf-8", errors="surrogateescape", newline="") as f:
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
# k 也印在同一行：verdict 全是「前 k 名」的性質，兩份紀錄 k 不同就不能逐列對齊（R4）。
builtin printf 'set sha256:%s k=%s\n' "$SETID" "$K"

# 一條查詢一個 python：起 ltm、用 monotonic 計時、解析 --json、只印一行「<ms> <verdict>」。
# 不印任何 snippet；judge 自己的 stdin 接 /dev/null（R7：它曾繼承查詢內容），python 端對 ltm 再設一次
# DEVNULL 是縱深、目前沒有測試分得出來（R8）；stderr 由外層整個丟掉。命中只看前 k 筆——「前 k 名」的語意由
# judge 自己截，不靠 ltm 自律（R7：多回傳的命中會安靜地改變 self 與 tool=<n>），連形狀檢查也只看
# 前 k 筆（R8：第 k+1 筆畸形不該讓整列量不到）。
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
if not isinstance(hits, list):
    print(f"{ms} error(shape)"); sys.exit(0)
hits = hits[:int(k)]
if not all(isinstance(h, dict) and isinstance(h.get("snippet"), str) for h in hits):
    print(f"{ms} error(shape)"); sys.exit(0)
if not hits:
    print(f"{ms} empty tool=0"); sys.exit(0)
tool = sum(1 for h in hits if "⟨tool " in h["snippet"])
selfhit = any(q in norm(h["snippet"]) for h in hits)
print(f"{ms} " + ("self" if selfhit else "clean") + f" tool={tool}")
'
# judge 印出來的那一列在執行期也要合形狀（不只靠測試釘）：<ms> 全數字、verdict 在字母表內、
# error token 只能是數字、sig＋數字、或 ERROR_TOKENS 裡的字面（不是「像 token 的字元」——bash 3.2 的
# [a-z] 隨 locale 排序而變，字面比對不會；數字也用字面集合 `[!0123456789]`，同步測試釘住程式碼行裡沒有 `[0-9]`，R13）。不合就整列換成 error(judge)——寧可少一列量測，也不讓不明
# 字串上 stdout。多行的列不必另外擋：每個位元組都落在 ms（只准數字）或 rest（各臂完整限制到結尾）裡。
ERROR_TOKENS="blank exec json shape judge"
# valid_row 裡刻意不寫 error( 的字面（連這個變數的定義也拆開寫）：同步測試把程式碼裡每一個 error( 出現都當
# 輸出點候選、不是輸出述句形狀就紅（含行尾註解裡的字面——R6 曾在上一行留一條 error(timeout) 註解當接線的
# canary，R7 指出它無主、而且哪天 timeout 進了字母表就無聲失效；現在不剝註解也就沒有接線要驅動），
# 這裡是比對不是輸出。
E_OPEN="error"'('
valid_row() {
    local ms="${1%% *}" rest="${1#* }"
    case "$ms" in ''|*[!0123456789]*) return 1 ;; esac
    case "$rest" in
        'clean tool='*|'self tool='*) case "${rest#* tool=}" in ''|*[!0123456789]*) return 1 ;; esac ;;
        'empty tool=0') ;;
        "$E_OPEN"*")")
            local tok="${rest#"$E_OPEN"}"; tok="${tok%)}"
            case "$tok" in
                ''|0*|sig0*) return 1 ;;
                sig*) case "${tok#sig}" in ''|*[!0123456789]*) return 1 ;; esac ;;
                *[!0123456789]*) case " $ERROR_TOKENS " in *" $tok "*) ;; *) return 1 ;; esac ;;
            esac ;;
        *) return 1 ;;
    esac
    return 0
}
ws=$' \t\r\v\f'
n=0; bad=0
while IFS= builtin read -r raw || [ -n "$raw" ]; do
    line="${raw#"${raw%%[!$ws]*}"}"
    line="${line%"${line##*[!$ws]}"}"
    case "$line" in ''|\#*) continue ;; esac
    n=$((n + 1))
    row=$(python3 -c "$RUN" "$LTM" "$K" "$line" </dev/null 2>/dev/null) || row=""
    valid_row "$row" || row="0 error(judge)"
    case "${row#* }" in "$E_OPEN"*) bad=$((bad + 1)) ;; esac
    builtin printf '#%d %sms %s\n' "$n" "${row%% *}" "${row#* }"
done < <(builtin printf '%s' "$QF_CONTENT")
[ "$n" -gt 0 ] || { echo "查詢檔沒有任何非註解行" >&2; exit 65; }
[ "$bad" -eq 0 ] || exit 1
