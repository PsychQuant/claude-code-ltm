## Context

The #44 cursor-coverage gate, `IndexDatabase.sourcesWithoutCursor()`, runs on every incremental build. Because `ltm query` merges before it retrieves, it also runs on every query. It checks two universal propositions:

- **Q1** — every chunk has at least one source. Today: `COUNT(*) FROM chunks WHERE id NOT IN (SELECT chunk_id FROM chunk_sources)`.
- **Q2** — every source that holds chunks has a scan cursor. Today: `SELECT source_key FROM chunk_sources EXCEPT SELECT source_key FROM scan_state`.

When either finds something, the build refuses with `stateUnreadable` and asks for `ltm build --full`.

#60 (`docs/measurements/2026-09-07-gate-first-touch.md`) measured that the gate's cost is governed by OS page-cache residency of four b-trees: `chunks_by_project` and the `chunk_sources` primary key for Q1, and `chunk_sources_by_source` and the `scan_state` key for Q2. On the 2026-09-30 index those were 42,583 and 29,246 pages (table 4). Its design input to this issue is `issuecomment-5910610664` on #61.

The #61 diagnosis established the constraint this design answers: a per-build audit of a universal proposition is sound only if it reads everything it quantifies over. A cheaper per-build check therefore cannot be an audit at all; it can only trust bookkeeping, and the question becomes how much that trust rests on. #58 rejected count-diff because the application computed it and could drift from the data unseen. Here the engine guarantees that the triggers run, in the same transaction as every write to `chunk_sources` made through SQL with the triggers enabled. It does not guarantee that the trigger bodies are correct — they are application SQL — and it does not cover changes made other than through the triggers (a connection with triggers disabled, dropped triggers, a direct write to a count, dropping and recreating `chunk_sources`; the property, not this list, is the criterion — R2-9). Those two gaps are what the equivalence tests and the whole-index audit are for. (R1-5: the first version said "a fact the engine guarantees", which overstated it.)

`chunk_sources` is written by exactly two statements in `IndexDatabase`:

- the upsert in the chunk-insert path (`INSERT … ON CONFLICT(chunk_id, source_key) DO UPDATE SET session_id, timestamp`);
- `DELETE FROM chunk_sources WHERE source_key = ?` in `deleteChunks(sourceKey:)`.

A from-scratch build discards the database file and recreates the schema.

## Goals / Non-Goals

**Goals:**

- The per-build gate reads structures whose size follows the number of orphan chunks (Q1) and the number of sources (Q2), not the number of chunks or chunk-source links.
- For every index whose derived counts agree with `chunk_sources`, the gate's decisions and its rejection message are unchanged. When the counts drift — `chunk_sources` or the counts changed other than through the triggers — the structural gate and the pre-change gate can disagree in either direction; only the whole-index audit detects that. (R1-5: the first version stated this without the condition.)
- The sound whole-index audit still exists. It runs on demand (`ltm build --audit`), at the end of the `ltm build` that completes from-scratch work, and before the scan of every `ltm build` while an audit is owed. The query path never runs it: when the query path itself finishes an interrupted rebuild, the audit stays owed until the next `ltm build`, and the query path says so in its output (R2-4).
- Invariant 2 holds: the derived counts are recomputable from `chunk_sources`, and incremental equals full.
- Pre-change versus structural gate is measured in the same window, warm and cold, plus the build-context arm #60 handed over.

**Non-Goals:**

- **Holding the index open, and reusing one connection across queries.** These are the two levers from #60. They change process lifetime (`ltm mcp`, overlapping #65), not the gate's SQL.
- **`chunkCount()`.** This change targets the two gate queries only. Whether `chunkCount()` is a per-build cost worth changing is not decided here: the only timing for it is an estimate in the #61 diagnosis, not a `docs/measurements/` record, and `docs/measurements/2026-09-01-noop-build-attribution.md` lists it among the per-build costs. It is tracked in #73: measure first, then decide. (R1-8: the first version quoted that estimate as the reason; R2-6: the item had no landing point.)
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

