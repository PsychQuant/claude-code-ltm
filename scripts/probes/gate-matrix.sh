#!/bin/zsh
# #60 Expected 1 補量（量測紀錄 docs/measurements/2026-09-07-gate-first-touch.md 的表 9–11）：
# ltm 路徑上的 cache_size／mmap、CLI 冷態、#58 條件重現。只印計數與時間，不印任何一列。
# 用法：在自己的終端機執行  zsh scripts/probes/gate-matrix.sh
#   不要用 sudo 跑整個腳本（ltm 開索引會檢查擁有者，root 會被拒）；開頭問一次 sudo 密碼，只給 purge 用。
#   每個冷樣本前跑一次 purge（共 7 次）：整台機器的檔案快取都會被清掉。
#   log 寫在 repo 外（mktemp），結束時印出路徑。
set -u
if [ "$(id -u)" = 0 ]; then echo '不要用 sudo 跑整個腳本：ltm 開索引會檢查擁有者，root 會被拒。' >&2; exit 1; fi
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel) || exit 1
DB="$HOME/.claude-ltm/derived/index.sqlite3"
OUT=$(mktemp -t gate-matrix) || exit 1
Q1="SELECT COUNT(*) FROM chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_sources);"
Q2="SELECT source_key FROM chunk_sources EXCEPT SELECT source_key FROM scan_state;"
OQ2="SELECT DISTINCT s.source_key FROM chunk_sources s LEFT JOIN scan_state c ON c.source_key = s.source_key WHERE c.source_key IS NULL;"

# ── 前置檢查：主檔那一行必須出現，每個存在的檔都要是 1 Regular File <uid> ──
[ -f "$DB" ] || { echo "找不到 $DB" >&2; exit 1; }
ME=$(id -u)
for f in "$DB" "$DB-wal" "$DB-shm" "$DB-journal"; do
  [ -e "$f" ] || continue
  s=$(stat -f '%l %HT %u' "$f")
  [ "$s" = "1 Regular File $ME" ] || { echo "不跑：$f 是「$s」" >&2; exit 1; }
done

# ── sudo：只問一次，背景保持有效到腳本結束 ──
echo '輸入一次 sudo 密碼（只用來執行 purge）：'
sudo -v || exit 1
( while kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &
KEEP=$!
W=$(mktemp -d) || exit 1
trap 'kill $KEEP 2>/dev/null; rm -rf "${W:?}"' EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 141' PIPE

# ── 建置：C 探針放在 repo 外的暫存目錄；harness 是 repo 裡的 executable target ──
cc -O2 -o "$W/gtf" "$REPO/scripts/probes/gate-first-touch.c" -lsqlite3 || exit 1
(cd "$REPO" && swift build -c release --product gate-harness > "$W/build.log" 2>&1) || { tail -20 "$W/build.log"; exit 1; }
H="$REPO/.build/release/gate-harness"; P="$W/gtf"

log() { print -r -- "$*" | tee -a "$OUT"; }
state() { log "## $1 $(date +%H:%M:%S) load=$(sysctl -n vm.loadavg) $("$P" "$DB" --residency) mtime=$(stat -f '%Sm' -t '%H:%M:%S' "$DB" "$DB-wal" | tr '\n' ' ')"; }
run_h()  { log "-- harness $*"; "$H" "$DB" 1 2 "$@" 2>&1 | tee -a "$OUT"; }
run_p()  { log "-- probe $*";   "$P" "$DB" --conns 1 --reps 2 "$@" 2>&1 | command grep -v '^residency' | tee -a "$OUT"; }
run_cli(){ log "-- cli $1"; { /usr/bin/time -p sqlite3 "file:$DB?mode=ro" "$Q1" "$2" > /dev/null; } 2>&1 | command grep -E 'real|rror' | tee -a "$OUT"; }
cold()   { sync; sudo -n /usr/sbin/purge || { log 'purge 失敗'; exit 1; }; state "cold-before $1"; }

log "# #60 gate matrix $(date '+%Y-%m-%d %H:%M:%S %z')  sqlite=$(sqlite3 --version | cut -d' ' -f1)"
log "# 版本：$(git -C "$REPO" rev-parse --short HEAD)；DB $(stat -f '%z' "$DB") B"

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

log "# 完成 $(date +%H:%M:%S)；log：$OUT"
