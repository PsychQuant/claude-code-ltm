#!/usr/bin/env python3
"""語料裡「中英在同一則 turn 內共現」的比重（#43）。

#43 的三種樣態裡，中英別名（擴散激發 ↔ spreading activation）是唯一一種有機械
量法的：**如果兩種寫法本來就常常出現在同一則 turn 裡，那麼用任一種查都會 lexical
命中那則 turn，別名表買到的東西就小。**

量的是共現，不是等價——見輸出的誠實邊界。
"""
import json, os, random, re, sys, unicodedata

CJK = re.compile(r'[一-鿿]')
# 技術性拉丁 token：長度 ≥3 的英數（含 . _ -），排除純數字
LATIN_TOK = re.compile(r'[A-Za-z][A-Za-z0-9._-]{2,}')

def turns(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            msg = rec.get('message') or {}
            if rec.get('type') not in ('user', 'assistant'):
                continue
            content = msg.get('content')
            if isinstance(content, str):
                yield content
            elif isinstance(content, list):
                parts = [b.get('text', '') for b in content
                         if isinstance(b, dict) and b.get('type') == 'text']
                if parts:
                    yield '\n'.join(parts)

def main():
    root = os.path.expanduser('~/.claude/projects')
    files = []
    for dirpath, _, names in os.walk(root):
        for n in names:
            if n.endswith('.jsonl'):
                p = os.path.join(dirpath, n)
                try:
                    if os.path.getsize(p) > 20 * 1024:
                        files.append(p)
                except OSError:
                    pass
    random.seed(43)                      # 確定性取樣：同一份語料重跑結果相同
    sample = random.sample(files, min(120, len(files)))

    total = cjk_only = latin_only = both = neither = 0
    latin_tokens_in_cjk_turns = 0
    for p in sample:
        for text in turns(p):
            if not text.strip():
                continue
            total += 1
            has_cjk = bool(CJK.search(text))
            toks = LATIN_TOK.findall(text)
            has_lat = bool(toks)
            if has_cjk and has_lat:
                both += 1
                latin_tokens_in_cjk_turns += len(set(t.lower() for t in toks))
            elif has_cjk:
                cjk_only += 1
            elif has_lat:
                latin_only += 1
            else:
                neither += 1

    def pct(n):
        return f"{100.0 * n / total:.1f}%" if total else "n/a"

    print(f"檔案（>20KB）總數 {len(files)}，取樣 {len(sample)}")
    print(f"有文字的 turn：{total}")
    print(f"  中英共現（同一則 turn 內）：{both}（{pct(both)}）")
    print(f"  只有中文：{cjk_only}（{pct(cjk_only)}）")
    print(f"  只有拉丁 token：{latin_only}（{pct(latin_only)}）")
    print(f"  兩者皆無：{neither}（{pct(neither)}）")
    cjk_bearing = both + cjk_only
    if cjk_bearing:
        print(f"  含中文的 turn 裡有拉丁 token 的比例：{100.0*both/cjk_bearing:.1f}%")
    if both:
        print(f"  共現 turn 的平均相異拉丁 token 數：{latin_tokens_in_cjk_turns/both:.1f}")

if __name__ == '__main__':
    main()