A source-scanning test fails if any SQL string literal in `Sources/` that names `chunk_sources` also uses REPLACE conflict resolution. A second test fails if a literal other than the three shipped trigger definitions writes `source_count` or `source_chunk_counts`, or uses REPLACE on `chunks` (which would reset `source_count` to its default). The scans are guaranteed to recognise only the shapes listed in `derivedCountGuardsRecogniseTheirShapes` — including schema-qualified and quoted table names, an alias, an upsert's `DO UPDATE SET` and `INSERT OR REPLACE INTO chunks`; they happen to catch some others and miss some single literals (R2-8 measured: `INSERT INTO chunks VALUES(…)` without a column list, `INSERT INTO chunks SELECT …`, `UPDATE OR REPLACE chunks`, a table-level `ON CONFLICT REPLACE`, a row-value `SET (source_count, …) =`, a quoted alias), and SQL split across concatenated or interpolated strings passes them. They also flag a read such as `WHERE source_count = 0`. (R1-7 said the scans stop ordinary edits; the R1 fix said "exactly … and nothing else". Both overstated, in opposite directions.) A raw string makes the scan fail, because the shared Swift lexer refuses it. What bounds the counts' correctness is the equivalence tests, not these scans. (R1-7: the first version said the scans stop ordinary edits; the most natural edit, adding `source_count` to the chunks upsert, passed them.)

**Alternative rejected — `PRAGMA recursive_triggers = ON` on every connection.** It is a per-connection setting. Any connection opened outside `IndexDatabase.init` (the C probe, a manual `sqlite3` session) would not carry it. That turns an engine guarantee back into application discipline, while the ban plus the equivalence tests catch the in-repository case.

### Q1 reads a partial index; Q2 reads the per-source table

- A partial index `chunks_unsourced ON chunks(id) WHERE source_count = 0` serves Q1 as `SELECT COUNT(*) FROM chunks WHERE source_count = 0`. A test extracts that statement from `sourcesWithoutCursor()` itself and asserts that every step of its `EXPLAIN QUERY PLAN` that reads `chunks` uses `chunks_unsourced` (SQLite reports it as `SCAN chunks USING COVERING INDEX chunks_unsourced`).
- Q2 becomes `SELECT source_key FROM source_chunk_counts EXCEPT SELECT source_key FROM scan_state`.
- `sourcesWithoutCursor()` keeps its signature, its return shape and its message strings, so `IndexBuilder` and every caller are unaffected.

**Alternative rejected — make Q1 structural and leave Q2 as is.** Q2's trees were 41% of the gate's pages in #60 table 4. Leaving Q2 would keep a whole-index walk on every build, and would need a second layout bump later.

### The whole-index audit runs on demand, while an audit is owed, and at the end of from-scratch work

`IndexDatabase` gains an audit that runs four checks and returns the counts of each kind of divergence:

1. the pre-change Q1 (`NOT IN` over `chunk_sources`);
2. the pre-change Q2 (`EXCEPT` over `chunk_sources`);
3. a recomputation of `source_count` per chunk, compared with the column;
4. a recomputation of `n` per source, compared with `source_chunk_counts`.

It runs in two places:

