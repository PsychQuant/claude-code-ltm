# no-op build 閘：第一次觸碰的成本跟著 OS 頁快取走（#60）

**日期**：2026-09-29 改寫、2026-09-30 補量（第一版 2026-09-07 的機理被 #60 verify R1 推翻；R2、R3、R4 又各抓到
一批說過頭的地方，見「第一版錯在哪」與誠實邊界）。**機器**：Apple M5 Max、128 GB、macOS 27。

**DB**：`~/.claude-ltm/derived/index.sqlite3`，有兩個量測窗口，數字不互比。
- **表 1–5**（2026-09-29 14:09 到 2026-09-30 15:38）：2,755,592,192 B（168,188 個 16 KiB 的 OS 頁；SQLite
  `page_size` 4096、共 672,752 頁）、785,879 chunk。這段時間沒有被寫入（查法：主檔 mtime，一直是
  2026-09-29 14:09）。
- **表 6–8**（2026-09-30 21:47–21:59）：之後索引被寫過好幾次（`build.lock` 16:55:55、19:48:56），長到
  2,968,543,232 B（181,186 個 OS 頁）。窗口裡主檔 mtime 從 21:45:39 變成 21:49:19——那是別的 `ltm`
  行程寫的（表 6 在 21:47:52 前跑完，前後讀到的都是 21:45:39），大小沒變。

**負載**：表 1–5 都沒有記錄 load average；表 6–8 有記（1 分鐘平均約 30–50，機器上有別的工作在跑）。

**結論先講**：

- 一次閘（`sourcesWithoutCursor()` 的 Q1＋Q2）要多久，數量級由**索引頁在不在 OS 頁快取裡**決定：0 頁
  常駐時第一次約 3 s（表 1、1b 兩個冷樣本 2,984 ms、3,226 ms），暖時約 0.22–0.26 s（ltm 的設定：開 mmap、預設
  `cache_size`）。**ltm 自己的 `IndexDatabase` 路徑也一樣**：在長大後的索引、較高的負載下，冷的第一次
  4,119 ms、暖 0.29–0.33 s，與同一窗口的 C 探針、CLI 同級（表 6、表 7）。
- 在同一個常駐狀態下，新連線與新行程不會重付那一個數量級；開著 mmap 時，每條新連線會多付約 1.2 萬次
  minor fault，多數比較裡慢幾到二十幾 ms（判讀 1）。這一份只有**重用同一條連線**才省得掉。
- 索引**會不會整檔變冷**，量到的強候選是 vnode 回收：同一段時間裡，沒人開的檔在兩次讀數之間（2 分 33 秒）
  歸零，被一個行程持有唯讀 fd 的檔 10 分鐘都還常駐（表 5）；記憶體有 88–92% 空閒。持有 fd 擋不住的，是
  讀進來卻沒被引用的預讀頁（表 8）。
- SQLite 的每連線私有頁快取不是機理：預設大小下第一次與第二次的 cache miss 幾乎相同，私有快取不保留
  工作集。暖態下把 `cache_size` 調大，不會讓第一次變快（表 2）。

## 為什麼要量

`2026-09-01-noop-build-attribution.md`（#58）把 no-op build 的成本鎖在
`IndexDatabase.sourcesWithoutCursor()`，並記了一個沒解釋的差距：「行程內 ~0.9s vs CLI 暖 0.44s」
（#58 的 residue，即 #60）。候選：SQLite 私有頁快取冷熱、`cache_size`、prepared statement 重編、
syscall 佔比、Swift 端逐列 `columnText` 字串建構。

## 方法（可重跑）

**C 探針** `scripts/probes/gate-first-touch.c`：每條連線開檔前，先對主檔與 `-wal`／`-shm`／`-journal` 做與
`IndexDatabase.init` 相同的 `lstat` 檢查（`--residency` 只確認主檔是一般檔、不是 symlink），然後以
`SQLITE_OPEN_READONLY` 開索引，把 Q1、Q2 分開跑。開頭印 load average；每條連線先印**讀回**的 `mmap_size`、
`cache_size`、`page_size`；每次呼叫印耗時、`sqlite3_db_status(SQLITE_DBSTATUS_CACHE_HIT／CACHE_MISS)`（每次
歸零）、`getrusage` 的 major／minor fault、`proc_pid_rusage` 的 `ri_diskio_bytesread`（讀不到時印
`unavailable`）、回傳列數；跑前跑後各印一次 `mincore` 量到的 OS 快取常駐頁數。只印數字。它不是測試，不在
`swift test` 裡跑。

`Tests/LTMIndexTests/GateProbeSQLSyncTests.swift` 有兩條測試。第一條比對**文字**：去掉註解、壓縮空白之後的
`sourcesWithoutCursor()` 本體骨架、兩邊的 SQL、`IndexBuilder` 引用的閘名，以及探針的程式碼骨架（SHA-256——
這是變更偵測，探針的任何程式碼改動都會紅，由人確認後更新釘值）。它看不到改變編譯器所見、卻不改變那段
文字的改動，也看不到控制流；已知的幾種不一致直接拒絕，見測試說明。第二條讀回**有效設定**：
`IndexDatabase(path:)` 開出的連線與照探針 `--mmap` 設定的連線，`mmap_size`、`cache_size` 要相同，且 mmap
開著；它只守 `init`。

