#!/bin/bash
# UserPromptSubmit hook：線索閘門 → ltm query --format recall → 注入。
#
# 薄：閘門、絕對 deadline、把區塊原樣印出。重的東西（有界併入、session 排除、標記）
# 都在 ltm query 裡，CLI 與 MCP 共用。規格：openspec specs/proactive-recall-hook。
#
# 三條硬規則：永不 exit 2（那會擋掉使用者的 prompt）；閘門放行後**絕不靜默**
# （失敗一律印一行通知——Claude Code 對逾時的 hook 是靜默丟棄輸出，我們得在那之前
# 自己說話）；閘門未命中、off 模式、系統產生的 prompt 才是空輸出。
#
# 成本形狀（verify R2 logic N2）：cued 模式下**先用便宜的 raw grep 擋一次**，未命中就
# 直接退出、不啟動 python——絕大多數 prompt（實測命中率 0–2%）因此只花 bash+grep 的
# 開銷。python（剝 system-reminder、取 session/cwd/shape）只在「raw grep 命中的候選」
# 或 always 模式跑。raw grep 是過近似（會match 到 JSON 其他欄位或 system-reminder 內），
# 由 python 之後對**剝過的 prompt** 再 grep 一次收斂。
#
# 其餘形狀（verify R1/R2）：整支腳本共用一個絕對 deadline，clamp 在 manifest 的 28 s 以下；
# `LTM_BIN` 必須絕對路徑；prompt 放 `--` 之後；通知不夾 CLI stderr；版本過舊每 session 一次；
# 查詢成功後驗證輸出真的是區塊。注意：變數後接全形標點要寫 ${VAR}——非 UTF-8 locale 下
# bash 會把高位元組併進變數名。
set -u
LTM_RECALL_MIN_VERSION="0.5.0"   # 第一個有 --format recall 的 ltm；ReleaseVersionSyncTests 釘住
MANIFEST_TIMEOUT="${LTM_RECALL_MANIFEST_TIMEOUT:-28}"   # hooks.json 宣告的 timeout；腳本 deadline 必須小於它（測試可覆寫）
GUARD="${LTM_RECALL_GUARD_SECONDS:-20}"
case "$GUARD" in ''|*[!0-9]*) GUARD=20 ;; esac
# clamp 在 manifest 之下（verify R2 logic/req）：GUARD ≥ 28 會讓內部 deadline 晚於外層逾時，
# Claude Code 先把輸出丟掉、腳本沒機會印通知。留 3 s 給 kill/wait 的收尾。
[ "$GUARD" -ge "$MANIFEST_TIMEOUT" ] && GUARD=$((MANIFEST_TIMEOUT - 3))
START=$(date +%s); DEADLINE=$((START + GUARD))
remaining() { echo $((DEADLINE - $(date +%s))); }

STATS="${LTM_RECALL_STATS_FILE:-}"
# 只記封閉集合的類別標籤與時間戳，不記任何 prompt 文字（與記憶層的儲存約束同一條線）。
stat() { [ -n "$STATS" ] && printf '%s %s\n' "$(date +%s)" "$1" >> "$STATS" 2>/dev/null; return 0; }

notice() {
    # 只壓平換行，不以 byte 截斷——`head -c` 會切在多位元組字元中間、產出非法 UTF-8。
    local reason; reason=$(printf '%s' "$1" | tr '\n\r' '  ')
    printf 'ltm：本輪回想未完成（%s）；可手動呼叫 ltm_query\n' "$reason"
    stat notice; exit 0
}
# run_bounded <out> <err> cmd…：在剩餘預算內跑；逾時殺掉子行程與它的直接子行程，回 124。
# 註（verify R2 N8）：這是「子行程與它的子行程」，**不是** process group——腳本沒有 setsid，
# 子行程與 hook 同一個 group，真的殺 group 會連 hook 自己（及叫用它的 Claude Code）一起殺。
# `ltm` 目前不 fork 孫行程，所以單層 kill 已足夠。
run_bounded() {
    local out="$1" err="$2"; shift 2
    local left; left=$(remaining); [ "$left" -gt 0 ] || return 124
    "$@" > "$out" 2> "$err" &
    local pid=$! i=0 ticks=$((left * 20))
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$ticks" ]; do sleep 0.05; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
        pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; sleep 0.2
        pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null; return 124
    fi
    wait "$pid"
}

