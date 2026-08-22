#!/bin/sh
# 對 measure-rrf-ties 探針跑三組手算過答案的固定輸入，逐字比對輸出。
# 用法：sh scripts/rrf-tie-fixtures/run-fixtures.sh <探針執行檔>
set -e
PROBE="${1:?用法：run-fixtures.sh <探針執行檔>}"
DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '測試\n' > "$TMP/q.txt"
# 兩個根都要給（探針的守衛要求），但 fixture 是假的 ltm、根本不會用到它們。
export LTM_CORPUS_ROOT="$TMP" LTM_DERIVED_ROOT="$TMP"

fail=0
check() {
  name="$1"; expect="$2"
  got=$("$PROBE" "$DIR/$name" "$TMP/q.txt" 20 2>/dev/null | grep '^| \*\*全部\*\*')
  if [ "$got" = "$expect" ]; then
    echo "✓ $name"
  else
    echo "✗ $name"; echo "  期望：$expect"; echo "  實得：$got"; fail=1
  fi
}

check basic \
  '| **全部** | 1 | 6 | 80.0% | 60.0% | 100.0% | 2 | 83.3% | 3 |'
# 這一條是 #18 verify R1 的 HIGH-4 回歸鎖：把探針改回解析 Double 就會變紅。
check ulp-neighbours \
  '| **全部** | 1 | 2 | 0.0% | 0.0% | 0.0% | 0 | 0.0% | — |'
check score-in-snippet \
  '| **全部** | 1 | 3 | 50.0% | 50.0% | 100.0% | 1 | 66.7% | 2 |'

exit $fail
