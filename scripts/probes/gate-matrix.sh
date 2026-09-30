#!/bin/zsh
# #60 Expected 1 補量（量測紀錄 docs/measurements/2026-09-07-gate-first-touch.md 的表 9–11）：
# ltm 路徑上的 cache_size／mmap、CLI 冷態、#58 條件重現。只印計數與時間，不印任何一列。
# 表 9–11 是它的前身跑的（量測本體相同；差別見紀錄的方法段），之後為 #60 verify R8 加了：
# 任何一次量測失敗就停、冷樣本開跑前要讀到 0 頁常駐、CLI 不讀 ~/.sqliterc、工作樹要乾淨、結束時撤銷 sudo。
# 用法：在自己的終端機執行  zsh scripts/probes/gate-matrix.sh
#   不要用 sudo 跑整個腳本（ltm 開索引會檢查擁有者，root 會被拒）；開頭問一次 sudo 密碼，只給 purge 用，
#   結束時 `sudo -k` 撤銷（這個終端機先前的 sudo 憑證也會一起失效）。
#   每個冷樣本前跑一次 purge（共 7 次）：整台機器的檔案快取都會被清掉，會干擾別的 session 的效能與量測——
#   不要在別人也在量的時候跑。
#   harness 在 repo 的工作樹裡建置；Sources/、Package.swift、harness 或探針有未 commit 的改動就拒跑
#   （log 只記 HEAD，髒的工作樹會讓記下的版本不等於量到的程式碼）。
#   log 寫在 repo 外（mktemp），結束時（不論成敗）印出路徑。
#   GATE_MATRIX_DB 可指向另一個 ltm 索引（測試用）；預設是 ~/.claude-ltm/derived/index.sqlite3。
set -u
setopt pipefail
if [ "$(id -u)" = 0 ]; then echo '不要用 sudo 跑整個腳本：ltm 開索引會檢查擁有者，root 會被拒。' >&2; exit 1; fi
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 1
DB="${GATE_MATRIX_DB:-$HOME/.claude-ltm/derived/index.sqlite3}"
OUT=$(mktemp -t gate-matrix) || exit 1
KEEP='' W=''
cleanup() {
  if [ -n "$KEEP" ]; then kill "$KEEP" 2>/dev/null; fi
  if [ -n "$W" ]; then rm -rf "$W"; fi
  sudo -k 2>/dev/null
  print -r -- "log：$OUT" >&2
}
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 141' PIPE
fail() { print -r -- "FAIL: $*" | tee -a "$OUT" >&2; exit 1; }
Q1="SELECT COUNT(*) FROM chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_sources);"
Q2="SELECT source_key FROM chunk_sources EXCEPT SELECT source_key FROM scan_state;"
OQ2="SELECT DISTINCT s.source_key FROM chunk_sources s LEFT JOIN scan_state c ON c.source_key = s.source_key WHERE c.source_key IS NULL;"

# ── 前置檢查：主檔必須存在，每個存在的檔（含 dangling symlink）都要是 1 Regular File <uid> ──
[ -f "$DB" ] || fail "找不到 $DB"
ME=$(id -u)
for f in "$DB" "$DB-wal" "$DB-shm" "$DB-journal"; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  s=$(stat -f '%l %HT %u' "$f")
  [ "$s" = "1 Regular File $ME" ] || fail "不跑：$f 是「$s」"
done
DIRTY=$(git -C "$REPO" status --porcelain -- Sources Package.swift Package.resolved scripts/gate-harness scripts/probes/gate-first-touch.c) \
  || fail 'git status 失敗'
[ -z "$DIRTY" ] || fail '工作樹有未 commit 的改動（Sources/、Package.swift、harness 或探針）：先 commit 或 stash'

# ── sudo：只問一次，背景保持有效到腳本結束，結束時撤銷 ──
echo '輸入一次 sudo 密碼（只用來執行 purge；結束時撤銷）：'
sudo -v || fail 'sudo -v 失敗'
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &
KEEP=$!
W=$(mktemp -d) || fail 'mktemp -d 失敗'

# ── 建置：C 探針放在 repo 外的暫存目錄；harness 是 repo 裡的 executable target ──
cc -O2 -o "$W/gtf" "$REPO/scripts/probes/gate-first-touch.c" -lsqlite3 || fail '探針建置失敗'
(cd "$REPO" && swift build -c release --product gate-harness > "$W/build.log" 2>&1) || { tail -20 "$W/build.log"; fail 'harness 建置失敗'; }
H="$REPO/.build/release/gate-harness"; P="$W/gtf"

