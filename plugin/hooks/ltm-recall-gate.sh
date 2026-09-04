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
# 閘門形狀（verify R3 codex）：python **直接**解碼 hook JSON（~22 ms），閘門比對**解碼後的**
# prompt。先前為省 python 而先對原始 JSON bytes 做 raw grep——被 codex 推翻為不可靠的過近似
# （錨點、`\uXXXX` 逃脫、跨 system-reminder 的線索都會讓 raw grep 漏而 stage-2 命中 → 安靜漏回想）。
# python 直接跑仍讓未命中輪次 ~37 ms、遠低於規格 100 ms，且閘門變 sound。python 缺席＝無法閘門
# ＝安靜未命中（一次 stderr 提醒），不對每輪注入通知。
#
# 其餘形狀（verify R1/R2/R3）：`--help` 探測與查詢共用一個絕對 deadline，clamp 在 manifest 28 s
# − 3 以下（env 只能降不能抬真上限）；`LTM_BIN` 必須絕對路徑；prompt 放 `--` 之後；通知不夾 CLI
# stderr；版本過舊每 session 一次；查詢成功後驗證輸出首行正好是開標記、末行正好是閉標記。
# 注意：變數後接全形標點要寫 ${VAR}——非 UTF-8 locale 下 bash 會把高位元組併進變數名。
set -u
LTM_RECALL_MIN_VERSION="0.5.0"   # 第一個有 --format recall 的 ltm；ReleaseVersionSyncTests 釘住
RECALL_OPEN="<!-- ltm:recall v1 -->"    # 與 RecallMarker.open 一致（RecallMarkerSyncTests 掃此檔）
RECALL_CLOSE="<!-- /ltm:recall -->"    # 與 RecallMarker.close 一致
HARD_MANIFEST_TIMEOUT=28                # hooks.json 實際宣告的 timeout（真上限，env 不能抬高）
MANIFEST_TIMEOUT="${LTM_RECALL_MANIFEST_TIMEOUT:-$HARD_MANIFEST_TIMEOUT}"
case "$MANIFEST_TIMEOUT" in ''|*[!0-9]*) MANIFEST_TIMEOUT="$HARD_MANIFEST_TIMEOUT" ;; esac   # 非數字→真上限（verify R3 codex #3）
# env 只能**降低** manifest（測試用），不能抬高真正的 28 s ceiling。
[ "$MANIFEST_TIMEOUT" -gt "$HARD_MANIFEST_TIMEOUT" ] && MANIFEST_TIMEOUT="$HARD_MANIFEST_TIMEOUT"
GUARD="${LTM_RECALL_GUARD_SECONDS:-20}"
case "$GUARD" in ''|*[!0-9]*) GUARD=20 ;; esac
# clamp 到 manifest − 3 以下（verify R2/R3）：留 3 s 給 kill/wait/通知輸出的收尾。用 `>`（不是 `>=`）
# 對 `MANIFEST−3`，所以 GUARD=27、manifest=28 也會被壓到 25，而非留在 27 貼著 28（codex R3 #3）。
CEILING=$((MANIFEST_TIMEOUT - 3))
[ "$GUARD" -gt "$CEILING" ] && GUARD="$CEILING"
[ "$GUARD" -lt 1 ] && GUARD=1
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

# once-per-session marker：用 mkdir（原子、不跟隨 symlink）而非 `: >`（會截斷 symlink 目標）。
# 檔名含最低版本，未來 min-version 升級時舊 marker 不會誤抑制新通知（verify R2 N7）。
# `$SESSION` 在 python 抽欄位前是空的（用 nosession），那只影響 python 缺席這一條的去重粒度。
SESSION=""
mark_once() {   # $1 = kind；回 0＝第一次（要通知），非 0＝已通知過
    local dir="${TMPDIR:-/tmp}/ltm-recall-$1-${LTM_RECALL_MIN_VERSION}-${SESSION:-nosession}"
    mkdir "$dir" 2>/dev/null
}