```bash
# 整段在同一個 shell 裡跑，否則 D 會丟掉
D=$(mktemp -d) && cc -O2 -o "$D/gate-first-touch" scripts/probes/gate-first-touch.c -lsqlite3
P="$D/gate-first-touch"; DB="$HOME/.claude-ltm/derived/index.sqlite3"
"$P" "$DB" --residency                                   # 先看是冷是暖
"$P" "$DB" --conns 2 --reps 3 --mmap                     # 表 1（2026-09-29 的 P1–P4：同一行命令跑四次）
"$P" "$DB" --conns 1 --reps 2 --mmap                     # 表 1b（冷樣本 2）、表 7 的 C 探針
for round in 1 2 3; do                                   # 表 2：五種設定輪流跑，每次一個新行程
  "$P" "$DB" --conns 1 --reps 2 --mmap
  "$P" "$DB" --conns 1 --reps 2 --mmap --cache-size -1000000
  "$P" "$DB" --conns 1 --reps 2
  "$P" "$DB" --conns 1 --reps 2 --cache-size -1000000
  "$P" "$DB" --conns 1 --reps 2 --mmap --reuse-stmt
done
rm -rf "${D:?}"
```

**ltm 自己的路徑**（表 6、表 7）：探針是 C、唯讀開檔，不是 ltm 的程式碼。為了量 ltm 的路徑，在 repo 外的
副本裡加一個只呼叫閘的執行檔：`IndexDatabase(path:)` 開索引，呼叫 `sourcesWithoutCursor()`，印耗時、
major／minor fault、`ru_inblock` 與回傳的列**數**。它走的是 ltm 的 `init`（`lstat` 檢查、讀寫開檔、WAL／`synchronous`／
mmap PRAGMA）、`query()` 與 `columnText`，不經過建置流程（不取鎖、不掃描、沒有 `currentStamps()`）。寫入面
與 ltm 的查詢相同（讀寫開檔；表 6 前後主檔與 `-wal` 的 mtime 沒變）。

```bash
H=$(mktemp -d) && git archive HEAD -- . ':(exclude)scripts/baseline-queries.txt' | tar -x -C "$H"
mkdir "$H/Sources/gateharness"      # main.swift 放下面那段；Package.swift 的 targets 加一行：
#   .executableTarget(name: "gateharness", dependencies: ["LTMIndex"]),
(cd "$H" && swift build -c release --product gateharness)
"$H/.build/release/gateharness" "$DB" 2 2                # 兩條連線、每條兩次
rm -rf "${H:?}"
```

```swift
// #60 Expected 1：用 ltm 自己的 IndexDatabase 路徑跑閘。只印計數與時間，不印任何一列。
import Darwin
import Foundation
import LTMIndex

func usage() -> rusage { var u = rusage(); getrusage(RUSAGE_SELF, &u); return u }
func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

let args = CommandLine.arguments
guard args.count == 4, let conns = Int(args[2]), let reps = Int(args[3]),
      (1...20).contains(conns), (1...20).contains(reps) else {
    FileHandle.standardError.write("usage: gateharness <index.sqlite3> <conns 1-20> <reps 1-20>\n".data(using: .utf8)!)
    exit(64)
}
var load = [Double](repeating: -1, count: 3)
_ = getloadavg(&load, 3)
print(String(format: "harness loadavg=%.2f %.2f %.2f", load[0], load[1], load[2]))
for c in 1...conns {
    let t0 = nowMs()
    let database = try IndexDatabase(path: args[1])
    print(String(format: "conn=%d open_ms=%.1f", c, nowMs() - t0))
    for r in 1...reps {
        let a = usage(); let s = nowMs()
        let missing = try database.sourcesWithoutCursor()
        let ms = nowMs() - s; let b = usage()
        print(String(format: "conn=%d rep=%d ms=%.1f majflt=%ld minflt=%ld inblock=%ld rows=%d",
                     c, r, ms, b.ru_majflt - a.ru_majflt, b.ru_minflt - a.ru_minflt, b.ru_inblock - a.ru_inblock, missing.count))
    }
    database.close()
}
```

**持有 fd 與預讀頁**（表 8）：一支 repo 外、用完即刪的小程式 `touch-pages`。`mk <檔> <MiB>` 以 `F_NOCACHE`
寫隨機內容（寫完常駐 0 頁）；`touch <檔> <KiB>` 對檔案 mmap、每隔那麼多 KiB 讀 1 byte。步驟：`mk` 一個
256 MiB 的檔 → 用 `sleep` 持有它（起停照表 5 的程序）→ `touch` 每 256 KiB 讀一次 → 之後只讀常駐頁。

```c
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 4) return 64;
    long n = strtol(argv[3], NULL, 10);
    if (!strcmp(argv[1], "mk")) {
        int fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0 || fcntl(fd, F_NOCACHE, 1) != 0) return 1;
        char *buf = malloc(1 << 20);
        for (long i = 0; i < n; i++) { arc4random_buf(buf, 1 << 20); if (write(fd, buf, 1 << 20) != 1 << 20) return 1; }
        fsync(fd); close(fd); return 0;
    }
    int fd = open(argv[2], O_RDONLY | O_NOFOLLOW);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) return 1;
    volatile unsigned char *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) return 1;
    unsigned long sum = 0, touched = 0;
    for (off_t o = 0; o < st.st_size; o += n * 1024) { sum += p[o]; touched++; }
    printf("touched=%lu sum=%lu\n", touched, sum);
    return 0;
}
```

**讀數要注意兩件事**：走 mmap 取得的頁**不計入** SQLite 的 hit／miss，所以 `--mmap` 下的 miss 只算
映射視窗外、走 `pread` 的頁；major fault 只記得到視窗內的讀盤，視窗外的讀盤要看 `diskread`。
`SQLITE_MAX_MMAP_SIZE` 與 `DEFAULT_CACHE_SIZE` 的值查法：
`sqlite3 "file:$DB?mode=ro" 'PRAGMA compile_options;'`（本機 `MAX_MMAP_SIZE=1073741824`、
`DEFAULT_CACHE_SIZE=2000`），探針每條連線讀回的值也一樣。

