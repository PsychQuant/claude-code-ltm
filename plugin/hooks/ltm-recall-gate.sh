#!/bin/bash
# UserPromptSubmit hook：線索閘門 → ltm query --format recall → 注入。
#
# 薄：閘門、逾時降級、把區塊原樣印出。重的東西（有界併入、session 排除、標記）
# 都在 ltm query 裡，CLI 與 MCP 共用。規格：openspec specs/proactive-recall-hook。
#
# 注意：變數後面緊接全形標點要寫 ${VAR}——非 UTF-8 locale 下 bash 會把高位元組併進變數名。
# 三條硬規則：永不 exit 2（那會擋掉使用者的 prompt）；閘門放行後**絕不靜默**
# （失敗一律印一行通知——Claude Code 對逾時的 hook 是靜默丟棄輸出，我們得在
# 那之前自己說話）；閘門未命中與 off 模式才是空輸出。
set -u
LTM_RECALL_MIN_VERSION="0.5.0"   # 第一個有 --format recall 的 ltm；ReleaseVersionSyncTests 釘住
notice() { printf 'ltm：本輪回想未完成（%s）；可手動呼叫 ltm_query\n' "$1"; exit 0; }

MODE="${LTM_RECALL_MODE:-cued}"
case "$MODE" in
    cued|always|off) ;;
    *) echo "ltm: LTM_RECALL_MODE=\"$MODE\" 不認得，當作 cued" >&2; MODE=cued ;;
esac
[ "$MODE" = off ] && exit 0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ltm-recall.XXXXXX") || exit 0
trap 'rm -rf "$TMP"' EXIT

# 抽 prompt / session_id / cwd。python3 是 macOS 內建；prompt 先剝掉別的 hook 注入的
# <system-reminder> 區塊——否則它們的措辭會替使用者觸發回想。
cat > "$TMP/input"   # heredoc 會佔掉 python 的 stdin，所以 hook 的 JSON 先落檔再讀
python3 - "$TMP" <<'PY' 2>/dev/null || exit 0
import json, re, sys
d = json.load(open(sys.argv[1] + "/input"))
prompt = re.sub(r"<system-reminder>.*?</system-reminder>", "", d.get("prompt") or "", flags=re.S)
open(sys.argv[1] + "/prompt", "w").write(prompt)
open(sys.argv[1] + "/meta", "w").write((d.get("session_id") or "") + "\n" + (d.get("cwd") or "") + "\n")
PY
SESSION=$(sed -n 1p "$TMP/meta")
CWD=$(sed -n 2p "$TMP/meta")

if [ "$MODE" = cued ]; then
    ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
    CUES="${LTM_RECALL_CUES:-$ROOT/hooks/recall-cues.txt}"
    if [ ! -r "$CUES" ]; then
        echo "ltm: 線索表讀不到：${CUES}（本輪不回想）" >&2
        exit 0
    fi
    grep -vE '^[[:space:]]*(#|$)' "$CUES" > "$TMP/cues" || true
    [ -s "$TMP/cues" ] || exit 0
    LC_ALL=C grep -E -q -f "$TMP/cues" "$TMP/prompt" || exit 0
fi

LTM="${LTM_BIN:-$HOME/bin/ltm}"
[ -x "$LTM" ] || notice "ltm 未安裝（${LTM}；plugin 的 MCP wrapper 首次啟動時會下載）"
"$LTM" query --help 2>/dev/null | grep -q -- '--format recall' \
    || notice "ltm 版本過舊，需 ≥ $LTM_RECALL_MIN_VERSION"

PROMPT=$(head -c 2000 "$TMP/prompt")
[ -n "$CWD" ] && cd "$CWD" 2>/dev/null
set -- query "$PROMPT" --format recall --k 3 --max-refresh-seconds 15
[ -n "$SESSION" ] && set -- "$@" --exclude-session "$SESSION"
"$LTM" "$@" > "$TMP/out" 2> "$TMP/err" &
PID=$!
# 20 s 守衛（hook 預算 28 s，留 retrieval 與行程啟動的餘裕）。不用 timeout(1)——macOS 沒有內建。
i=0
while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null; sleep 0.2; kill -KILL "$PID" 2>/dev/null
    notice "逾時 20 s"
fi
wait "$PID"; RC=$?
[ "$RC" -eq 0 ] || notice "ltm query 結束碼 ${RC}：$(head -c 200 "$TMP/err" | tr '\n' ' ')"
cat "$TMP/out"
exit 0