- **`ltm build --audit`** — runs it before the scan, in place of the structural gate. Nothing is merged before the audit passes.
- **At the end of the build that completes from-scratch work.** A from-scratch build (`--full`, or a layout/revision mismatch) writes an `audit_pending` meta key in the same transaction as the new layout stamps. Whichever build finishes that work runs the audit after its last batch and removes the key only when the audit passes: the from-scratch build itself, or — if it was interrupted, so the stamps already match and the next build goes incremental — the next `ltm build`. A build that leaves sources unmerged (a bounded merge that ran out of budget) has not finished that work: it skips the audit and leaves the key. While the key is present, every `ltm build` also runs the audit before the scan in place of the structural gate (R2-2: the gate reads exactly the counts that are not yet audited, so a failed audit's state was otherwise stopped by the gate with "run `--full`"). The query path passes `honorPendingAudit: false` and never audits; it reports `auditOwed`, and `ltm query`, the recall block and the MCP response each print one line naming `ltm build` (R2-4). When its gate refuses on an owed index it throws `stateUnreadableWhileAuditOwed`, whose remedy is `ltm build`, not `--full`. (R1-3: without the key, an interrupted rebuild finished by later merges was never audited, and the first rebuild after an upgrade is the one most likely to be interrupted.)

Outcomes:

- **Before the scan, on an index that owes no audit, the counts diverge** → `derivedCountsDiverged`: nothing was merged; the remedy is `ltm build --full`, which regrows the counts and audits again at its end.
- **Before the scan, the counts agree but the sound checks find orphans or missing cursors** → the existing `stateUnreadable` refusal.
- **On an owed index (before the scan or at the end), or at the end of a from-scratch build, anything fails** → `auditFailed(AuditFailure)`, carrying the counts, the coverage findings, the moment and one of two attributions (closed list): `.defect` when the counts were grown by one uninterrupted from-scratch build — this one, or an earlier one whose end-of-build audit failed, recorded by setting the key to `rebuild-failed` — and the message does not offer `--full`; `.defectOrOutsideChange` when the work was interrupted and finished later, since an outside writer had a window, and the message says to run `--full` once. Source keys go on their own line marked for redaction. The key stays. (R1-4, R2-2/3.)
- **Getting out of a `.defect` state** requires a binary whose trigger fix reaches the index. Triggers are created with `IF NOT EXISTS`, so `countSchemaIsPinnedToTheLayoutVersion` pins the trigger and partial-index definitions per layout version: changing them without bumping `layoutVersion` turns it red, and the bump makes the next build rebuild from scratch.

Each audit that passes is reported with its moment (before the scan, after the build), so the numbers in one report are not read as describing the same state.

**Alternative rejected — run the audit every N builds.** The merge runs on the query path, so one query in N would pay the whole-index cost unannounced, and the counter would be one more piece of state that must survive crashes.

### Layout 5 → 6, bumped by this change

The new column, table, indexes and triggers change the derived schema, so `IndexDatabase.layoutVersion` becomes 6. The existing mismatch handling applies unchanged:

- `ltm build` discards and rebuilds;
- the query path refuses with the existing remediation message.

Whether #67 joins the same release is decided at release time.

### The measurement compares both gates on the same layout-6 index in one window

The pre-change SQL still runs on layout 6, because every table and index it reads still exists. So:

- The gate harness gains a mode that runs the pre-change Q1/Q2 through the ltm `IndexDatabase` path.
- `scripts/probes/gate-matrix.sh` interleaves pre-change and structural rounds — warm ×4 after warming both arms, the order alternating so each arm goes first twice (R2-19: three rounds could not balance it), and cold with `purge` before each sample — logging residency and the one-minute load average without attributing to it, as #60 did.

The build-context arm runs `sample` on a no-op `ltm build`, warm and after `purge`, and attributes samples to the gate frames versus the rest of the build. Its question is #60's Residue: inside a real build process, does the gate cost what the harness measures in the same residency state? **No script prepares this arm yet**; it has to be written before 6.1 runs. (R1-2: the deferral notes named only the `gate-matrix.sh` D section.)

The measurement is deferred until after release by the user's choice (2026-10-03). Measuring before release on a side index under `LTM_DERIVED_ROOT` is possible; it was not chosen because a from-scratch build of the real corpus takes hours (`docs/measurements/2026-08-26-interrupted-full-build.md` records an hours-scale full build on older code and corpus, and states that it supports no duration prediction). The 2026-10-03 deferral also cited "about 13 GiB free"; that number was the `Used` column of `df -h /` for the sealed system volume, not free space. `df -h /System/Volumes/Data` showed 241 GiB available on 2026-10-05, and the live derived directory is 5.5 GiB (`du -sh ~/.claude-ltm/derived`), so disk space does not constrain a side index (R2-13). The layout bump therefore ships before the issue's before/after measurement exists.

## Implementation Contract

**Observable behaviour**

- `IndexDatabase.layoutVersion == 6`. A fresh index has `chunks.source_count`, the `source_chunk_counts` table, the `chunks_unsourced` partial index and three triggers on `chunk_sources`.
- After any sequence of the shipped write paths, every chunk's `source_count` and every source's `n` equal a recomputation from `chunk_sources`. The write paths are: inserting new turns, re-observing a turn in the same source, adding a second source for a turn, deleting a source whose turns have other holders, deleting a source holding a turn's last link, re-parsing an invalidated source, and a from-scratch build. A source with no rows has no `source_chunk_counts` row.
- `sourcesWithoutCursor()` returns exactly what the pre-change implementation returns, for every state the existing tests construct and for a chunk whose last `chunk_sources` row is deleted directly.
- `ltm build --audit` exits:
  - 0 on a consistent index, and the final stdout report states that the audit ran before the scan and how many chunks and sources it checked;
  - non-zero with a `derivedCountsDiverged` message naming the counts, stating that nothing was merged, and naming `ltm build --full`, when `source_count` or `source_chunk_counts` is hand-corrupted;
  - non-zero with the existing `stateUnreadable` message when a cursor row is deleted.
- `ltm build --full` runs the audit after rebuilding and exits 0 on a consistent rebuild, reporting it as run after the build.
- A from-scratch build interrupted after some batches, or bounded and stopped short, leaves `audit_pending`; the next `ltm build` audits before the scan and again at its end, and removes the key.
- While `audit_pending` is present, `ltm build` (with or without `--audit`) runs the audit before the scan in place of the structural gate and merges nothing when it fails.
- A failed audit on an owed index or at the end of a from-scratch build raises `auditFailed`; the CLI states whether anything was merged, names counts only when they diverge and coverage gaps only when they exist, prints source keys on their own line marked for redaction, and attributes the failure as an ltm defect (no `--full`; key set to `rebuild-failed`) or as a defect or outside change (run `--full` once). The key stays.
- The query path never runs the audit, owed or not; while one is owed, `ltm query`, the recall block and the MCP response carry one line naming `ltm build`, and a gate refusal throws `stateUnreadableWhileAuditOwed`, whose message names `ltm build` instead of `--full`.
- The trigger and partial-index definitions are pinned per layout version.
- Updating `chunk_sources.chunk_id` or `source_key` fails with the trigger's abort message.

**Acceptance (named tests)**

- `DerivedCountTests`:
  - trigger counts ≡ recomputation for each write path listed above, and deleting one of several links of a source decrements its count;
  - dropping the INSERT trigger, then the DELETE trigger, makes the corresponding assertions fail (mutation, run once per trigger);
  - the `EXPLAIN QUERY PLAN` assertion, on the statement extracted from `sourcesWithoutCursor()`;
  - the REPLACE ban and the trigger-only-writer scans, with the detector's own positive and negative shapes;
  - the key-update abort and its message;
  - `sourcesCheckedCountsTheUnionOfKeys`; `countSchemaIsPinnedToTheLayoutVersion`.
- `IncrementalEquivalenceTests`: the snapshot includes `source_count` and `source_chunk_counts`.
- `IndexBuilderTests`: the existing missing-cursor and empty-mirror tests pass unchanged; `--audit` covers the three outcomes and each of the three per-source corruptions; from-scratch builds run the audit; an interrupted rebuild is audited before the scan and at the end by the build that finishes it; a bounded rebuild that stops short leaves the audit owed; the query path leaves an owed audit and reports it; an owed audit fails before the scan and merges nothing; an uninterrupted rebuild's failed audit is a defect and stays one on the next build; gate-visible drift on an owed index is reported by the audit, and the query path throws `stateUnreadableWhileAuditOwed`; coverage gaps alone are named without counts.
- `CLICommandTests`: the report lines for both moments, `--audit` with a deleted cursor, `ltm query` answering on an index whose counts the audit would reject, and on an owed index: the query answers with the owed line, a gate refusal names `ltm build`, `ltm build` prints each attribution, and coverage gaps alone read consistently.
- `RetrievalToolRenderTests` and `LTMServiceTests`: the owed line in the MCP response and the recall block.
- `GateProbeSQLSyncTests`: the copies of the gate SQL in `gate-matrix.sh` and `gate-harness` equal the gate and the audit's pre-change formulation.
- `GateProbeSQLSyncTests`: green after the probe follows the new SQL. Its pins are updated, not loosened.

**Scope**

- In: the `IndexDatabase` schema, gate and audit; `IndexBuilder` audit placement; the `LTMService` build parameter; the CLI flag and messages; the C probe, gate harness and `gate-matrix.sh`; tests; the measurement record; CHANGELOG; the spec deltas.
- Out: everything in Non-Goals; any change to retrieval or the memory layer; `ltm mcp` connection handling.

## Risks / Trade-offs

- [Every user pays one from-scratch rebuild on upgrade] → CHANGELOG states it. The layout mismatch already rebuilds on `ltm build` and names the remedy on the query path. One bump per release is coordinated at release time.
- [A trigger defect corrupts the counts on every write] → The equivalence tests cover every shipped write path, mutation proves each trigger is load-bearing, and the audit at the end of the build that completes from-scratch work checks the counts on real data. After a defect is reported, the way out is a fixed binary: `countSchemaIsPinnedToTheLayoutVersion` forces a layout bump when trigger definitions change, so the fix rebuilds the index instead of leaving the old triggers in place (`CREATE TRIGGER IF NOT EXISTS`).
- [The per-build gate trusts the trigger bodies] → That is the trade this change makes: per-build soundness for #44's propositions moves from every build to `--audit`, the end of from-scratch work and every build while an audit is owed. Within #44's threat model (a rolled-back transaction, an older binary's index, a deleted cursor row) the counts change in the same transactions as `chunk_sources`, so the refusal semantics hold; only changes made other than through the triggers diverge. The user accepted this relaxation of #61's Expected ③ on 2026-10-04. The CHANGELOG states it.
- [A future write path uses REPLACE, or writes the counts directly] → The text-scan tests name the listed shapes; other shapes are bounded by the equivalence tests.
- [Every write to `chunk_sources` now also updates `chunks` and `source_chunk_counts`, and the build that completes from-scratch work — plus every `ltm build` while an audit is owed, twice — runs a whole-index audit under the build lock] → Not measured. Task 6.1 measures the no-op gate only; this cost is recorded here so a later measurement knows to look for it.
- [The new index's page layout differs from an aged layout-5 index] → Both arms of the A/B run on the same file, so the comparison is fair. The record does not compare against #60's numbers, which were taken in other windows, on other days, on another layout.
- [The planner does not choose the partial index] → The `EXPLAIN QUERY PLAN` assertion in `DerivedCountTests` turns red.

## Migration Plan

1. Ship layout 6.
2. On the first `ltm build` after upgrade, the index is discarded and rebuilt, and the audit runs at the end of the build that finishes the rebuild — the same build, or the next `ltm build` if it was interrupted.
3. A query issued before that build is refused with the existing "run `ltm build --full`" message.
4. Rollback means installing the previous binary. It finds layout 6, treats it as a mismatch, and rebuilds at layout 5. No user data outside the derived directory is involved.

## Open Questions

(none — trigger versus application maintenance, audit timing and the layout bump were decided in the #61 discussion on 2026-10-03)
