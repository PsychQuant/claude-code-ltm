/*
 * gate-first-touch —— no-op build 閘的唯讀探針（#60）。
 *
 * 以唯讀開索引，把 IndexDatabase.sourcesWithoutCursor() 的兩條閘查詢（Q1、Q2）
 * 分開跑。每條連線開好之後，先印讀回的 mmap_size、cache_size、page_size（實際生效
 * 的值，不是請求的值）；每一次呼叫印：耗時、SQLite 每連線私有快取的命中／未命中
 * （sqlite3_db_status，每次呼叫前歸零）、major／minor page fault（getrusage）、
 * 行程從磁碟讀進來的 bytes（proc_pid_rusage 的 ri_diskio_bytesread；讀不到時印 unavailable）、
 * 回傳列數。開頭印一次系統負載（getloadavg）——同一常駐狀態下，時間會隨 CPU 爭用差好幾倍。
 * 跑之前與跑之後各印一次索引檔在 OS 頁快取裡常駐幾頁（對 PROT_READ 映射做 mincore；
 * 不觸碰頁，但 open 本身會刷新這個檔的 vnode 在 LRU 裡的位置——連續輪詢會讓檔案
 * 看起來比較晚才變冷）。**只印數字**——不印任何一列、不印 DB 裡的任何路徑。
 *
 * 計數要注意的兩件事：
 * - 走 mmap 取得的頁**不計入** sqlite3_db_status 的 hit／miss；--mmap 下的 miss 只算
 *   映射視窗外、走 pread 的頁。
 * - major fault 只記得到映射視窗內的讀盤；視窗外的讀盤看 diskread。
 *
 * 建置與執行（binary 放 repo 外，用完刪掉）：
 *   D=$(mktemp -d) && cc -O2 -o "$D/gate-first-touch" scripts/probes/gate-first-touch.c -lsqlite3
 *   "$D/gate-first-touch" "$HOME/.claude-ltm/derived/index.sqlite3" [選項]
 *   rm -rf "$D"
 * 選項：
 *   --conns N        在同一行程裡依序開 N 條連線（1–1000，預設 2）
 *   --reps N         每條連線呼叫幾次（1–1000，預設 3）
 *   --mmap           每條連線下 MMAP_PRAGMA（與 IndexDatabase.init 同字面）；不給則下 mmap_size=0
 *   --cache-size N   每條連線下 PRAGMA cache_size=N（正數是頁數、負數是 KiB；不給則用 SQLite 預設）
 *   --reuse-stmt     每條連線只 prepare 一次、呼叫之間 sqlite3_reset
 *                    （預設每次 prepare＋finalize，與 IndexDatabase.query 相同）
 *   --residency      只印 OS 快取常駐頁數就結束
 *
 * 它不是測試：不在 `swift test` 裡跑，本 repo 的測試不碰真索引。
 *
 * 寫入面：主檔與 -wal 永遠不寫。-shm 會被寫——WAL 模式的讀者會更新 read-mark；
 * 只缺 -shm 而 -wal 還在時，會建出 -shm；-shm 被清零而 -wal 非空時，會做 WAL
 * recovery、重建 wal-index，期間持有寫鎖，同時跑的 `ltm build` 可能短暫拿到 BUSY。
 * -wal、-shm 兩個都缺時，第一次 prepare 就失敗（"unable to open database file"）。
 * -shm 的寫入落在那個名字**指向的 inode**：它若是指向別檔的 hard link，寫入會穿過去
 * 改掉那個檔（#60 verify R3 在合成 DB 上重現）。所以開檔前先對主檔與三個後綴做
 * 與 IndexDatabase.init 相同的 lstat 檢查（一般檔、只有一個名字、擁有者是自己），
 * 不過就不開。symlink 本來就會被 SQLite 拒絕，這裡一併擋。
 * **不要**為了繞過任何一種失敗改成讀寫開檔：這支探針不得寫主檔。
 *
 * Q1／Q2 與 sourcesWithoutCursor() 的 SQL 逐項相等（空白除外）、MMAP_PRAGMA 與
 * IndexDatabase.init 同字面，由 Tests/LTMIndexTests/GateProbeSQLSyncTests.swift 守住。
 */
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/resource.h>

/* 與 IndexDatabase.sourcesWithoutCursor() 的 SQL 相等；GateProbeSQLSyncTests 比對兩者。 */
static const char *Q1 = "SELECT COUNT(*) FROM chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_sources)";
static const char *Q2 = "SELECT source_key FROM chunk_sources EXCEPT SELECT source_key FROM scan_state";
/* 與 IndexDatabase.init 的 mmap PRAGMA 同字面；同一條測試比對。 */
static const char *MMAP_PRAGMA = "PRAGMA mmap_size=4294967296";

