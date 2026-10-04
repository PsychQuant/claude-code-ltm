#!/bin/zsh
# #60 Expected 1 補量（量測紀錄 docs/measurements/2026-09-07-gate-first-touch.md 的表 9–11）：
# ltm 路徑上的 cache_size／mmap、CLI 冷態、#58 條件重現。只印計數與時間，不印任何一列。
# 表 9–11 是它的前身跑的（量測的順序、命令與參數與 1104d49 的這支腳本相同；差別見紀錄的方法段）。之後為 #60
# verify 加的：setopt pipefail；任何一次量測或 log 寫入失敗就停；探針與 CLI 的輸出裡沒有讀數、harness 的讀數
#   不是兩行就停；沒有 -wal 就拒跑（sudo 與建置之前）；冷樣本開跑前要讀到 0 頁常駐；常駐讀數格式不對就停；讀不到 mtime、或 mtime 在途中變了就停；harness 回的 rows（與
#   --old-sql 的 q1）不是 no-op 的值就停；CLI 加 -init /dev/null，開跑前在暫存檔上確認它的預設是 mmap_size=0、
#   cache_size=2000；前置檢查不跳過 dangling symlink；下面列的路徑有未 commit 的改動就拒跑（建置前後各查一次）；
#   harness 建好後複製到暫存目錄再跑，log 記它的 SHA-256；路徑含 URI 特殊字元就拒跑；mtime 連日期記；結束時撤銷
#   sudo；GATE_MATRIX_DB（測試用）。
# #61（gate-structural-counts）：Q1／Q2 與 A、B 段量的是結構計數版的閘（layout 6；在 layout 5 的索引上 harness、探針
#   與 CLI 都會報 no such column 而停）。D 段在同一個檔、同一個窗口交錯量 #61 之前（--pre61-sql、P1／P2）與之後的閘，
#   暖態三輪（兩臂都先暖過；每輪輪換兩臂的先後）、冷態每臂一個樣本；那是 #61 量測紀錄的 A/B。
#   GATE_MATRIX_SECTIONS 選要跑的段（預設 ABCD；#61 的 6.1 只要 D：GATE_MATRIX_SECTIONS=D）。
#   layout 6 的檢查（四張表都在）在 sudo 之前做——GATE_MATRIX_DB，或不跑 A 段時；預設路徑又要跑 A 段時不做，
#   因為它會讀索引的第 1 頁，A 段第一個樣本就不再是自然冷；那時 layout 5 的索引要到 sudo 之後的第一次 warmup 才停。
# 用法：在自己的終端機執行  zsh scripts/probes/gate-matrix.sh
#   不要用 sudo 跑整個腳本（ltm 開索引會檢查擁有者，root 會被拒）；開頭問一次 sudo 密碼，只給 purge 用，
#   結束時 `sudo -k` 撤銷（這個終端機先前的 sudo 憑證也會一起失效，提早失敗時也是）。
#   每個冷樣本前跑一次 purge（四段全跑共 11 次：B 5、C 2、D 4）：整台機器的檔案快取都會被清掉，會干擾別的 session 的效能與量測——
#   不要在別人也在量的時候跑。
#   Sources/、Package.swift、harness、探針或這支腳本有未 commit 的改動就拒跑（log 只記 HEAD）。
#   log 寫在 repo 外（mktemp），結束時（不論成敗，SIGKILL 除外）印出路徑。
#   GATE_MATRIX_DB 可指向另一個 ltm 索引（測試用；log 會標記）。harness 以讀寫開檔、會把目標設成 WAL，
#   所以指向的檔若不是 ltm 索引就拒跑（以 immutable 唯讀檢查，不寫主檔、-wal 或 -shm；immutable 不讀 WAL，
#   schema 還沒 checkpoint 的索引會被誤拒——覆寫的索引要先 checkpoint、沒有並行寫入者）；預設是
#   ~/.claude-ltm/derived/index.sqlite3。沒有 -wal 就拒跑（在型別與 schema 檢查之後、sudo 與建置之前；harness 以
#   讀寫開檔會建出它）。
#   mtime 的比對依賴 macOS 系統 SQLite 關檔後保留 0 B 的 -wal（persistent WAL）；改連別的 SQLite 時，關檔可能
#   刪掉 -wal，腳本會停在讀不到 mtime。
#   mtime 只到秒，字串沒變不完全保證沒有寫入。
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
# fail 不經過 emit（log 寫不進去時不能再靠它）。
fail() { print -r -- "FAIL: $*" >&2; { print -r -- "FAIL: $*" >> "$OUT"; } 2>/dev/null; exit 1; }
emit() { print -r -- "$1" | tee -a "$OUT" || { print -r -- "FAIL: log 寫不進 $OUT" >&2; exit 1; }; }
log() { emit "$*"; }
# 目前的閘（#61 的結構計數版）與 #61 之前的閘；兩組都要與 IndexDatabase／gate-harness 的 SQL 相同。
Q1="SELECT COUNT(*) FROM chunks WHERE source_count = 0;"
Q2="SELECT source_key FROM source_chunk_counts EXCEPT SELECT source_key FROM scan_state;"
P1="SELECT COUNT(*) FROM chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_sources);"
P2="SELECT source_key FROM chunk_sources EXCEPT SELECT source_key FROM scan_state;"
OQ2="SELECT DISTINCT s.source_key FROM chunk_sources s LEFT JOIN scan_state c ON c.source_key = s.source_key WHERE c.source_key IS NULL;"

