#!/bin/sh
# #18 量測紀錄裡「機制表」的產生工具。
#
# 初版那張表是用一行 inline python 產的、沒有提交，於是表格裡的數字無法對照到
# 任何可重跑的東西（#18 verify R1）。這支腳本就是那張表。
#
# 它印的是：每個查詢的 trigram 命中數、單通道候選的分組、以及相鄰平手數——
# 用來檢查「平手是否來自兩組互斥的單通道候選在名次上對撞」這個假說。
#
# **隱私**：只印查詢字串（自撰）、通道名稱與計數，不印任何命中片段。
#
# 用法：
#   LTM_CORPUS_ROOT=<語料> LTM_DERIVED_ROOT=<索引> \
#     sh scripts/rrf-tie-mechanism.sh <ltm 執行檔> [查詢...]
set -e
LTM="${1:?用法：rrf-tie-mechanism.sh <ltm 執行檔> [查詢...]}"
shift
: "${LTM_CORPUS_ROOT:?兩個根都必須顯式指定（同 measure-rrf-ties 的守衛）}"
: "${LTM_DERIVED_ROOT:?兩個根都必須顯式指定（同 measure-rrf-ties 的守衛）}"
[ "$#" -gt 0 ] || set -- 測試 索引 記憶 快取 型別 相容性 一致性 資料庫

printf '| 查詢 | trigram 命中 | 單通道組 | 相鄰平手 |\n'
printf '|---|---:|---|---:|\n'
for q in "$@"; do
  "$LTM" query "$q" --json --k 20 --all-projects 2>/dev/null | python3 -c '
import json, sys, collections
q = sys.argv[1]
hits = json.load(sys.stdin)
trigram = sum(1 for h in hits if "trigram" in h["channels"])
solo = collections.Counter(
    h["channels"][0] for h in hits if len(h["channels"]) == 1)
# 平手用**原始 token 字串**比對的等價做法：json 模組的 float 解析是正確捨入的
# （與 Foundation 的 JSONSerialization 不同），所以這裡解析後比較是安全的。
ties = sum(1 for i in range(1, len(hits))
           if hits[i]["score"] == hits[i-1]["score"]
           and hits[i]["band"] == hits[i-1]["band"])
groups = "、".join(f"`{k}`×{v}" for k, v in sorted(solo.items())) or "（無）"
print(f"| `{q}` | {trigram} | {groups} | {ties} |")
' "$q"
done