static const char *USAGE =
    "usage: %s <index.sqlite3> [--conns N] [--reps N] [--mmap] [--cache-size N] [--reuse-stmt] [--residency]\n";

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

/* 讀不到就回 -1——失敗與「真的沒有讀盤」要分得開，不能都印成 0。 */
static int disk_bytes_read(unsigned long long *out) {
    struct rusage_info_v4 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return -1;
    *out = ri.ri_diskio_bytesread;
    return 0;
}

/* 與 IndexDatabase.init 相同的四個名字、相同的三個條件。不存在的後綴沒問題。 */
static int sidecars_safe(const char *path) {
    const char *suffixes[] = { "", "-wal", "-shm", "-journal" };
    for (size_t i = 0; i < sizeof suffixes / sizeof *suffixes; i++) {
        char candidate[4096];
        if (snprintf(candidate, sizeof candidate, "%s%s", path, suffixes[i]) >= (int)sizeof candidate) {
            fprintf(stderr, "路徑太長\n");
            return -1;
        }
        struct stat st;
        if (lstat(candidate, &st) != 0) continue;
        const char *reason = NULL;
        if (S_ISLNK(st.st_mode)) reason = "是符號連結";
        else if (!S_ISREG(st.st_mode)) reason = "不是一般檔案";
        else if (st.st_nlink > 1) reason = "有不只一個名字（hard link）";
        else if (st.st_uid != getuid()) reason = "擁有者不是你";
        if (reason) {
            fprintf(stderr, "不開：主檔或後綴 \"%s\" %s——SQLite 會寫它，寫入會落到別處\n",
                    suffixes[i][0] ? suffixes[i] : "（主檔）", reason);
            return -1;
        }
    }
    return 0;
}

static int residency(const char *path, long *resident, long *total) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size == 0) { close(fd); return -1; }
    void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return -1;
    long page = getpagesize();
    long pages = (long)((st.st_size + page - 1) / page);
    char *vec = malloc((size_t)pages);
    if (!vec || mincore(map, (size_t)st.st_size, vec) != 0) { free(vec); munmap(map, (size_t)st.st_size); return -1; }
    long n = 0;
    for (long i = 0; i < pages; i++) if (vec[i] & MINCORE_INCORE) n++;
    free(vec);
    munmap(map, (size_t)st.st_size);
    *resident = n; *total = pages;
    return 0;
}

static void print_residency(const char *when, const char *path) {
    long r = 0, t = 0;
    if (residency(path, &r, &t) == 0)
        printf("residency %s resident=%ld of=%ld page=%d\n", when, r, t, getpagesize());
    else
        printf("residency %s unavailable\n", when);
}

/* 讀一個整數型 PRAGMA 的實際值；失敗回 -1 並印錯誤。 */
static int pragma_value(sqlite3 *db, const char *sql, long long *out) {
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) {
        fprintf(stderr, "%s: %s\n", sql, sqlite3_errmsg(db));
        return -1;
    }
    int rc = sqlite3_step(st);
    if (rc != SQLITE_ROW) {
        fprintf(stderr, "%s: %s\n", sql, sqlite3_errmsg(db));
        sqlite3_finalize(st);
        return -1;
    }
    *out = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
    return 0;
}

static int run(sqlite3 *db, const char *label, const char *sql, sqlite3_stmt **keep, int conn, int rep) {
    int cur = 0, hi = 0;
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_HIT, &cur, &hi, 1);   /* reset */
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_MISS, &cur, &hi, 1);
    struct rusage a, b;
    getrusage(RUSAGE_SELF, &a);
    unsigned long long disk0 = 0, disk1 = 0;
    int disk_ok = disk_bytes_read(&disk0) == 0;
    double t0 = now_ms();
    sqlite3_stmt *st = keep ? *keep : NULL;
    if (!st && sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) {
        fprintf(stderr, "prepare %s: %s\n", label, sqlite3_errmsg(db));
        return -1;
    }
    long rows = 0;
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) rows++;
    if (keep) { sqlite3_reset(st); *keep = st; } else sqlite3_finalize(st);
    if (rc != SQLITE_DONE) { fprintf(stderr, "step %s: %s\n", label, sqlite3_errmsg(db)); return -1; }
    double ms = now_ms() - t0;
    disk_ok = disk_ok && disk_bytes_read(&disk1) == 0 && disk1 >= disk0;
    getrusage(RUSAGE_SELF, &b);
    int hit = 0, miss = 0;
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_HIT, &hit, &hi, 1);
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_MISS, &miss, &hi, 1);
    char disk[32] = "unavailable";
    if (disk_ok) snprintf(disk, sizeof disk, "%llu", (disk1 - disk0) / 1024);
    printf("conn=%d rep=%d q=%s ms=%.1f cache_hit=%d cache_miss=%d majflt=%ld minflt=%ld diskread_kib=%s rows=%ld\n",
           conn, rep, label, ms, hit, miss, b.ru_majflt - a.ru_majflt, b.ru_minflt - a.ru_minflt, disk, rows);
    return 0;
}