# ── 前置檢查：路徑不含 URI 特殊字元（CLI 以 file: URI 開檔）；主檔必須存在；每個存在的檔（含 dangling
#    symlink）都要是 1 Regular File <uid>；工作樹乾淨 ──
case "$DB" in *[#?%]*) fail "路徑含 #、? 或 %，CLI 的 file: URI 會開到別的檔：$DB" ;; esac
[ -f "$DB" ] || fail "找不到 $DB"
ME=$(id -u)
for f in "$DB" "$DB-wal" "$DB-shm" "$DB-journal"; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  s=$(stat -f '%l %HT %u' "$f")
  [ "$s" = "1 Regular File $ME" ] || fail "不跑：$f 是「$s」"
done
require_clean() {
  local dirty
  dirty=$(git -C "$REPO" status --porcelain -- Sources Package.swift Package.resolved scripts/gate-harness \
            scripts/probes/gate-first-touch.c scripts/probes/gate-matrix.sh) || fail 'git status 失敗'
  [ -z "$dirty" ] || fail '有未 commit 的改動（Sources/、Package.swift、harness、探針或這支腳本）：先 commit 或 stash'
}
require_clean
SECTIONS="${GATE_MATRIX_SECTIONS:-ABCD}"
[[ "$SECTIONS" =~ '^[ABCD]+$' ]] || fail "GATE_MATRIX_SECTIONS 只能由 A、B、C、D 組成：$SECTIONS"
has() { [[ "$SECTIONS" == *$1* ]]; }
# 覆寫時先以唯讀確認它是 layout 6 的 ltm 索引（不然 harness 會把它改成 WAL 才失敗，或要到 sudo 之後才因
# no such column 停下）。immutable 只看主檔，schema 還在 WAL 裡時會誤拒（安全的方向）。
# 預設路徑又要跑 A 段時不做這一步：它會讀索引的第 1 頁，A 段的 warmup 就不再是自然冷。
if [ -n "${GATE_MATRIX_DB:-}" ] || ! has A; then
  n=$(sqlite3 -init /dev/null "file:$DB?mode=ro&immutable=1" \
        "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name IN ('chunks','chunk_sources','scan_state','source_chunk_counts');" 2>&1) \
    || fail "讀不到 $DB 的 schema"
  [ "$n" = 4 ] || fail "$DB 不是 layout 6 的 ltm 索引（缺 chunks／chunk_sources／scan_state／source_chunk_counts 其中之一）"
fi
# 沒有 -wal 就拒跑：harness 以讀寫開檔會建出它，後面 mtime 的比對會因此誤停。
[ -f "$DB-wal" ] || fail "沒有 $DB-wal（harness 以讀寫開檔會建出它，mtime 的比對會因此誤停）：先建出它——預設路徑跑一次 ltm query；GATE_MATRIX_DB 跑 /usr/bin/sqlite3 -init /dev/null <檔> 'PRAGMA journal_mode;'（要印出 wal；只開檔、不跑語句不會建出 -wal）"

# ── sudo：只問一次，背景保持有效到腳本結束，結束時撤銷 ──
echo '輸入一次 sudo 密碼（只用來執行 purge；結束時撤銷）：'
sudo -v || fail 'sudo -v 失敗'
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &
KEEP=$!
W=$(mktemp -d) || fail 'mktemp -d 失敗'

# ── 建置：C 探針放在暫存目錄；harness 在 repo 建置後複製到暫存目錄（別的 session 重新建置換不掉它）──
cc -O2 -o "$W/gtf" "$REPO/scripts/probes/gate-first-touch.c" -lsqlite3 || fail '探針建置失敗'
(cd "$REPO" && swift build -c release --product gate-harness > "$W/build.log" 2>&1) || { tail -20 "$W/build.log"; fail 'harness 建置失敗'; }
cp "$REPO/.build/release/gate-harness" "$W/gate-harness" || fail 'harness 複製失敗'
H="$W/gate-harness"; P="$W/gtf"
require_clean
# CLI 的預設設定：在暫存目錄的空檔上讀（不碰索引），不是 mmap_size=0、cache_size=2000 就停。
CLISET=$(sqlite3 -init /dev/null "$W/cli-defaults.sqlite3" 'PRAGMA mmap_size;' 'PRAGMA cache_size;' 2>&1 | tr '\n' ' ') \
  || fail 'CLI 讀回預設設定失敗'
[ "$CLISET" = '0 2000 ' ] || fail "CLI 的預設設定是「$CLISET」，不是 mmap_size=0、cache_size=2000"

MTFMT='%Y-%m-%d %H:%M:%S'
# 主檔或 -wal 讀不到就回非零（呼叫端 || fail）；沒有 -wal 已在 sudo 之前擋掉，之後才消失的由這裡擋下。
mtimes() { stat -f '%Sm' -t "$MTFMT" "$DB" "$DB-wal" | tr '\n' ' '; }
MT0=$(mtimes) || fail '讀不到索引的 mtime'
# 每一步記負載、常駐頁數、主檔與 -wal 的 mtime；常駐讀數格式不對、或 mtime 與開頭不同就停（harness 自己關檔時
# 若做了 checkpoint 也會讓它停）。常駐讀數留在 LAST_RES 給 cold() 檢查。
state() {
  LAST_RES=$("$P" "$DB" --residency) || fail '讀常駐頁數失敗'
  [[ "$LAST_RES" == "residency before resident="<->" of="<->" page="<-> ]] || fail "常駐讀數不對：$LAST_RES"
  local mt; mt=$(mtimes) || fail '讀不到索引的 mtime'
  log "## $1 $(date +%H:%M:%S) load=$(sysctl -n vm.loadavg) $LAST_RES mtime=$mt"
  [ "$mt" = "$MT0" ] || fail "索引在量測途中被寫入（mtime 從 $MT0 變成 $mt）"
}
# 三個 run_*：先收下輸出與退出碼再寫 log，任何一次失敗就停。
run_h() {
  log "-- harness $*"
  local o rc exp=' rows=0' r
  [[ " $* " == *" --old-sql "* || " $* " == *" --pre61-sql "* ]] && exp=' rows=1 q1=0'
  o=$("$H" "$DB" 1 2 "$@" 2>&1); rc=$?
  emit "$o"
  [ $rc -eq 0 ] || fail "harness $* 回 $rc"
  # 一條連線、兩次呼叫：恰好兩行讀數。no-op 狀態：閘模式 rows=0；--old-sql／--pre61-sql 是兩條 SQL 的列數加總
  # （Q1 的 COUNT 一列、Q2 零列）＝1，且 Q1 的 COUNT 值 q1=0。
  local -a reads; reads=( ${(M)${(@f)o}:#conn=1 rep=<-> *} )
  (( ${#reads} == 2 )) || fail "harness $* 的讀數不是兩行（${#reads} 行）"
  for r in $reads; do
    [[ "$r" == *"$exp" ]] || fail "harness $* 回的不是 no-op 的值（要${exp}）"
  done
}
run_p() {
  log "-- probe $*"
  local o rc
  o=$("$P" "$DB" --conns 1 --reps 2 "$@" 2>&1); rc=$?
  emit "${(F)${(@)${(@f)o}:#residency*}}"
  [ $rc -eq 0 ] || fail "probe $* 回 $rc"
  (( ${#${(@M)${(@f)o}:#*rep=*}} > 0 )) || fail "probe $* 的輸出裡沒有讀數"
}
# CLI：-init /dev/null 不讀 ~/.sqliterc；stdout 丟掉（不印任何一列），只留 time -p 的 real 與錯誤行。
# 用法：run_cli <標籤> <Q1> <Q2>。
run_cli() {
  log "-- cli $1"
  local o rc
  o=$( { /usr/bin/time -p sqlite3 -init /dev/null "file:$DB?mode=ro" "$2" "$3" > /dev/null; } 2>&1 ); rc=$?
  emit "${(F)${(@M)${(@f)o}:#*(real|rror)*}}"
  [ $rc -eq 0 ] || fail "cli $1 回 $rc"
  (( ${#${(@M)${(@f)o}:#real *}} > 0 )) || fail "cli $1 的輸出裡沒有 real 那一行"
}
# 冷樣本：purge 之後讀到 0 頁常駐才開跑，否則停（不輪詢；讀完到開跑之間仍可能被別的行程讀暖）。
cold() {
  sync
  sudo -n /usr/sbin/purge || fail 'purge 失敗'
  state "cold-before $1"
  [[ "$LAST_RES" == *' resident=0 '* ]] || fail "purge 之後仍有頁常駐，這個樣本不算冷（$1）"
}

log "# #60 gate matrix $(date '+%Y-%m-%d %H:%M:%S %z')  sqlite=$(sqlite3 --version | cut -d' ' -f1)"
log "# 版本：$(git -C "$REPO" rev-parse --short HEAD)；DB $(stat -f '%z' "$DB") B${GATE_MATRIX_DB:+（GATE_MATRIX_DB 覆寫，不是預設的索引）}；段：$SECTIONS"
log "# harness sha256=$(shasum -a 256 "$H" | cut -d' ' -f1)；CLI 預設 mmap_size cache_size = $CLISET"

# ── A. 暖態：目前的閘 SQL，三條路徑、三種設定，三輪交錯 ──
if has A; then
state warmup; run_h > /dev/null; run_cli gate "$Q1" "$Q2" > /dev/null
for round in 1 2 3; do
  state "warm round=$round"
  run_h
  run_h --cache-size -1000000
  run_h --no-mmap
  run_p --mmap
  run_p --mmap --cache-size -1000000
  run_p
  run_cli gate "$Q1" "$Q2"
done
state warm-end
fi

# ── B. 冷態：目前的閘 SQL，每種一個樣本（每個之前 purge）──
if has B; then
cold h-default;  run_h;                        state after
cold h-cache;    run_h --cache-size -1000000;  state after
cold h-nommap;   run_h --no-mmap;              state after
cold p-mmap;     run_p --mmap;                 state after
cold cli-gate;   run_cli gate "$Q1" "$Q2";     state after
fi

# ── C. #58 條件重現：#58 修正之前的 SQL、不開 mmap；ltm 路徑對 CLI ──
if has C; then
state warmup-old; run_h --old-sql --no-mmap > /dev/null; run_cli old "$P1" "$OQ2" > /dev/null
for round in 1 2 3; do
  state "old warm round=$round"
  run_h --old-sql --no-mmap
  run_cli old "$P1" "$OQ2"
done
cold h-old;   run_h --old-sql --no-mmap; state after
cold cli-old; run_cli old "$P1" "$OQ2";  state after
fi

# ── D. #61 的 A/B：同一個檔、同一個窗口，#61 之前的閘對結構計數版的閘（ltm 的設定）；暖態三輪交錯、冷態每臂一個樣本 ──
# 兩臂都先暖過（只暖一臂的話，另一臂第一輪的第一次呼叫會付首次觸碰）；每輪輪換先後，順序不固定在同一邊（R1-13）。
if has D; then
d_pre61() { run_h --pre61-sql; run_cli pre61 "$P1" "$P2"; }
d_gate()  { run_h;             run_cli gate "$Q1" "$Q2"; }
state warmup-61
run_h --pre61-sql > /dev/null; run_cli pre61 "$P1" "$P2" > /dev/null
run_h > /dev/null;             run_cli gate "$Q1" "$Q2" > /dev/null
for round in 1 2 3; do
  if (( round % 2 )); then
    state "61 warm round=$round order=pre61,gate"; d_pre61; d_gate
  else
    state "61 warm round=$round order=gate,pre61"; d_gate; d_pre61
  fi
done
cold h-pre61;   run_h --pre61-sql;           state after
cold h-gate61;  run_h;                       state after
cold cli-pre61; run_cli pre61 "$P1" "$P2";   state after
cold cli-gate61; run_cli gate "$Q1" "$Q2";   state after
fi

log "# 完成 $(date +%H:%M:%S)"