log() { print -r -- "$*" | tee -a "$OUT"; }
# 每一步記負載、常駐頁數、主檔與 -wal 的 mtime（含日期）；常駐讀數留在 LAST_RES 給 cold() 檢查。
state() {
  LAST_RES=$("$P" "$DB" --residency) || fail '讀常駐頁數失敗'
  log "## $1 $(date +%H:%M:%S) load=$(sysctl -n vm.loadavg) $LAST_RES mtime=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$DB" "$DB-wal" | tr '\n' ' ')"
}
# 三個 run_*：先收下輸出與退出碼再寫 log，任何一次失敗就停。
run_h() {
  log "-- harness $*"
  local o rc
  o=$("$H" "$DB" 1 2 "$@" 2>&1); rc=$?
  print -r -- "$o" | tee -a "$OUT"
  [ $rc -eq 0 ] || fail "harness $* 回 $rc"
}
run_p() {
  log "-- probe $*"
  local o rc
  o=$("$P" "$DB" --conns 1 --reps 2 "$@" 2>&1); rc=$?
  print -r -- "$o" | command grep -v '^residency' | tee -a "$OUT"
  [ $rc -eq 0 ] || fail "probe $* 回 $rc"
}
# CLI：-init /dev/null 不讀 ~/.sqliterc；stdout 丟掉（不印任何一列），只留 time -p 的 real 與錯誤行。
run_cli() {
  log "-- cli $1"
  local o rc
  o=$( { /usr/bin/time -p sqlite3 -init /dev/null "file:$DB?mode=ro" "$Q1" "$2" > /dev/null; } 2>&1 ); rc=$?
  print -r -- "$o" | command grep -E 'real|rror' | tee -a "$OUT"
  [ $rc -eq 0 ] || fail "cli $1 回 $rc"
}
# 冷樣本：purge 之後讀到 0 頁常駐才開跑，否則停（不輪詢；讀完到開跑之間仍可能被別的行程讀暖）。
cold() {
  sync
  sudo -n /usr/sbin/purge || fail 'purge 失敗'
  state "cold-before $1"
  [[ "$LAST_RES" == *' resident=0 '* ]] || fail "purge 之後仍有頁常駐，這個樣本不算冷（$1）"
}

log "# #60 gate matrix $(date '+%Y-%m-%d %H:%M:%S %z')  sqlite=$(sqlite3 --version | cut -d' ' -f1)"
log "# 版本：$(git -C "$REPO" rev-parse --short HEAD)；DB $(stat -f '%z' "$DB") B"
CLISET=$(sqlite3 -init /dev/null "file:$DB?mode=ro" 'PRAGMA mmap_size;' 'PRAGMA cache_size;' 2>&1 | tr '\n' ' ') \
  || fail 'CLI 讀回設定失敗'
log "# CLI 設定（同參數的另一個行程讀回）：mmap_size cache_size = $CLISET"

# ── A. 暖態：目前的閘 SQL，三條路徑、三種設定，三輪交錯 ──
state warmup; run_h > /dev/null; run_cli gate "$Q2" > /dev/null
for round in 1 2 3; do
  state "warm round=$round"
  run_h
  run_h --cache-size -1000000
  run_h --no-mmap
  run_p --mmap
  run_p --mmap --cache-size -1000000
  run_p
  run_cli gate "$Q2"
done
state warm-end

# ── B. 冷態：目前的閘 SQL，每種一個樣本（每個之前 purge）──
cold h-default;  run_h;                        state after
cold h-cache;    run_h --cache-size -1000000;  state after
cold h-nommap;   run_h --no-mmap;              state after
cold p-mmap;     run_p --mmap;                 state after
cold cli-gate;   run_cli gate "$Q2";           state after

# ── C. #58 條件重現：#58 修正之前的 SQL、不開 mmap；ltm 路徑對 CLI ──
state warmup-old; run_h --old-sql --no-mmap > /dev/null; run_cli old "$OQ2" > /dev/null
for round in 1 2 3; do
  state "old warm round=$round"
  run_h --old-sql --no-mmap
  run_cli old "$OQ2"
done
cold h-old;   run_h --old-sql --no-mmap; state after
cold cli-old; run_cli old "$OQ2";        state after

log "# 完成 $(date +%H:%M:%S)"