MODE="${LTM_RECALL_MODE:-cued}"; MODE_WARN=""
case "$MODE" in cued|always|off) ;; *) MODE_WARN="$MODE"; MODE=cued ;; esac
if [ "$MODE" = off ]; then cat > /dev/null; stat off; exit 0; fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ltm-recall.XXXXXX") || { cat > /dev/null; exit 0; }
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/input"

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# ── 便宜的 raw 閘門（cued 模式）──────────────────────────────────────────────
# 對整份 hook 輸入（**原始 JSON bytes**）grep 線索。命中是過近似（可能 match 到 prompt 以外的
# 欄位、或 system-reminder 內），由後面對剝過的 prompt 再 grep 收斂。這一段的成本讓絕大多數
# 未命中輪次不必啟動 python（verify R2 logic N2）。
#
# **編碼假設（verify R2 logic finding 2）**：raw grep 比對的是 bytes。Claude Code 是 Node app、
# hook JSON 走 `JSON.stringify`，對 BMP 內的非 ASCII（含中日文線索）輸出**字面 UTF-8**、不逃脫，
# 所以中文線索的 bytes 直接對得上。這個假設沒有文件保證，所以萬一某個 build 改成輸出 `\uXXXX`
# 逃脫，中文線索在 bytes 層會對不上——為此加一條 fallback：raw grep 未命中**但輸入含 `\u` 逃脫**
# 時，不當終止未命中，改讓 python 解碼後由 stage-2 判定（全 ASCII 且無 `\u` 的未命中才是終止的，
# 那條路徑不含任何線索、可安全快退）。純 ASCII 線索（earlier／last time…）在逃脫 JSON 裡仍是字面，
# stage-1 照樣命中。
CUES=""
if [ "$MODE" = cued ]; then
    CUES="${LTM_RECALL_CUES:-$ROOT/hooks/recall-cues.txt}"
    # 必須是**一般檔案**（verify R2 security N-S1）：raw grep 在 deadline 之外，若 `LTM_RECALL_CUES`
    # 指到 fifo／device／慢速掛載，grep 會阻塞到超過腳本 deadline、撞外層逾時、輸出被丟棄。
    # 一般檔案的 grep 有界；非一般檔案一律當讀不到、fail closed（不回想）。
    if [ ! -f "$CUES" ] || [ ! -r "$CUES" ]; then
        echo "ltm: 線索表不是可讀的一般檔案：${CUES}（本輪不回想）" >&2; stat miss; exit 0
    fi
    grep -vE '^[[:space:]]*(#|$)' "$CUES" > "$TMP/cues" || true
    [ -s "$TMP/cues" ] || { stat miss; exit 0; }
    if ! LC_ALL=C grep -E -q -f "$TMP/cues" "$TMP/input"; then
        # 未命中：只有「不含 \u 逃脫」才是終止未命中；含 \u 時可能是被逃脫的中文線索，落到 python。
        LC_ALL=C grep -q '\\u[0-9a-fA-F]' "$TMP/input" || { stat miss; exit 0; }
    fi
fi

# ── 到這裡：cued 命中候選，或 always 模式。才啟動 python 抽欄位。────────────────
PY="${LTM_RECALL_PYTHON:-python3}"
command -v "$PY" > /dev/null 2>&1 || notice "找不到 python3，無法解析 hook 輸入"
cat > "$TMP/extract.py" <<'PY'
import json, re, sys
tmp = sys.argv[1]
try:
    d = json.load(open(tmp + "/input", encoding="utf-8"))
except Exception:
    sys.exit(3)
prompt = re.sub(r"<system-reminder>.*?</system-reminder>", "", d.get("prompt") or "", flags=re.S)
session = d.get("session_id") or ""
cwd = d.get("cwd") or ""
if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", session): session = ""
if "\n" in cwd or "\r" in cwd: cwd = ""
head = prompt.lstrip()[:40]
# Claude Code 自己產生的 prompt（封閉列舉，會漏；量測 §3 記命中分佈）：slash 展開、skill
# 本文、compaction 續接、skill 重載、Stop hook 回饋。
synthetic = head.startswith("<") or any(head.startswith(p) for p in (
    "Base directory for this skill", "This session is being continued",
    "(Re-invocation of", "Stop hook feedback:"))