**寫入面**：主檔與 `-wal` 不寫。`-shm` 會被寫（讀者的 read-mark）；只缺 `-shm` 時會建出它；`-shm` 被
清零而 `-wal` 非空時會做 WAL recovery、重建 wal-index；`-wal` 不在時第一條需要讀資料庫的語句就失敗、不建
任何檔。`-shm` 的寫入落在那個名字指向的 inode——所以探針每條連線開檔前做 `lstat` 檢查（一般檔、只有一個
名字、擁有者是自己），不過就不開。上面的 `PRAGMA compile_options` 與表 3、表 4、表 6 的 `sqlite3` CLI 命令
**沒有**這道檢查；跑之前先自己看一次，每個存在的檔都要是 `1 Regular File <你的 uid>`：

```bash
stat -f '%l %HT %u %N' "$DB" "$DB-wal" "$DB-shm" "$DB-journal" 2>/dev/null; id -u
```

**不要**為了繞過任何一種失敗改成讀寫開檔。

**冷態無法直接強制**（清 OS 快取要 `sudo purge`，本紀錄沒有權限）。表 1、表 1b 是**自然冷**；表 7 是先用
`find /System/Library /usr /Library /Applications /opt -xdev > /dev/null` 走一遍系統目錄（只查 metadata、
不讀內容），讓 vnode 表輪轉到索引被回收。兩種都是先 `--residency` 印出 0 頁常駐才開跑，等待期間不輪詢
（輪詢會延後變冷，見判讀 6）。

## 結果

### 表 1：同一條查詢，OS 冷 vs 暖；同連線、新連線、新行程（`--mmap`，2026-09-29）

14:23:04 起連跑四個行程（P1–P4），每個行程依序開兩條連線、每條呼叫三次。當時的探針版本還沒有
`diskread`、不讀回設定、不印負載；它的 `--mmap` 下的 PRAGMA 與現在相同。

| 情形 | Q1 ms | Q2 ms | major fault（Q1＋Q2） | minor fault（Q1＋Q2） | cache miss Q1／Q2 |
|---|---|---|---|---|---|
| P1 第 1 條連線第 1 次（**0 頁常駐**） | **2,187.1** | **797.1** | **6,563＋4,775** | 557＋1 | 33,283／18,419 |
| P1 第 1 條連線第 2、3 次 | 173.0／172.6 | 52.6／51.3 | 0 | 0 | 33,323／18,419、33,316／18,419 |
| P1 第 2 條連線（同行程新連線）第 1 次 | 188.0 | 55.8 | 0 | 7,106＋4,775 | 33,283／18,419 |
| P2／P3／P4 第 1 條連線第 1 次（新行程） | 177.4／183.7／174.3 | 53.1／56.7／51.7 | 0 | 約 7,120＋4,776 | 33,283／18,419 |

OS 快取常駐頁：P1 前 0 ／ 168,188，P1 後 46,126；P2–P4 前後都是 46,126。

### 表 1b：冷樣本 2（`--mmap`，2026-09-30 15:16:17）

| 情形 | Q1 ms | Q2 ms | major fault | diskread | cache miss Q1／Q2 |
|---|---|---|---|---|---|
| 第 1 次（**0 頁常駐**） | **2,334.4** | **891.1** | 6,563＋4,775 | 507,660＋235,996 KiB | 33,281／18,419 |
| 第 2 次 | 182.9 | 54.5 | 0 | 0 | 33,323／18,419 |

跑後常駐 46,127 頁（約 721 MiB），與讀盤量 743,656 KiB（約 726 MiB）相當。15:17:08 再讀是 35,155 頁
（見表 4 之後的對帳與判讀 6）。

### 表 2：可調的連線設定（2026-09-30 15:27:31–15:27:40，五種設定輪流跑三輪，每次一個新行程）

`mmap_size`、`cache_size` 是探針讀回的生效值；第 1、2 次是同一條連線的第 1、2 次呼叫（Q1＋Q2，ms）；
「讀盤」與「minor fault」是第 1 次呼叫的；常駐頁是那次執行開跑前的讀數。這段時間索引由表 5 的持有者持有。

| 時間 | 輪 | mmap_size／cache_size | 其他 | 常駐頁 | 第 1 次 | 第 2 次 | 第 1 次讀盤 | 第 1 次 minor fault |
|---|---|---|---|---|---|---|---|---|
| 15:27:31 | 1 | 1 GiB／2000 | | 35,155 | 304.7 | 258.1 | 3,484 KiB | 11,890 |
| 15:27:32 | 1 | 1 GiB／−1000000 | | 35,339 | 303.8 | 200.5 | 0 | 25,251 |
| 15:27:32 | 1 | 0／2000 | | 35,339 | 278.8 | 282.9 | 596 KiB | 552 |
| 15:27:33 | 1 | 0／−1000000 | | 35,367 | 305.6 | 198.1 | 0 | 19,603 |
| 15:27:34 | 1 | 1 GiB／2000 | statement 重用 | 35,367 | 253.7 | 241.2 | 0 | 11,890 |
| 15:27:34 | 2 | 1 GiB／2000 | | 35,367 | 259.9 | 245.6 | 0 | 11,889 |
| 15:27:35 | 2 | 1 GiB／−1000000 | | 35,367 | 273.8 | 189.7 | 0 | 25,254 |
| 15:27:35 | 2 | 0／2000 | | 35,367 | 279.8 | 284.6 | 0 | 552 |
| 15:27:36 | 2 | 0／−1000000 | | 35,367 | 318.0 | 202.8 | 0 | 19,593 |
| 15:27:37 | 2 | 1 GiB／2000 | statement 重用 | 35,367 | 276.7 | 252.3 | 0 | 11,890 |
| 15:27:37 | 3 | 1 GiB／2000 | | 35,367 | 259.4 | 255.0 | 0 | 11,887 |
| 15:27:38 | 3 | 1 GiB／−1000000 | | 35,367 | 277.6 | 188.3 | 0 | 25,248 |
| 15:27:39 | 3 | 0／2000 | | 35,367 | 272.4 | 281.8 | 0 | 552 |
| 15:27:39 | 3 | 0／−1000000 | | 35,367 | 313.3 | 207.2 | 0 | 19,603 |
| 15:27:40 | 3 | 1 GiB／2000 | statement 重用 | 35,367 | 269.2 | 271.3 | 0 | 11,889 |

