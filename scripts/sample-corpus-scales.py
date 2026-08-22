#!/usr/bin/env python3
"""#18 規模階梯的語料抽樣。**這支腳本存在的理由是可查證性。**

初版沒有提交它，於是 verify 的 devil's advocate 只能**猜**抽樣法——它猜了
`random.sample`，並據此證明「巢狀」不成立。猜錯了：實際用的是 shuffle + 前綴，
那確實巢狀。但那次誤判本身就是這條 finding 的證明——**未提交的方法不可查證**。
（寫可提交版本時另外發現初版有真缺陷：目的地路徑用 `parent.name/name`，不同
project 的同名檔互相覆蓋，檔案層巢狀性確實破了。）

## 為什麼目的地不由呼叫端指定（#18 verify R2）

R1 的版本收一個目的地參數，並自己寫一個「不得在 repo 內」的守衛：

    repo = pathlib.Path(__file__).resolve().parent.parent
    if repo == dest_root or repo in dest_root.parents: ...

那是**字串式路徑比對**，實測四條旁路全部放行：

    BLOCKED  /Users/che/Developer/claude-LTM/tmpdata
    ALLOWED  /Users/che/developer/claude-LTM/tmpdata          ← APFS 大小寫不敏感
    ALLOWED  /System/Volumes/Data/Users/.../claude-LTM/...    ← firmlink
    ALLOWED  ~/.claude/projects/sample                        ← 語料樹內（！）
    ALLOWED  ~/.claude/projects                               ← 語料根本身（！！）

最後兩條會讓 `shutil.rmtree` 與 `copy2` 打在**唯讀語料**上——違反不變式 1，而且是
寫入。前兩條實測會把 `.jsonl` 落進真實工作樹（大小寫那條我驗過是同一個目錄）。

而 `Sources/LTMMemory/EventStore.swift` 的 `CorpusLocation` 就是這件事的正確做法，
它的 doc comment 逐字寫著「複製這段邏輯是不可接受的替代方案——它被 symlink、
`..`、dangling link、firmlink 各咬過一次，兩份實作必然漂移，而漂移的方向是
『放行了不該放行的路徑』且不報錯」。R1 的版本就是那份被禁止的複製品，而且比原版
弱三處：字串前綴而非 inode 身分、字串而非路徑元件、解析失敗時 fail open。

**所以這一版不修那個述詞，而是讓它不需要存在**：目的地由腳本自己用
`tempfile.mkdtemp()` 建立並印出來，呼叫端不提供路徑。沒有外來路徑，就沒有要
判定的東西——這是性質不是列舉。（`$TMPDIR` 理論上仍可被設成奇怪的位置，所以
留一道 inode 身分的 sanity check 當縱深，fail closed。）

隱私（CLAUDE.md 鐵律）：本腳本**只讀** `~/.claude/projects/`。產出的副本是第三方
逐字內容，不得進 git remote——它落在系統暫存區，且 `.gitignore` 另有 `*.jsonl`。

用法：
    python3 scripts/sample-corpus-scales.py [100 400 1600]
印出的根目錄再交給 `ltm build` 與探針使用。
"""
import os
import pathlib
import random
import shutil
import sys
import tempfile

SEED = 42
CORPUS = pathlib.Path(os.path.expanduser("~/.claude/projects"))


def identity(path):
    """(st_dev, st_ino)——路徑的**身分**，不是它的字面文字。

    大小寫差異與 firmlink 都會折疊到同一個 inode，字串比對則不會。解析失敗時
    回 None，呼叫端據此 fail closed。
    """
    try:
        st = os.stat(path)
    except OSError:
        return None
    return (st.st_dev, st.st_ino)


def contains(ancestor, descendant):
    """`descendant` 是否落在 `ancestor` 底下——沿 inode 身分往上走，不比字串。"""
    target = identity(ancestor)
    if target is None:
        return True  # fail closed：問不出祖先的身分就當作命中
    current = pathlib.Path(descendant).resolve()
    while True:
        here = identity(current)
        if here is None:
            return True  # fail closed
        if here == target:
            return True
        if current.parent == current:
            return False
        current = current.parent


def main() -> int:
    scales = [int(a) for a in sys.argv[1:]] or [100, 400, 1600]

    dest_root = pathlib.Path(tempfile.mkdtemp(prefix="ltm-rrf-scales-"))
    repo = pathlib.Path(__file__).resolve().parent.parent
    # 縱深：`$TMPDIR` 被設成 repo 內或語料內時仍要擋。這道檢查走 inode 身分，
    # 所以大小寫與 firmlink 兩條旁路都折疊掉了。
    for name, root in (("repo", repo), ("語料", CORPUS)):
        if contains(root, dest_root):
            print(f"✗ 暫存目的地 {dest_root} 落在{name}（{root}）內。中止。")
            shutil.rmtree(dest_root, ignore_errors=True)
            return 1

    files = sorted(CORPUS.rglob("*.jsonl"))
    if not files:
        print(f"✗ {CORPUS} 下沒有 .jsonl")
        return 1

    # **shuffle 一次、取前綴**——不是 `random.sample`（後者在 k=1600 會換演算法，
    # sample(400) ⊄ sample(1600)）。前綴天然巢狀，所以規模是唯一變動的因素。
    random.seed(SEED)
    random.shuffle(files)

    print(f"語料 {len(files)} 檔，seed={SEED}，來源 {CORPUS}")
    print(f"目的地（由本腳本建立）：{dest_root}")
    for n in scales:
        dest = dest_root / f"n{n}" / "corpus"
        # 目的地路徑用「來源相對於語料根」的**完整**相對路徑。初版用
        # `f.parent.name / f.name`，於是不同 project 下的同名檔互相覆蓋，
        # 而被覆蓋的是哪幾個隨複製順序而定——巢狀性在檔案層因此被打破。
        for f in files[:n]:
            target = dest / f.relative_to(CORPUS)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, target)
        (dest_root / f"n{n}" / "derived").mkdir(parents=True, exist_ok=True)
        landed = sum(1 for _ in dest.rglob("*.jsonl"))
        mb = sum(p.stat().st_size for p in dest.rglob("*.jsonl")) // 1048576
        print(f"  n={n}: {landed} 檔、{mb} MB  {'✓' if landed == n else f'✗ 落地 {landed} ≠ {n}'}")
        if landed != n:
            return 1

    # 巢狀性當場自證，不靠散文宣稱
    sets = {}
    for n in scales:
        base = dest_root / f"n{n}" / "corpus"
        sets[n] = {p.relative_to(base) for p in base.rglob("*.jsonl")}
    for small, large in zip(sorted(scales), sorted(scales)[1:]):
        ok = sets[small] <= sets[large]
        print(f"  巢狀 n{small} ⊆ n{large}: {ok}")
        if not ok:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
