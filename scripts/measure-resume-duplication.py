import json, os, hashlib, collections, sys

root = os.path.expanduser("~/.claude/projects")
files = []
for d, _, names in os.walk(root):
    for n in names:
        if n.endswith(".jsonl"):
            files.append(os.path.join(d, n))
files.sort()
print(f"語料檔總數：{len(files)}")

# uuid -> list of (file, sessionId, content_hash)
seen = collections.defaultdict(list)
parsed = skipped = 0
for path in files:
    try:
        with open(path, "rb") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    o = json.loads(raw)
                except Exception:
                    skipped += 1
                    continue
                uuid = o.get("uuid"); sid = o.get("sessionId"); msg = o.get("message")
                if not (isinstance(uuid, str) and isinstance(sid, str) and isinstance(msg, dict)):
                    skipped += 1
                    continue
                c = msg.get("content")
                text = c if isinstance(c, str) else json.dumps(c, sort_keys=True, ensure_ascii=False)
                seen[uuid].append((path, sid, hashlib.sha256(text.encode()).hexdigest()))
                parsed += 1
    except Exception:
        continue

multi = {u: v for u, v in seen.items() if len({p for p, _, _ in v}) > 1}
same_content = sum(1 for v in multi.values() if len({h for _, _, h in v}) == 1)
diff_session = sum(1 for v in multi.values() if len({s for _, s, _ in v}) > 1)
same_ts_pairs = 0

print(f"解析出的 turn 紀錄：{parsed}（跳過 {skipped}）")
print(f"不同 uuid 數：{len(seen)}")
print(f"出現在一個以上檔案的 uuid：{len(multi)}")
print(f"  其中內容完全相同：{same_content}（{same_content/max(len(multi),1)*100:.1f}%）")
print(f"  其中 sessionId 不同：{diff_session}（{diff_session/max(len(multi),1)*100:.1f}%）")