所有執行的 major fault 都是 0，第 2 次呼叫的 minor fault 都是 0。第 1 輪的第 1、3 次讀了盤（3,484 KiB、
596 KiB），**第 1 輪不算完全暖**——下面比較時只用第 2、3 輪。第 2 次呼叫的 cache miss：`cache_size` 2000 時
Q1／Q2 為 33,323／18,419（有 mmap）與 43,426／29,246（無 mmap），−1000000 時都是 0。

2026-09-29 另有一張表 2（P5–P10，14:23–14:24，每種設定一次），它的單次讀數讓 R2 抓到說過頭的通則，已由
這張三輪表取代；原表可用 `git show 8a80149:docs/measurements/2026-09-07-gate-first-touch.md` 查。

### 表 3：`sqlite3` CLI（2026-09-30 15:28:01–15:28:03，前後都是 35,367 頁常駐）

每次一個新行程，`/usr/bin/time -p` 的 real（含行程啟動）；Q2 用的是閘的原字面，輸出導到 `/dev/null`。
跑之前先做方法段的 `stat` 檢查。

```bash
sqlite3 "file:$DB?mode=ro" "SELECT COUNT(*) FROM chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_sources);" > /dev/null
sqlite3 "file:$DB?mode=ro" "<同上>" "SELECT source_key FROM chunk_sources EXCEPT SELECT source_key FROM scan_state;" > /dev/null
```

| | 三次 |
|---|---|
| Q1 | 0.26／0.28／0.26 s |
| Q1＋Q2 | 0.34／0.32／0.32 s |

### 表 4：閘碰到的四棵 b-tree（`dbstat`，2026-09-30 15:28:10）

```bash
sqlite3 "file:$DB?mode=ro" "SELECT name, count(*), sum(pageno <= 262144) FROM dbstat WHERE name IN
  ('chunks_by_project','sqlite_autoindex_chunk_sources_1','chunk_sources_by_source','sqlite_autoindex_scan_state_1') GROUP BY name;"
```

| b-tree | 用在 | 頁數（4 KiB） | 其中在 1 GiB mmap 視窗內 |
|---|---|---|---|
| `chunks_by_project` | Q1 | 12,446 | 3,684 |
| `sqlite_autoindex_chunk_sources_1` | Q1 | 30,137 | 6,260 |
| `chunk_sources_by_source` | Q2 | 28,732 | 10,540 |
| `sqlite_autoindex_scan_state_1` | Q2 | 514 | 287 |

合計 71,829 頁（約 281 MiB），其中 51,058 頁（71%）在視窗外，頁號散佈到檔尾（最大 672,421）。

**冷讀的讀盤量（表 1b，約 726 MiB）約是這四棵樹的 2.6 倍，多出來的有兩部分**：
- **顆粒度**：SQLite 頁是 4 KiB、OS 頁是 16 KiB，樹頁又散佈在整個檔裡，碰一個樹頁就讀進、也引用了整個
  16 KiB 的 OS 頁。表 1b 之後，沒被引用的頁掉完，常駐頁回落到 35,155（約 549 MiB）並在持有下留了 10 分鐘
  （表 5）——這是閘碰到的 OS 頁的足跡，約是四棵樹的兩倍。表 4 那天沒有直接量這個足跡；表 7 在長大後的索引上
  量了（表 7 之後）：79,075 個樹頁落在 38,831 個 OS 頁上（約 607 MiB），冷讀約 784 MiB，足跡約佔 77%。以同一個
  比例（每個 OS 頁約 2.04 個樹頁）推，表 4 那天的足跡約 3.5 萬頁，與 35,155 相近——這是推算，那天沒有量。
- **預讀**：讀進來卻沒被引用、之後被回收的頁。表 1b 那次是 46,127 − 35,155 = 10,972 頁（約 171 MiB），約佔
  多出來那部分的 38%。

所以常駐頁數以 4 KiB 計不是工作集大小；冷態的讀盤量要以 `diskread` 計，不能以四棵樹的大小估。

### 表 5：有沒有行程持有檔案（2026-09-30）

A、B 是兩個 512 MiB 的隨機內容檔（放在一個用完即刪的暫存目錄），先 `cat` 全檔讀暖——所以它們的每一頁都
被引用過。B 與索引各由一個 `sleep 1500 < 檔案` 持有一個唯讀 fd（15:16:48／15:16:50 起），A 沒人開；
15:28:27 放掉兩個持有者。每次讀數都用 `--residency`，它自己也會開檔（見判讀 6）。

| 時間 | A（沒人開） | B | 索引 | 與上一次讀數之間每分鐘回收的 vnode |
|---|---|---|---|---|
| 15:17:08 | 32,768／32,768 | 32,768／32,768（持有中） | 35,155（持有中） | — |
| 15:19:41 | **0** | 32,768 | 35,155 | 約 25 萬 |
| 15:20:33 | 0 | 32,768 | 35,155 | 約 5.6 萬 |
| 15:27:19 | 0 | 32,768 | 35,155 | 約 11.6 萬 |
| 15:28:27 放掉兩個持有者 | | | | |
| 15:33:34 | 0 | 32,768 | 35,385 | 約 3.9 萬 |
| 15:38:34 | 0 | 32,768 | 35,385 | 約 1.2 萬 |

