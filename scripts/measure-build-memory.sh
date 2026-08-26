#!/bin/bash
# 量 `ltm build` 的峰值 RSS 對語料規模的關係（#46）。
#
# 用**合成**語料而不是真實語料的單一觀察：三個點才看得出線性與否，而真實語料
# 只給得出一個點，且要等數十分鐘。合成語料的 chunk 大小分布與真實不同——這是
# 已知的限度，寫在產出的紀錄裡。
set -u
BIN="${1:?用法: measure-build-memory.sh <ltm binary path>}"
[ -x "$BIN" ] || { echo "不是可執行檔：$BIN" >&2; exit 2; }

# 這支腳本只跑**合成**語料，所以 key 是字面常數、沒有跨執行的意義。
#
# **不要照抄下面的 `env LTM_ANCHOR_KEY=… ` 形式去跑真實語料**：那會讓真實密鑰
# 進到 `ps` 看得到的 argv。真實語料請用 `export`，並從 keychain 取值：
#   export LTM_ANCHOR_KEY="$(security find-generic-password -s ltm-anchor -w)"
KEY=$(python3 -c "print('ab'*32)")
printf 'turns\tchunks\tpeak_rss_mb\twall_s\n'
for TURNS in 200 800 3200; do
  # mktemp 失敗時 T 會是空字串，後面的 "$T/corpus" 就變成絕對路徑 /corpus——
  # `set -u` 擋不住這個（T 有被賦值，只是賦成空的）。
  T=$(mktemp -d) || { echo "mktemp 失敗" >&2; exit 2; }
  [ -n "$T" ] && [ -d "$T" ] || { echo "mktemp 給出不可用的路徑：'$T'" >&2; exit 2; }
  mkdir -p "$T/corpus/proj-a" "$T/derived"
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

  # 解析失敗要讓整輪失敗，不要印一行帶 `?` 的資料然後繼續。
  #
  # 產出的是一份要被引用的量測紀錄：一份「看似完整、其中一格是 ?」的表格
  # 會被當成有效資料讀，而讀的人不會回頭問那個 ? 是什麼意思。
  if [ -z "$CH" ] || [ -z "$RSS" ] || [ -z "$WALL" ]; then
    echo "解析失敗（turns=${TURNS}）：chunks='$CH' rss='$RSS' wall='$WALL'" >&2
    echo "--- build 輸出 ---" >&2
    printf '%s\n' "$OUT" >&2
    rm -rf "$T"
    exit 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$TURNS" "$CH" "$RSS" "$WALL"
  rm -rf "$T"
done
