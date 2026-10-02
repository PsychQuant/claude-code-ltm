## Context

The #44 cursor-coverage gate, `IndexDatabase.sourcesWithoutCursor()`, runs on every incremental build. Because `ltm query` merges before it retrieves, it also runs on every query. It checks two universal propositions:

- **Q1** — every chunk has at least one source. Today: `COUNT(*) FROM chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_sources)`.
- **Q2** — every source that holds chunks has a scan cursor. Today: `SELECT source_key FROM chunk_sources EXCEPT SELECT source_key FROM scan_state`.

When either finds something, the build refuses with `stateUnreadable` and asks for `ltm build --full`.

#60 (`docs/measurements/2026-09-07-gate-first-touch.md`) measured that the gate's cost is governed by OS page-cache residency of four b-trees: `chunks_by_project` and the `chunk_sources` primary key for Q1, and `chunk_sources_by_source` and the `scan_state` key for Q2. On the 2026-09-30 index those were 42,583 and 29,246 pages (table 4). Its design input to this issue is `issuecomment-5910610664` on #61.

The #61 diagnosis established the constraint this design answers: a per-build audit of a universal proposition is sound only if it reads everything it quantifies over. Any cheaper per-build check therefore has to rest on a fact the engine guarantees, not on an inference the application makes. #58 rejected count-diff for exactly that reason.

`chunk_sources` is written by exactly two statements in `IndexDatabase`:

- the upsert in the chunk-insert path (`INSERT … ON CONFLICT(chunk_id, source_key) DO UPDATE SET session_id, timestamp`);
- `DELETE FROM chunk_sources WHERE source_key = ?` in `deleteChunks(sourceKey:)`.

A from-scratch build discards the database file and recreates the schema.

## Goals / Non-Goals

**Goals:**

- The per-build gate reads structures whose size follows the number of orphan chunks (Q1) and the number of sources (Q2), not the number of chunks or chunk-source links.
- The gate's decisions and its rejection message are unchanged for every index state.
- The sound whole-index audit still exists, runs on demand, and runs after every from-scratch build.
- Invariant 2 holds: the derived counts are recomputable from `chunk_sources`, and incremental equals full.
- Pre-change versus structural gate is measured in the same window, warm and cold, plus the build-context arm #60 handed over.

**Non-Goals:**