同一段時間的系統狀態：`kern.num_vnodes` 等於 `kern.maxvnodes`（263,168，vnode 表是滿的）；
`kern.free_vnodes` 在 15:17:08–15:27:19 的讀數是 184,764–204,217（之後沒有再讀）；
`kern.num_recycledvnodes` 從 15:17:08 的 11,667,514 到 15:38:34 的 13,446,717；`memory_pressure -Q` 的
空閒比例 88–92%；12 個 `ltm` 行程在跑，`lsof` 顯示沒有一個開著索引檔。15:28–15:32 本 session 跑了全套
`swift test`（落在 15:27:19–15:33:34 那段），15:33 之後沒有跑任何東西——這只是時間上的重疊，不是歸因。
查法：`sysctl kern.num_vnodes kern.maxvnodes kern.free_vnodes kern.num_recycledvnodes`、`memory_pressure -Q`、
`lsof -t "$DB"`（只用來數，不要接進 `kill`）。

前一天沒有持有者時的觀測（每分鐘一次 `--residency`，會延後變冷；索引沒被寫入）：最後一次觸碰約 14:24:15，
14:25:27 還有 35,186 頁，14:26:27 是 0；14:27–14:29 有別的行程讀過（10,721 頁），14:30:28 起連續 24 次
都是 0。另有三次 0：2026-09-29 13:51（R1 的 DA）、14:23:04、2026-09-30 15:16:17（表 1b 開跑前）。

**持有者的起停**：用一個 `sleep` 持有，當下記下它的 PID 與啟動時間；收掉時照
`docs/measurements/README.md` 規則 1 的收尾程序——同一個 call 裡核對記下的那一行仍一致，才送 TERM／KILL。
**不要**用 `killall sleep`、`pkill -f` 或 `kill $(lsof -t "$DB")`：這台機器上有別的 session 的 `sleep` 與
別的行程開著同一個檔。持有真索引時若有 `ltm build --full`，持有者抓著的是被換掉的舊 inode（見 #61 段）。

```bash
sleep 1500 < "$FILE" > /dev/null 2>&1 &
ps -o pid=,lstart= -p $!      # 記下這一行
```

### 表 6：ltm 路徑、C 探針、CLI，暖態（2026-09-30 21:47:42–21:47:52，三輪交錯）

每輪依序跑：C 探針 `--conns 2 --reps 2 --mmap`、ltm 路徑（`gateharness … 2 2`）、CLI Q1＋Q2
（`/usr/bin/time -p` 的 real，含行程啟動）。都是 Q1＋Q2 的 ms。load average（1 分鐘）46.94、46.14、46.14。
常駐頁：第 1 輪開跑前 46,718，第 1 輪的 C 探針第 1 次讀了 3,296 KiB，之後都是 46,947。

| 輪 | 路徑 | 第 1 條連線 第 1／2 次 | 第 2 條連線 第 1／2 次 | 每條連線第 1 次的 minor fault | CLI |
|---|---|---|---|---|---|
| 1 | C 探針 | 352.4／317.4 | 322.5／301.1 | 11,932、11,920 | |
| 1 | ltm 路徑 | 331.0／301.9 | 318.7／293.3 | 11,932、11,917 | 0.37 s |
| 2 | C 探針 | 326.7／304.2 | 398.2／310.9 | 11,930、11,919 | |
| 2 | ltm 路徑 | 311.9／302.2 | 298.4／304.0 | 11,930、11,917 | 0.38 s |
| 3 | C 探針 | 320.3／290.8 | 315.1／320.4 | 11,931、11,919 | |
| 3 | ltm 路徑 | 319.8／306.6 | 325.3／320.6 | 11,930、11,918 | 0.36 s |

所有執行 major fault 都是 0；第 2 次呼叫的 minor fault 是 0–1。C 探針第 1 次的 cache miss 是 Q1 37,633、
Q2 21,286（索引比表 1–5 大）。

### 表 7：ltm 路徑與 C 探針，冷態（2026-09-30，各一個樣本）

| 時間 | 路徑 | load | 第 1 條連線 第 1／2 次 | 第 2 條連線 第 1／2 次 | 第 1 次 major fault | 跑後常駐 |
|---|---|---|---|---|---|---|
| 21:54:00 | ltm 路徑 | 34.18 | **4,119.3**／291.4 | 321.7／302.3 | 11,381 | 49,820 |
| 21:55:55 | C 探針 | 30.79 | **4,066.1**／287.0 | — | 11,380 | 49,822 |

兩者開跑前都是 0 頁常駐（用 `find` 讓 vnode 表輪轉之後）；ltm 路徑的第 2 條連線第 1 次多了 11,917 次
minor fault，與暖態相同。C 探針那次讀盤 546,576＋256,552 KiB（約 784 MiB），跑後常駐 49,822 頁（約 778 MiB）；
60 秒後（沒人持有、中間不讀）仍是 49,822——表 1b 之後那種回落，這次在 60 秒內沒有發生。

**閘在 16 KiB OS 頁上的足跡**（21:57:13，冷態量完之後）：

```bash
sqlite3 "file:$DB?mode=ro" "SELECT count(*), count(DISTINCT (pageno-1)/4), sum(pageno <= 262144),
  count(DISTINCT CASE WHEN pageno <= 262144 THEN (pageno-1)/4 END) FROM dbstat WHERE name IN
  ('chunks_by_project','sqlite_autoindex_chunk_sources_1','chunk_sources_by_source','sqlite_autoindex_scan_state_1');"
```