# ── 抽欄位（解碼後才閘門）──────────────────────────────────────────────────────
# **直接**跑 python 解碼 hook JSON，取剝過 system-reminder 的 prompt、session、cwd、shape，
# 然後對**解碼後的 prompt** 比對線索。verify R3 (codex) 推翻了先前「先對原始 JSON bytes 做便宜
# raw grep」的做法：對整份 JSON 套使用者的 ERE **不是**「對解碼後 prompt 比對」的可靠過近似——
# 錨點（`^上次`）、`\uXXXX` 逃脫、跨 system-reminder 邊界的線索都會讓 raw grep 漏而 stage-2 命中，
# 於是安靜地不回想。python 直接抽（實測 ~22 ms，全 hook 未命中 ~37 ms、仍遠低於規格 100 ms）就
# 沒有這個過近似問題。python 讀的是我們剛用 `cat` 寫下的本地一般檔案，json.load 有界、不會卡，
# 所以**不經 `run_bounded`**（省掉輪詢開銷）。
PY="${LTM_RECALL_PYTHON:-python3}"
if ! command -v "$PY" > /dev/null 2>&1; then
    # python 缺席就無法解碼、無法閘門——不能判斷這則 prompt 有沒有線索，所以**安靜未命中**
    # （不是每輪注入通知：那會對「幫我改函式」這種完全無關的輪次也吐一行，見 codex R3 #2）。
    # 一次 stderr 提醒（去重粒度是 $TMPDIR，非 session——session_id 要 python 解碼才拿得到，
    # 而這正是 python 缺席的那條路；python 缺席是機器層條件，per-$TMPDIR 去重已足夠）。
    mark_once nopython && echo "ltm: 找不到 python3，proactive recall 停用（可手動呼叫 ltm_query）" >&2
    stat miss; exit 0
fi
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
"$PY" "$TMP/extract.py" "$TMP"; RC=$?
[ "$RC" -eq 0 ] || notice "解析 hook 輸入失敗（結束碼 ${RC}）"
SESSION=$(sed -n 1p "$TMP/meta"); CWD=$(sed -n 2p "$TMP/meta"); SHAPE=$(sed -n 3p "$TMP/meta")

if [ -n "$MODE_WARN" ] && mark_once modewarn; then
    echo "ltm: LTM_RECALL_MODE=\"$MODE_WARN\" 不認得，當作 cued（本 session 只提醒一次）" >&2
fi
if [ "$SHAPE" = synthetic ]; then stat synthetic; exit 0; fi

# cued：對**解碼後**的 prompt 比對線索（唯一的閘門，sound）。
if [ "$MODE" = cued ]; then
    CUES="${LTM_RECALL_CUES:-$ROOT/hooks/recall-cues.txt}"
    # cue 檔必須是**一般檔案**（verify R2 security N-S1）：fifo／device／慢速掛載會讓 grep 阻塞。
    if [ ! -f "$CUES" ] || [ ! -r "$CUES" ]; then
        echo "ltm: 線索表不是可讀的一般檔案：${CUES}（本輪不回想）" >&2; stat miss; exit 0
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
# 驗證輸出真的是**完整**區塊（verify R2 N7／R3 codex #4）：第一行必須**正好**是開標記、
# 最後一行必須**正好**是閉標記。先前只查「第一行含開標記子字串」，會放行未閉合或首行帶垃圾的
# 輸出——而缺閉標記正好破壞這個區塊要給模型的資料邊界。exit 0 但輸出不合格 → 可見降級，不靜默。
if [ ! -s "$TMP/out" ] \
    || [ "$(head -1 "$TMP/out")" != "$RECALL_OPEN" ] \
    || [ "$(tail -1 "$TMP/out")" != "$RECALL_CLOSE" ]; then
    notice "ltm query 沒有回傳完整的回想區塊"
fi
cat "$TMP/out"; stat hit
exit 0