open(tmp + "/prompt", "w", encoding="utf-8").write(prompt)
open(tmp + "/query", "w", encoding="utf-8").write(prompt[:4000])   # 以字元不以 byte 截
open(tmp + "/meta", "w", encoding="utf-8").write(f"{session}\n{cwd}\n{'synthetic' if synthetic else 'typed'}\n")
PY
run_bounded "$TMP/py.out" "$TMP/py.err" "$PY" "$TMP/extract.py" "$TMP"; RC=$?
[ "$RC" -eq 0 ] || notice "解析 hook 輸入失敗（結束碼 ${RC}）"
SESSION=$(sed -n 1p "$TMP/meta"); CWD=$(sed -n 2p "$TMP/meta"); SHAPE=$(sed -n 3p "$TMP/meta")

# once-per-session marker：用 mkdir（原子、不跟隨 symlink）而非 `: >`（會截斷 symlink 目標）。
# 檔名含最低版本，未來 min-version 升級時舊 marker 不會誤抑制新通知（verify R2 N7）。
mark_once() {   # $1 = kind；回 0＝第一次（要通知），非 0＝已通知過
    local dir="${TMPDIR:-/tmp}/ltm-recall-$1-${LTM_RECALL_MIN_VERSION}-${SESSION:-nosession}"
    mkdir "$dir" 2>/dev/null
}
if [ -n "$MODE_WARN" ] && mark_once modewarn; then
    echo "ltm: LTM_RECALL_MODE=\"$MODE_WARN\" 不認得，當作 cued（本 session 只提醒一次）" >&2
fi
if [ "$SHAPE" = synthetic ]; then stat synthetic; exit 0; fi

# cued：對**剝過 system-reminder 的 prompt** 再 grep 一次，收斂 raw 閘門的過近似
# （system-reminder 內的線索、或 prompt 以外欄位的命中都在這裡被濾掉）。
if [ "$MODE" = cued ]; then
    LC_ALL=C grep -E -q -f "$TMP/cues" "$TMP/prompt" || { stat miss; exit 0; }
fi

LTM="${LTM_BIN:-$HOME/bin/ltm}"
case "$LTM" in /*) ;; *) notice "LTM_BIN 必須是絕對路徑（${LTM}）" ;; esac
[ -x "$LTM" ] || notice "ltm 未安裝（${LTM}；plugin 的 MCP wrapper 首次啟動時會下載）"
[ -n "$CWD" ] || notice "hook 沒有提供可用的 cwd"
cd "$CWD" 2>/dev/null || notice "無法進入工作目錄（${CWD}）"

# 版本探測也在 deadline 內（卡住就撞外層逾時、靜默丟棄）。
run_bounded "$TMP/help.out" "$TMP/help.err" "$LTM" query --help; RC=$?
[ "$RC" -eq 124 ] && notice "ltm 版本探測逾時"
if ! grep -q -- '--format recall' "$TMP/help.out"; then
    # 舊 binary：每個 session 只通知一次（否則每輪一行噪音直到 release）。
    mark_once oldbin || { stat notice; exit 0; }
    notice "ltm 版本過舊，需 ≥ ${LTM_RECALL_MIN_VERSION}（本 session 只提醒一次）"
fi

# 併入的批次要小：預算判定只在批次邊界，預設 2,000 chunk 一批在本機約 25 s 才到邊界。
export LTM_BUILD_BATCH_CHUNKS="${LTM_BUILD_BATCH_CHUNKS:-200}"
REFRESH=$(( GUARD > 5 ? GUARD - 5 : 1 ))
set -- query --format recall --k 3 --max-refresh-seconds "$REFRESH"
[ -n "$SESSION" ] && set -- "$@" --exclude-session "$SESSION"
QUERY=$(cat "$TMP/query")
set -- "$@" -- "$QUERY"
run_bounded "$TMP/out" "$TMP/err" "$LTM" "$@"; RC=$?
[ "$RC" -eq 124 ] && notice "逾時 ${GUARD} s"
[ "$RC" -eq 0 ] || notice "ltm query 結束碼 ${RC}"
# 驗證輸出真的是區塊（verify R2 N7/codex R2-7）：exit 0 但空／不是區塊時仍要可見降級，
# 不能靜默 cat 一個空檔——那違反「放行後不靜默」。
if [ ! -s "$TMP/out" ] || ! head -1 "$TMP/out" | grep -q '<!-- ltm:recall'; then
    notice "ltm query 沒有回傳可用的回想區塊"
fi
cat "$TMP/out"; stat hit
exit 0