| | SQLite 頁（4 KiB） | 橫跨的 OS 頁（16 KiB） |
|---|---|---|
| 四棵樹全部 | 79,075（約 309 MiB） | 38,831（約 607 MiB） |
| 其中在 1 GiB mmap 視窗內 | 20,834 | **11,380** |

視窗內橫跨的 OS 頁數 11,380，正好等於上表兩條路徑冷的第一次的 major fault（C 探針 6,563＋4,817＝11,380，
ltm 路徑 11,381）：視窗內每個被碰到的 16 KiB 頁都缺頁一次。

### 表 8：被持有的檔，觸碰過的頁與預讀頁（2026-09-30 21:48:45–21:58:50）

256 MiB 的合成檔（16,384 個 OS 頁），`mk` 寫完常駐 0 頁；21:48:45 起由一個 `sleep` 持有（PID 與啟動時間當下
記下、事後照程序收掉），同一秒 `touch` 每 256 KiB 讀 1 byte。

| 時間 | 常駐頁 | 與上一次讀數之間每分鐘回收的 vnode | 備註 |
|---|---|---|---|
| 21:48:45 | 0 | — | 持有、觸碰之前 |
| 21:48:45 | 3,045 | — | 觸碰 1,024 次之後 |
| 21:49:50 | **1,024** | 約 5.0 萬 | |
| 21:50:50 | 1,024 | 約 3.0 萬 | |
| 21:51:50 | 1,024 | 約 0.6 萬 | |
| 21:53:50 | 1,024 | 約 32 萬 | 其間有表 7 的第一次 `find`（21:52:31–21:54:00） |
| 21:58:50 | 1,024 | 約 19 萬 | 其間有第二次 `find`（21:54:23–21:55:55）；之後收掉持有者、刪檔 |

查法：常駐頁用探針的 `--residency`；回收速率用 `sysctl kern.num_recycledvnodes` 的差（21:48:45 的 88,431,381
到 21:58:50 的 90,126,815）。load average（1 分鐘）31–53。

## 判讀

1. **一個數量級的差別來自 OS 頁快取。** 同一個 Q1＋Q2，0 頁常駐時 2,984／3,226 ms（表 1、表 1b），暖時
   224–244 ms（表 1）。冷的那一次有 11,338 次 major fault、讀盤約 726 MiB；暖的都是 0。在同一個常駐狀態下，
   新連線與新行程不會重付那一個數量級，但開著 mmap 時，每條新連線會多約 1.2 萬次 minor fault（把已常駐的頁
   映進新連線的 mmap 視窗）。以同一連線的第 2 次為基準：表 1 的四次新連線／新行程慢 0.4–18 ms；表 2 第 2、3 輪
   開 mmap、預設 `cache_size`、每次 prepare 的兩次，第 1 次慢 14.3、4.4 ms（statement 重用的執行不算——它的
   第 2 次省掉了 prepare，混進了別的差別）；表 6 裡完全暖的十一條連線（兩條路徑；第 1 輪 C 探針第 1 條連線讀了盤，不算）九條第 1 次
   較慢（+4.7 到 +87.3 ms）、兩條較快（−5.3、−5.6 ms），那時負載約 46。沒有 mmap 時沒有這筆 minor fault，表 2 第 2、3 輪都是
   第 1 次較快（−4.8、−9.4 ms）。**這一份只有重用同一條連線才省得掉**；只持有 fd、每次查詢仍開新連線，
   每條新連線都要重新映射。
2. **SQLite 私有頁快取在預設大小下不是機理。** 預設 2000 頁（約 8 MiB）；無 mmap 時 Q1 一次 43,426 次
   miss、Q2 29,246 次，與表 4 的頁數（42,583、29,246）相近、相同。第二次的 miss 與第一次幾乎相同（Q1
   33,283 對 33,323，Q2 相同）——私有快取沒有保留工作集。
3. **暖態下，`cache_size` 調大不會讓第一次變快。** 表 2 的第 2、3 輪（完全暖）：調到約 1 GB 後，第 1 次在
   有 mmap 時慢 5.3%、7.0%，無 mmap 時慢 13.7%、15.0%，多出的 minor fault 是配置私有快取的代價（表 2 最後
   一欄）；同一連線的第 2 次則快（有 mmap 22.3%、22.8%、26.2%，無 mmap 30.0%、28.7%、26.5%，三輪逐一配對）。
   這些是暖態、C 探針、一個 9 秒窗口的讀數；**冷態下與 ltm 自己的路徑上沒有量**（R3 的 DA 在高負載下冷跑
   兩輪，有 mmap 時大快取反而快，n=2，不足以下結論——R3 報告 `issuecomment-5907951440` 第 5 列）。
4. **statement 重用、mmap、`columnText`、syscall 都不是數量級的來源。** 只看第 2、3 輪：statement 重用與
   每次 prepare 的第 1 次呼叫跑的是同一段程式碼（都是 prepare＋step），卻差了 +6.5%、+3.8%（276.7 對 259.9、
   269.2 對 259.4）——這就是同一窗口裡重複執行的差距。關掉 mmap 的第 1 次慢 +7.7%、+5.0%（279.8、272.4 對
   259.9、259.4），與那個差距同一個大小；第 2 次呼叫三輪都慢（+9.6%、+15.9%、+10.5%，逐輪配對）。都是一成
   上下，不是 2×，更不是 13×。no-op 狀態下 Q2 回 0 列，`columnText` 沒被呼叫。R3 的 requirements 在另一個
   時段重跑，方向相同、大小不同（R3 報告第 12 列），所以這些百分比只代表這一個窗口。
