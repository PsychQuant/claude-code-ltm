/*
 * gate-first-touch —— no-op build 閘的唯讀探針（#60）。
 *
 * 以唯讀開索引，把 IndexDatabase.sourcesWithoutCursor() 的兩條閘查詢（Q1、Q2）
 * 分開跑，每一次呼叫印：耗時、SQLite 每連線私有快取的命中／未命中
 * （sqlite3_db_status，每次呼叫前歸零）、major／minor page fault（getrusage）、
 * 回傳列數。跑之前與跑之後各印一次索引檔在 OS 頁快取裡常駐幾頁（對 PROT_READ
 * 映射做 mincore；只映射不觸碰，不會把頁讀進來）。**只印數字**——不印任何一列、
 * 不印 DB 裡的任何路徑。
 *
 * 建置與執行（binary 放 repo 外）：
 *   cc -O2 -o "${TMPDIR:-/tmp}/gate-first-touch" scripts/probes/gate-first-touch.c -lsqlite3
 *   "${TMPDIR:-/tmp}/gate-first-touch" "$HOME/.claude-ltm/derived/index.sqlite3" [選項]
 * 選項：
 *   --conns N        在同一行程裡依序開 N 條連線（預設 2）
 *   --reps N         每條連線呼叫幾次（預設 3）
 *   --mmap           每條連線下 PRAGMA mmap_size=4294967296，與 IndexDatabase 相同
 *   --cache-size N   每條連線下 PRAGMA cache_size=N（預設用 SQLite 的預設值）
 *   --reuse-stmt     每條連線只 prepare 一次、呼叫之間 sqlite3_reset
 *                    （預設每次 prepare＋finalize，與 IndexDatabase.query 相同）
 *   --residency      只印 OS 快取常駐頁數就結束
 *
 * 它不是測試：不在 `swift test` 裡跑，本 repo 的測試不碰真索引。
 *
 * 前提：索引是 WAL 模式，而且 -wal、-shm 兩個檔都在——SQLITE_OPEN_READONLY
 * 建不出它們，缺檔時開檔失敗（"unable to open database file"）。**不要**為了
 * 繞過它改成讀寫開檔：這支探針不得寫索引。WAL 模式的讀者會更新 -shm 裡的
 * read-mark（跑完後 -shm 的 mtime 會變）；它碰的檔只有這一個。
 *
 * Q1／Q2 的字面與 sourcesWithoutCursor() 逐字相同（空白除外），由
 * Tests/LTMIndexTests/GateProbeSQLSyncTests.swift 守住。
 */
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/resource.h>

/* 與 IndexDatabase.sourcesWithoutCursor() 同字面；GateProbeSQLSyncTests 比對兩者。 */
static const char *Q1 = "SELECT COUNT(*) FROM chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_sources)";
static const char *Q2 = "SELECT source_key FROM chunk_sources EXCEPT SELECT source_key FROM scan_state";

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
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

static int run(sqlite3 *db, const char *label, const char *sql, sqlite3_stmt **keep, int conn, int rep) {
    int cur = 0, hi = 0;
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_HIT, &cur, &hi, 1);   /* reset */
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_MISS, &cur, &hi, 1);
    struct rusage a, b;
    getrusage(RUSAGE_SELF, &a);
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
    getrusage(RUSAGE_SELF, &b);
    int hit = 0, miss = 0;
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_HIT, &hit, &hi, 1);
    sqlite3_db_status(db, SQLITE_DBSTATUS_CACHE_MISS, &miss, &hi, 1);
    printf("conn=%d rep=%d q=%s ms=%.1f cache_hit=%d cache_miss=%d majflt=%ld minflt=%ld rows=%ld\n",
           conn, rep, label, ms, hit, miss, b.ru_majflt - a.ru_majflt, b.ru_minflt - a.ru_minflt, rows);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <index.sqlite3> [--conns N] [--reps N] [--mmap] [--cache-size N] [--residency]\n", argv[0]); return 64; }
    const char *path = argv[1];
    int conns = 2, reps = 3, use_mmap = 0, residency_only = 0, have_cache = 0, reuse = 0;
    long cache_size = 0;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--conns") && i + 1 < argc) conns = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--reps") && i + 1 < argc) reps = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mmap")) use_mmap = 1;
        else if (!strcmp(argv[i], "--cache-size") && i + 1 < argc) { cache_size = atol(argv[++i]); have_cache = 1; }
        else if (!strcmp(argv[i], "--reuse-stmt")) reuse = 1;
        else if (!strcmp(argv[i], "--residency")) residency_only = 1;
        else { fprintf(stderr, "unknown option: %s\n", argv[i]); return 64; }
    }
    print_residency("before", path);
    if (residency_only) return 0;
    char cache_label[32] = "default";
    if (have_cache) snprintf(cache_label, sizeof cache_label, "%ld", cache_size);
    printf("sqlite=%s mmap=%d cache_size=%s reuse_stmt=%d\n", sqlite3_libversion(), use_mmap, cache_label, reuse);
    for (int c = 1; c <= conns; c++) {
        sqlite3 *db = NULL;
        if (sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
            fprintf(stderr, "open: %s\n", db ? sqlite3_errmsg(db) : "failed");
            sqlite3_close_v2(db);
            return 1;
        }
        char pragma[64];
        if (use_mmap) sqlite3_exec(db, "PRAGMA mmap_size=4294967296", NULL, NULL, NULL);
        if (have_cache) { snprintf(pragma, sizeof pragma, "PRAGMA cache_size=%ld", cache_size); sqlite3_exec(db, pragma, NULL, NULL, NULL); }
        sqlite3_stmt *k1 = NULL, *k2 = NULL;
        for (int r = 1; r <= reps; r++) {
            if (run(db, "Q1", Q1, reuse ? &k1 : NULL, c, r) != 0 || run(db, "Q2", Q2, reuse ? &k2 : NULL, c, r) != 0) {
                sqlite3_finalize(k1); sqlite3_finalize(k2); sqlite3_close_v2(db); return 1;
            }
        }
        sqlite3_finalize(k1); sqlite3_finalize(k2);
        sqlite3_close_v2(db);
    }
    print_residency("after", path);
    return 0;
}
