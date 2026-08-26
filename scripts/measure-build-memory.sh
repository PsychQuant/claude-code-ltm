#!/bin/bash
# 量 `ltm build` 的峰值 RSS 對語料規模的關係（#46）。
#
# 用**合成**語料而不是真實語料的單一觀察：三個點才看得出線性與否，而真實語料
# 只給得出一個點，且要等數十分鐘。合成語料的 chunk 大小分布與真實不同——這是
# 已知的限度，寫在產出的紀錄裡。
set -u
BIN="${1:?用法: measure-build-memory.sh <ltm binary path>}"
KEY=$(python3 -c "print('ab'*32)")
printf 'turns\tchunks\tpeak_rss_mb\twall_s\n'
for TURNS in 200 800 3200; do
  T=$(mktemp -d); mkdir -p "$T/corpus/proj-a" "$T/derived"
  python3 - "$T/corpus/proj-a" "$TURNS" <<'PY'
import sys, json, os
d, n = sys.argv[1], int(sys.argv[2])
per = 50
for f in range((n + per - 1)//per):
    with open(os.path.join(d, f"s{f:04d}.jsonl"), "w") as fh:
        for i in range(min(per, n - f*per)):
            k = f*per + i
            fh.write(json.dumps({
                "type": "user" if k % 2 == 0 else "assistant",
                "uuid": f"{k:08x}-aaaa-bbbb-cccc-dddddddddddd",
                "sessionId": "11111111-2222-3333-4444-555555555555",
                "timestamp": "2026-01-01T00:00:00Z",
                "message": {"role": "user" if k % 2 == 0 else "assistant",
                            "content": f"第 {k} 段內容。" + "測試語料需要足夠長度才能切成 chunk。" * 12},
            }, ensure_ascii=False) + "\n")
PY
  OUT=$( { /usr/bin/time -l env LTM_CORPUS_ROOT="$T/corpus" LTM_DERIVED_ROOT="$T/derived" \
      LTM_ANCHOR_KEY="$KEY" "$BIN" build --quiet; } 2>&1 )
  CH=$(printf '%s' "$OUT" | grep -oE '索引總計：[0-9]+' | grep -oE '[0-9]+')
  RSS=$(printf '%s' "$OUT" | grep "maximum resident set size" | awk '{printf "%.0f", $1/1048576}')
  WALL=$(printf '%s' "$OUT" | grep -E "^ *[0-9.]+ real" | awk '{print $1}')
  printf '%s\t%s\t%s\t%s\n' "$TURNS" "${CH:-?}" "${RSS:-?}" "${WALL:-?}"
  rm -rf "$T"
done
