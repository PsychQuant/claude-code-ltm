#!/usr/bin/env python3
"""#18 規模階梯的語料抽樣。**這支腳本存在的理由是可查證性。**

初版沒有提交它，於是 verify 的 devil's advocate 只能**猜**抽樣法——它猜了
`random.sample`，並據此證明「巢狀」不成立（`random.sample` 在 k=1600 會換演算法，
sample(400) ⊄ sample(1600)）。猜錯了：實際用的是 shuffle + 前綴，那確實巢狀。
但那次誤判本身就是這條 finding 的證明——**未提交的方法不可查證**，讀者無從分辨
「作者做對了」與「作者做錯了」。所以方法要以可執行的形式落地，不是散文描述。

隱私（CLAUDE.md 鐵律）：本腳本**只讀** `~/.claude/projects/`，複製到指定的目的地。
目的地必須在 repo 之外（見下方守衛）——語料是第三方逐字內容，不得進 git remote。

用法：
    python3 scripts/sample-corpus-scales.py <目的地根目錄> [100 400 1600]
"""
import os
import pathlib
import random
import shutil
import sys

SEED = 42
CORPUS = pathlib.Path(os.path.expanduser("~/.claude/projects"))


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 64
    dest_root = pathlib.Path(sys.argv[1]).resolve()
    scales = [int(a) for a in sys.argv[2:]] or [100, 400, 1600]

    # 守衛：目的地不得落在 repo 內。語料副本一旦進工作樹，就只剩 .gitignore 擋著，
    # 而那是一份會漏的列舉（初版就漏了 `*.jsonl` 本身）。
    repo = pathlib.Path(__file__).resolve().parent.parent
    if repo == dest_root or repo in dest_root.parents:
        print(f"✗ 目的地 {dest_root} 在 repo ({repo}) 內。語料副本不得進工作樹。")
        return 1

    files = sorted(CORPUS.rglob("*.jsonl"))
    if not files:
        print(f"✗ {CORPUS} 下沒有 .jsonl")
        return 1

    # **shuffle 一次、取前綴**——不是 random.sample。前綴天然巢狀：
    # files[:100] ⊂ files[:400] ⊂ files[:1600]，所以規模是唯一變動的因素。
    random.seed(SEED)
    random.shuffle(files)

    print(f"語料 {len(files)} 檔，seed={SEED}，來源 {CORPUS}")
    for n in scales:
        dest = dest_root / f"n{n}" / "corpus"
        if dest.exists():
            shutil.rmtree(dest)
        # 目的地路徑用「來源相對於語料根」的完整相對路徑，避免不同 project 底下的
        # 同名檔互相覆蓋。初版用 `f.parent.name / f.name`，於是 400 檔只落地 398 個、
        # 1600 檔只落地 1584 個——而**被覆蓋掉的是哪幾個隨複製順序而定**，在不同
        # 規模不必相同，巢狀性因此在檔案層被打破（#18 verify R1）。
        for f in files[:n]:
            target = dest / f.relative_to(CORPUS)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, target)
        (dest_root / f"n{n}" / "derived").mkdir(parents=True, exist_ok=True)
        landed = sum(1 for _ in dest.rglob("*.jsonl"))
        mb = sum(p.stat().st_size for p in dest.rglob("*.jsonl")) // 1048576
        status = "✓" if landed == n else f"✗ 落地 {landed} ≠ 要求 {n}"
        print(f"  n={n}: {landed} 檔、{mb} MB  {status}")
        if landed != n:
            return 1

    # 巢狀性當場自證，不靠散文宣稱
    sets = {n: {p.relative_to(dest_root / f"n{n}" / "corpus")
                for p in (dest_root / f"n{n}" / "corpus").rglob("*.jsonl")}
            for n in scales}
    ordered = sorted(scales)
    for small, large in zip(ordered, ordered[1:]):
        ok = sets[small] <= sets[large]
        print(f"  巢狀 n{small} ⊆ n{large}: {ok}")
        if not ok:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