5. **同一常駐狀態下，C 探針、CLI 與 ltm 自己的路徑同級。** 表 1–5 的窗口：暖態 C 探針第一次 Q1＋Q2 為
   259–278 ms（表 2 第 2、3 輪的有 mmap 執行），CLI 含行程啟動 0.32–0.34 s（表 3）。表 6：ltm 路徑第 1 次
   298–331 ms、C 探針 315–398 ms、CLI 0.36–0.38 s。表 7 的冷態：ltm 路徑 4,119 ms、C 探針 4,066 ms，major
   fault 都約 1.14 萬（11,381、11,380）。所以 #60 issue 記的那個約 2× 差距，在同一常駐狀態下量不到。
6. **整檔變冷的強候選是 vnode 回收；持有 fd 擋得住它，擋不住預讀頁。** 表 5 的前半是同時進行的對照：記憶體
   88–92% 空閒、每分鐘回收 5.6 萬–25 萬個 vnode 的時段，沒人開的 A 在兩次讀數之間（2 分 33 秒）從全常駐
   掉到 0；被持有的 B（每一頁都被引用過）與索引，在 10 分鐘裡每次讀數都一樣。這與 vnode 被回收時整份檔案
   快取跟著丟掉這個候選一致。表 5 本身只有間隔好幾分鐘的讀數，看不出是整批還是逐頁掉的。#60 verify R2 的
   兩個讀者在前一天各自量到同樣的形狀（R2 報告 `issuecomment-5886067604` 第 2 列）；R3 的 DA 在回收速率每分鐘
   200 萬以上時，量到十個沒人開的檔各在 30–60 秒內歸零、被持有的檔 13 分鐘都在（R3 報告開頭那一段與第 22 列）。
   **持有 fd 擋不住的**：表 8 的檔一直被持有，觸碰 1,024 次後常駐 3,045 頁，65 秒後剩 1,024 頁，之後
   到 21:58:50 每次讀數都是 1,024——剩下的正是被觸碰過的
   那 1,024 頁，掉的是讀進來卻沒被引用的預讀頁。表 7 用 `find` 讓 vnode 大量輪轉的那兩段也在表 8 的觀察期
   裡，被持有的檔沒有因此掉掉觸碰過的頁。表 1b 之後索引從 46,127 掉到 35,155，形狀相同；那段期間
   （15:16:18–15:17:08）持有者在 15:16:50 才開始，所以掉頁發生在持有前還是持有後，本紀錄分不出來。
   **放掉之後那一段（15:33、15:38）不當證據**：兩次讀數間隔約 5 分鐘，而每次 `--residency` 都會刷新
   vnode 在回收佇列裡的位置——R3 的 logic 重現過，每 30 秒讀一次的沒人開的檔撐了 18 分鐘，完全不讀的
   歸零（R3 報告第 3 列）。所以沒人開的檔多快變冷，本紀錄沒有乾淨的量測；只知道在表 5 的回收速率下，
   2 分 33 秒內會發生。每種條件只量了一兩輪，**這是強候選，不是已證實的機理**。

## #58 的「~0.9s vs 0.44s」：沒有重現，也不重新解釋

那兩個數字不是同一種量測。0.9 s 出自 #58 Diagnosis 候選表的一列：「Q1 行程內 | ~0.7–0.9s（sample
推算；CLI 暖只要 0.21s）」——以 `sample`（1 ms 間隔）的樣本數推算，不是計時；當時是 #58 修法**之前**
（舊的 DISTINCT＋LEFT JOIN Q2、沒有 mmap），取樣當下的 OS 快取狀態沒有紀錄。0.44 s 在 #58 的 comment
與紀錄裡都沒有寫出怎麼來的；最接近的是同一張表的 CLI 暖跑 Q1 0.21 s 與舊 Q2 0.20 s，相加是 0.41 s。
（查法：issue 58 的 Diagnosis comment，「候選」那張表與 Residue 段。）本紀錄能說的只有：同一常駐狀態下
量時間，C 探針、CLI 與 ltm 自己的路徑同級（判讀 5）；而閘的成本隨常駐狀態差一個數量級，#58 沒有記錄那個
狀態。所以兩次量測之間的快取狀態不同是**候選**解釋，不是已證實的解釋。本表與 #58 的表不同日、不同語料、
不同設定，不互比。

## 第一版錯在哪

第一版（`e9f5dec`，`git show e9f5dec:docs/measurements/2026-09-07-gate-first-touch.md`）量了四條
行程內路徑：(a) `IndexDatabase` 的 `sourcesWithoutCursor()`（Q1＋Q2）；(b) 同一個包裝的 `query()`
跑 Q1（同一連線，已被 (a) 暖過）；(c) 繞過包裝、直接用 C API 跑 Q1（新連線）；(d) 同 (c) 但開 mmap
（新連線）。它的結論寫「差距不在 SQL 執行，在**同一連線的第一次觸碰**——每個 `ltm` 行程都是新連線、
都付一次」，判讀寫「這是 SQLite **每連線私有頁快取從零暖起**的成本」，並據此寫「任何仍要掃 N 的做法
（換 SQL 寫法、調 `cache_size`）都救不了」「#60 到此可以關」。

它自己的表就推翻了這一點：(c)(d) 是新連線，第一次只要 0.141／0.127 s；CLI 每次是新行程，第一次
0.60 s、第 2、3 次卻只要 0.16／0.17 s。它 (a) 那一次 1.86 s 最可能是 Q2 的頁在 OS 層還冷——暖快取用的
CLI 只跑過 Q1——但那個順序本紀錄沒有重跑。它的誠實邊界說機理「沒有 `PRAGMA cache_stats` 類的計數
支撐」，而 `sqlite3_db_status` 一直都在；它也說「唯讀開啟」，但 (a)(b) 走的 `IndexDatabase(path:)` 只有
讀寫模式。這些由 #60 verify R1 抓到（`issuecomment-5884588066`）。