/* 整數參數：整段都要是數字，而且在 [lo, hi] 內；否則回 -1。 */
static int parse_long(const char *s, long lo, long hi, long *out) {
    char *end = NULL;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno != 0 || end == s || *end != '\0' || v < lo || v > hi) return -1;
    *out = v;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, USAGE, argv[0]); return 64; }
    const char *path = argv[1];
    long conns = 2, reps = 3, cache_size = 0;
    int use_mmap = 0, residency_only = 0, have_cache = 0, reuse = 0;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--conns") && i + 1 < argc) {
            if (parse_long(argv[++i], 1, 1000, &conns) != 0) { fprintf(stderr, "--conns 要 1–1000 的整數\n"); return 64; }
        } else if (!strcmp(argv[i], "--reps") && i + 1 < argc) {
            if (parse_long(argv[++i], 1, 1000, &reps) != 0) { fprintf(stderr, "--reps 要 1–1000 的整數\n"); return 64; }
        } else if (!strcmp(argv[i], "--cache-size") && i + 1 < argc) {
            if (parse_long(argv[++i], -100000000, 100000000, &cache_size) != 0 || cache_size == 0) {
                fprintf(stderr, "--cache-size 要非零整數（正數是頁數、負數是 KiB）\n"); return 64;
            }
            have_cache = 1;
        } else if (!strcmp(argv[i], "--mmap")) use_mmap = 1;
        else if (!strcmp(argv[i], "--reuse-stmt")) reuse = 1;
        else if (!strcmp(argv[i], "--residency")) residency_only = 1;
        else { fprintf(stderr, "unknown option: %s\n", argv[i]); fprintf(stderr, USAGE, argv[0]); return 64; }
    }
    print_residency("before", path);
    if (residency_only) return 0;
    if (sidecars_safe(path) != 0) return 1;
    double load[3] = { -1, -1, -1 };
    if (getloadavg(load, 3) != 3) load[0] = load[1] = load[2] = -1;
    printf("sqlite=%s mmap=%d reuse_stmt=%d loadavg=%.2f %.2f %.2f\n", sqlite3_libversion(), use_mmap, reuse,
           load[0], load[1], load[2]);
    for (int c = 1; c <= conns; c++) {
        sqlite3 *db = NULL;
        if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
            fprintf(stderr, "open: %s\n", db ? sqlite3_errmsg(db) : "failed");
            sqlite3_close_v2(db);
            return 1;
        }
        char pragma[64];
        const char *mmap_sql = use_mmap ? MMAP_PRAGMA : "PRAGMA mmap_size=0";
        /* PRAGMA mmap_size 會回一列（生效值），所以用 pragma_value 執行，不用 sqlite3_exec 丟掉它。 */
        long long ignored = 0;
        if (pragma_value(db, mmap_sql, &ignored) != 0) { sqlite3_close_v2(db); return 1; }
        if (have_cache) {
            snprintf(pragma, sizeof pragma, "PRAGMA cache_size=%ld", cache_size);
            if (sqlite3_exec(db, pragma, NULL, NULL, NULL) != SQLITE_OK) {
                fprintf(stderr, "%s: %s\n", pragma, sqlite3_errmsg(db));
                sqlite3_close_v2(db);
                return 1;
            }
        }
        long long mmap_size = 0, cache = 0, page = 0;
        if (pragma_value(db, "PRAGMA mmap_size", &mmap_size) != 0 || pragma_value(db, "PRAGMA cache_size", &cache) != 0
            || pragma_value(db, "PRAGMA page_size", &page) != 0) {
            sqlite3_close_v2(db);
            return 1;
        }
        printf("conn=%d mmap_size=%lld cache_size=%lld page_size=%lld\n", c, mmap_size, cache, page);
        sqlite3_stmt *k1 = NULL, *k2 = NULL;
        for (long r = 1; r <= reps; r++) {
            if (run(db, "Q1", Q1, reuse ? &k1 : NULL, c, (int)r) != 0 || run(db, "Q2", Q2, reuse ? &k2 : NULL, c, (int)r) != 0) {
                sqlite3_finalize(k1); sqlite3_finalize(k2); sqlite3_close_v2(db); return 1;
            }
        }
        sqlite3_finalize(k1); sqlite3_finalize(k2);
        sqlite3_close_v2(db);
    }
    print_residency("after", path);
    return 0;
}
