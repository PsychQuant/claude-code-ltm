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
# verify R1 之後的形狀：**整支腳本**共用一個絕對 deadline（第一版只包正式查詢，
# `--help` 探測與 JSON 解析在守衛外）；`LTM_BIN` 必須是絕對路徑（相對路徑會讓檢查與
# 執行落在 `cd` 兩側、跑到不同檔）；prompt 放在 `--` 之後（以 `-` 開頭的 prompt 不再
# 被當成選項）；通知行不夾帶 CLI 的原始 stderr；版本過舊每個 session 只通知一次。
# 注意：變數後面緊接全形標點要寫 ${VAR}——非 UTF-8 locale 下 bash 會把高位元組併進變數名。
set -u
LTM_RECALL_MIN_VERSION="0.5.0"   # 第一個有 --format recall 的 ltm；ReleaseVersionSyncTests 釘住
GUARD="${LTM_RECALL_GUARD_SECONDS:-20}"   # 整支腳本的預算（秒）。hook manifest 是 28 s；測試設小值
case "$GUARD" in ''|*[!0-9]*) GUARD=20 ;; esac
START=$(date +%s); DEADLINE=$((START + GUARD))
remaining() { echo $((DEADLINE - $(date +%s))); }

STATS="${LTM_RECALL_STATS_FILE:-}"
# 只記封閉集合的類別標籤與時間戳，不記任何 prompt 文字（與記憶層的儲存約束同一條線）。
stat() { [ -n "$STATS" ] && printf '%s %s\n' "$(date +%s)" "$1" >> "$STATS" 2>/dev/null; return 0; }

notice() {
    # 只壓平換行，不以 byte 截斷——`head -c` 會切在多位元組字元中間、產出非法 UTF-8（verify-fix 實測：
    # 通知行因此整行讀不出來）。原因字串都是我們自己的、長度由路徑上限決定。
    local reason; reason=$(printf '%s' "$1" | tr '\n\r' '  ')
    printf 'ltm：本輪回想未完成（%s）；可手動呼叫 ltm_query\n' "$reason"
    stat notice; exit 0
}
# run_bounded <out> <err> cmd…：在剩餘預算內跑；逾時殺掉子行程與它的子行程，回 124。
run_bounded() {
    local out="$1" err="$2"; shift 2
    local left; left=$(remaining); [ "$left" -gt 0 ] || return 124
    "$@" > "$out" 2> "$err" &
    local pid=$! i=0 ticks=$((left * 10))
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$ticks" ]; do sleep 0.1; i=$((i + 1)); done
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

# 抽欄位。python3 不保證存在（verify R1 codex #8）——缺席就通知，不靜默。
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
# Claude Code 自己產生的 prompt（封閉列舉，會漏）：slash 展開、skill 本文、compaction 續接、
# skill 重載、Stop hook 回饋。量過：不排除時 84% 的放行是非使用者輸入。
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
[ -n "$MODE_WARN" ] && [ ! -e "${TMPDIR:-/tmp}/ltm-recall-modewarn-${SESSION:-nosession}" ] && {
    echo "ltm: LTM_RECALL_MODE=\"$MODE_WARN\" 不認得，當作 cued（本 session 只提醒一次）" >&2
    : > "${TMPDIR:-/tmp}/ltm-recall-modewarn-${SESSION:-nosession}"
}
if [ "$SHAPE" = synthetic ]; then stat synthetic; exit 0; fi

if [ "$MODE" = cued ]; then
    ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
    CUES="${LTM_RECALL_CUES:-$ROOT/hooks/recall-cues.txt}"
    if [ ! -r "$CUES" ]; then
        echo "ltm: 線索表讀不到：${CUES}（本輪不回想）" >&2; stat miss; exit 0
    fi
    grep -vE '^[[:space:]]*(#|$)' "$CUES" > "$TMP/cues" || true
    [ -s "$TMP/cues" ] || { stat miss; exit 0; }
    LC_ALL=C grep -E -q -f "$TMP/cues" "$TMP/prompt" || { stat miss; exit 0; }
fi

LTM="${LTM_BIN:-$HOME/bin/ltm}"
case "$LTM" in /*) ;; *) notice "LTM_BIN 必須是絕對路徑（${LTM}）" ;; esac
[ -x "$LTM" ] || notice "ltm 未安裝（${LTM}；plugin 的 MCP wrapper 首次啟動時會下載）"
[ -n "$CWD" ] || notice "hook 沒有提供可用的 cwd"
cd "$CWD" 2>/dev/null || notice "無法進入工作目錄（${CWD}）"

# 版本探測也在 deadline 內（第一版在守衛外，卡住就撞 28 s 外層逾時、靜默丟棄）。
run_bounded "$TMP/help.out" "$TMP/help.err" "$LTM" query --help; RC=$?
[ "$RC" -eq 124 ] && notice "ltm 版本探測逾時"
if ! grep -q -- '--format recall' "$TMP/help.out"; then
    # 舊 binary：每個 session 只通知一次，之後這個原因靜默（否則每輪一行噪音直到 release）。
    MARK="${TMPDIR:-/tmp}/ltm-recall-oldbin-${SESSION:-nosession}"
    if [ -e "$MARK" ]; then stat notice; exit 0; fi
    : > "$MARK"
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
cat "$TMP/out"; stat hit
exit 0