- **Holding the index open, and reusing one connection across queries.** These are the two levers from #60. They change process lifetime (`ltm mcp`, overlapping #65), not the gate's SQL.
- **`chunkCount()`.** The #61 diagnosis measured it at about 0.01 s via a covering index; it is not a fixed cost worth a schema change.
- **Using `source_count` inside `deleteChunks`.** Its `COUNT(*)` subqueries stay as they are; behaviour is unchanged.
- **A latency target.** "Under one second" (#56) is not claimed; the record reports what is measured.
- **#67's possible schema change.** Merging layout bumps is a release-time decision.

## Decisions

### Derived counts are maintained by SQLite triggers, not by application code

Triggers on `chunk_sources` maintain `chunks.source_count` and the per-source table `source_chunk_counts(source_key TEXT PRIMARY KEY, n INTEGER NOT NULL CHECK (n > 0))`, inside the statement's own transaction:

- **AFTER INSERT** — increment the chunk's count, then upsert the source row with +1.
- **AFTER DELETE** — decrement the chunk's count. Then delete the source row if its `n` is 1, otherwise decrement it. This order keeps `CHECK (n > 0)` satisfiable.
- **BEFORE UPDATE OF chunk_id, source_key** — abort with `RAISE(ABORT, 'chunk_sources keys are immutable')`, before anything is written. No current path updates the keys, and the abort makes that an engine-enforced fact rather than an assumption.

Measured with `/usr/bin/sqlite3` 3.54: an upsert that takes the DO UPDATE branch does not fire the AFTER INSERT trigger, so re-observing a turn leaves the count unchanged.

**Alternative rejected — application-maintained counts.** Two write sites would each need to know whether the upsert inserted or updated. A third write path added later would drift without any signal: the count-diff failure mode in a new place.

### No SQL writes `chunk_sources` with REPLACE conflict resolution

With SQLite's default `recursive_triggers = OFF`, the row a REPLACE removes does not fire DELETE triggers. Measured: the count reads 2 while 1 row exists.

A source-scanning test fails if any SQL statement in `Sources/` that names `chunk_sources` also contains `OR REPLACE` or `REPLACE INTO`. A second test fails if application SQL assigns `source_count` or writes `source_chunk_counts`. The triggers are their only writers.

These tests compare text: they stop ordinary edits, not a deliberate bypass. That is the same honest boundary `GateProbeSQLSyncTests` states.

**Alternative rejected — `PRAGMA recursive_triggers = ON` on every connection.** It is a per-connection setting. Any connection opened outside `IndexDatabase.init` (the C probe, a manual `sqlite3` session) would not carry it. That turns an engine guarantee back into application discipline, while the ban plus the equivalence tests catch the in-repository case.

### Q1 reads a partial index; Q2 reads the per-source table

- A partial index `chunks_unsourced ON chunks(id) WHERE source_count = 0` serves Q1 as `SELECT COUNT(*) FROM chunks WHERE source_count = 0`. A test asserts that `EXPLAIN QUERY PLAN` for that statement uses `chunks_unsourced` and does not scan `chunks`.
- Q2 becomes `SELECT source_key FROM source_chunk_counts EXCEPT SELECT source_key FROM scan_state`.
- `sourcesWithoutCursor()` keeps its signature, its return shape and its message strings, so `IndexBuilder` and every caller are unaffected.

**Alternative rejected — make Q1 structural and leave Q2 as is.** Q2's trees were 41% of the gate's pages in #60 table 4. Leaving Q2 would keep a whole-index walk on every build, and would need a second layout bump later.

### The whole-index audit runs on demand and after every from-scratch build

`IndexDatabase` gains an audit that runs four checks and returns the counts of each kind of divergence:

1. the pre-change Q1 (`NOT IN` over `chunk_sources`);
2. the pre-change Q2 (`EXCEPT` over `chunk_sources`);
3. a recomputation of `source_count` per chunk, compared with the column;
4. a recomputation of `n` per source, compared with `source_chunk_counts`.

It runs in two places:

- **`ltm build --audit`** — runs it before the scan, in place of the structural gate. Nothing is merged before the audit passes.
- **Every from-scratch build** (`--full`, or a layout/revision mismatch) — runs it after the last batch commits.

Outcomes:

- **Derived counts diverge from the recomputation** → a new failure, `derivedCountsDiverged`, exits non-zero with the divergent chunk and source counts and recommends `ltm build --full`. After a from-scratch build this means a trigger defect, and it is reported as such.
- **The sound checks find orphans or missing cursors while the counts agree** → the existing `stateUnreadable` refusal.

**Alternative rejected — run the audit every N builds.** The merge runs on the query path, so one query in N would pay the whole-index cost unannounced, and the counter would be one more piece of state that must survive crashes.

### Layout 5 → 6, bumped by this change

The new column, table, indexes and triggers change the derived schema, so `IndexDatabase.layoutVersion` becomes 6. The existing mismatch handling applies unchanged:

- `ltm build` discards and rebuilds;
- the query path refuses with the existing remediation message.

Whether #67 joins the same release is decided at release time.

### The measurement compares both gates on the same layout-6 index in one window

The pre-change SQL still runs on layout 6, because every table and index it reads still exists. So:

- The gate harness gains a mode that runs the pre-change Q1/Q2 through the ltm `IndexDatabase` path.
- `scripts/probes/gate-matrix.sh` interleaves pre-change and structural rounds — warm ×3, and cold with `purge` before each sample — logging residency and the one-minute load average without attributing to it, as #60 did.

The build-context arm runs `sample` on a no-op `ltm build`, warm and after `purge`, and attributes samples to the gate frames versus the rest of the build. Its question is #60's Residue: inside a real build process, does the gate cost what the harness measures in the same residency state?

## Implementation Contract

**Observable behaviour**

- `IndexDatabase.layoutVersion == 6`. A fresh index has `chunks.source_count`, the `source_chunk_counts` table, the `chunks_unsourced` partial index and three triggers on `chunk_sources`.
- After any sequence of the shipped write paths, every chunk's `source_count` and every source's `n` equal a recomputation from `chunk_sources`. The write paths are: inserting new turns, re-observing a turn in the same source, adding a second source for a turn, deleting a source whose turns have other holders, deleting a source holding a turn's last link, re-parsing an invalidated source, and a from-scratch build. A source with no rows has no `source_chunk_counts` row.
- `sourcesWithoutCursor()` returns exactly what the pre-change implementation returns, for every state the existing tests construct and for a chunk whose last `chunk_sources` row is deleted directly.
- `ltm build --audit` exits:
  - 0 on a consistent index, and the final stdout report states that the audit ran and how many chunks and sources it checked;
  - non-zero with a `derivedCountsDiverged` message naming the counts and `ltm build --full` when `source_count` is hand-corrupted;
  - non-zero with the existing `stateUnreadable` message when a cursor row is deleted.
- `ltm build --full` runs the audit after rebuilding and exits 0 on a consistent rebuild.
- The query path never runs the audit.
- Updating `chunk_sources.chunk_id` or `source_key` fails with the trigger's abort message.

**Acceptance (named tests)**

- `DerivedCountTests`:
  - trigger counts ≡ recomputation for each write path listed above;
  - dropping the INSERT trigger, then the DELETE trigger, makes the corresponding assertions fail (mutation, run once per trigger);
  - the `EXPLAIN QUERY PLAN` assertion for Q1;
  - the REPLACE ban and the trigger-only-writer scans;
  - the key-update abort.
- `IncrementalEquivalenceTests`: the snapshot includes `source_count` and `source_chunk_counts`.
- `IndexBuilderTests`: the existing missing-cursor and empty-mirror tests pass unchanged; `--audit` covers the three outcomes; from-scratch builds run the audit.
- `GateProbeSQLSyncTests`: green after the probe follows the new SQL. Its pins are updated, not loosened.

**Scope**

- In: the `IndexDatabase` schema, gate and audit; `IndexBuilder` audit placement; the `LTMService` build parameter; the CLI flag and messages; the C probe, gate harness and `gate-matrix.sh`; tests; the measurement record; CHANGELOG; the spec deltas.
- Out: everything in Non-Goals; any change to retrieval or the memory layer; `ltm mcp` connection handling.

## Risks / Trade-offs

- [Every user pays one from-scratch rebuild on upgrade] → CHANGELOG states it. The layout mismatch already rebuilds on `ltm build` and names the remedy on the query path. One bump per release is coordinated at release time.
- [A trigger defect corrupts the counts on every write] → The equivalence tests cover every shipped write path, mutation proves each trigger is load-bearing, and the audit after every from-scratch build checks the counts on real data.
- [A future write path uses REPLACE, or writes the counts directly] → The text-scan tests stop ordinary edits. A deliberate bypass is out of reach, which is stated, not hidden.
- [The new index's page layout differs from an aged layout-5 index] → Both arms of the A/B run on the same file, so the comparison is fair. The record does not compare against #60's numbers, which were taken in other windows, on other days, on another layout.
- [The planner does not choose the partial index] → The `EXPLAIN QUERY PLAN` assertion in `DerivedCountTests` turns red.

## Migration Plan

1. Ship layout 6.
2. On the first `ltm build` after upgrade, the index is discarded and rebuilt, and the from-scratch audit runs.
3. A query issued before that build is refused with the existing "run `ltm build --full`" message.
4. Rollback means installing the previous binary. It finds layout 6, treats it as a mismatch, and rebuilds at layout 5. No user data outside the derived directory is involved.

## Open Questions

(none — trigger versus application maintenance, audit timing and the layout bump were decided in the #61 discussion on 2026-10-03)