之後三次改寫又各有說過頭的地方：
- 2026-09-29 版（R2 抓到，`issuecomment-5886067604`）：把 C 探針寫成行程內；用單次讀數寫出調大 `cache_size`
  第一次不變這種通則；把與連線、行程無關寫成無條件。
- 2026-09-30 上午版（R3 抓到，`issuecomment-5907951440`）：把新連線的成本寫成噪音；把 `cache_size` 的暖態結果
  寫成對 ltm 的全稱；把被持有的檔 10 分鐘沒掉一頁當成區分機理的證據；用受輪詢干擾的一段去推變冷的快慢。
- 2026-09-30 下午版（R4 抓到，`issuecomment-5911382731`）：把表 4 多讀的部分全歸給預讀；把持有 fd 與重用
  連線寫成同一個槓桿；刪掉了 ltm 每次查詢開三條連線這個事實；持有 fd 擋不住預讀頁只引讀者的回報、沒有自己
  量；同步測試說成一改就紅。

## 與 #61 的關係（設計輸入）

- 閘的成本有兩個狀態：**暖**約 0.22–0.26 s，每次查詢都付；**冷**約 3 s、讀盤約 726 MiB，在索引頁被
  逐出之後付（表 1–5 的索引；表 6、表 7 的索引較大、負載較高，冷約 4 s、暖約 0.3 s）。#61 的設計若要量
  效果，冷態與暖態都要量，而且要記負載（`sysctl vm.loadavg`）、在同一負載下交錯跑——R3 的 DA 回報負載
  68–82 時同一常駐狀態下的時間差 2–4 倍（R3 報告第 12 列；本紀錄沒有量負載的影響）。
- 冷讀的量大半是 **16 KiB OS 頁的顆粒度**，不是預讀（表 4 之後的對帳）：頁大小與樹頁在檔中的分散程度，
  也是冷成本的一個槓桿。
- ltm 今天每次查詢開**三條新連線**（`LTMService.withEngine`、`IndexBuilder.build` 裡的 `currentStamps()` 與
  建置本身，各自用完即關；查法：`grep -n 'IndexDatabase(path:' Sources/LTMService/LTMService.swift
  Sources/LTMIndex/IndexBuilder.swift`），閘在建置那條連線上只跑一次；常駐的 `ltm mcp` 也一樣。
- 兩個槓桿要分開看：
  - **持有索引**（任何行程持有一個 fd 或一條連線）：在這條機理下擋得住整檔被 vnode 回收丟掉（表 5）；
    擋不住沒被引用的預讀頁（表 8）。
  - **重用同一條連線**（常駐行程每次查詢都用同一條碰過閘的連線）：才省得掉每條新連線約 1.2 萬次 minor
    fault（判讀 1）；只持有 fd、每次查詢仍開新連線，這一份照付。重用連線時調大 `cache_size`，同一連線第 2 次
    起快兩到三成（判讀 3，暖態、C 探針）。
  - 本紀錄**沒有量**這兩個槓桿對 ltm 查詢的效果。
- 持有的正確性前提：`IndexBuilder.discardDerivedArtifacts()` 在 `--full` 或版本不符時會刪掉索引重建。持有者
  若一直抓著舊的 fd 或連線，就是抓著一個已被 unlink 的舊 inode——磁碟與快取都不會釋放，暖的也是舊檔。設計上
  要能發現索引換了（例如比對 inode）並重開。
- 哪一種 SQL 改寫能降低冷成本、降多少，本紀錄沒有量。第一版「任何仍要掃 N 的做法（換 SQL 寫法、調
  `cache_size`）都救不了」已撤回；量到的只有暖態下調大 `cache_size` 第一次不會變快（表 2）。
- #61 改寫閘的時候，`GateProbeSQLSyncTests` 會紅——那是預期的：更新探針，再更新測試裡的骨架與釘值。

## 誠實邊界

- **ltm 自己的路徑是用一支 harness 量的**（表 6、表 7）：它直接呼叫 `IndexDatabase.sourcesWithoutCursor()`，
  不經過建置流程（不取鎖、不掃描、沒有 `currentStamps()`），所以量到的是閘本身在 ltm 程式碼上的成本，不是
  `ltm build` 或一次查詢的總時間。它只在 2026-09-30 晚上的索引與負載下量過（暖三輪、冷一個樣本），與表 1–5
  不直接比；冷態的比較各只有一個樣本。
- **負載**：表 1–5 沒有記 load average；表 6–8 有，約 30–50，機器上有別的工作。表 2 的讀數比表 1、表 1b 高
  （ltm 設定下第 2 次呼叫：表 1 第 2、3 次為 225.6／223.9 ms，表 1b 為 237.4，表 2 為 245.6–258.1），可能是
  負載或時段，不是日期；跨表只比量級。R3 的 DA 回報高負載下時間差 2–4 倍，本紀錄沒有量。
- 單機、每個情形 1–3 次，沒有分佈統計。語料活著，數字只在同一個窗口內可比。
- **冷態**：表 1、表 1b 兩個自然冷樣本（都開 mmap）；表 7 兩個以 `find` 讓 vnode 輪轉得到的冷樣本。冷態下
  `cache_size`、關掉 mmap 的影響本紀錄沒有量——讀者回報過：R2 的 DA 量到無 mmap 的冷態 3.2–3.3 s、major fault
  為 0（R2 報告），R3 的 DA 量到無 mmap 冷跑讀盤約 560 MiB（R3 報告開頭）。
- 逐出機理（判讀 6）是強候選：只量了一台機器、一兩輪；表 5 的讀數間隔不等，而 `--residency` 會刷新
  vnode 的位置，所以它量不出沒人開的檔多快變冷。
- 第一版表上的 `chunkCount()`（7 ms）這一版沒有量，也不沿用。
