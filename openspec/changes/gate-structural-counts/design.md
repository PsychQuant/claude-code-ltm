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
- For every index that owes no audit and whose derived counts agree with `chunk_sources`, the gate's decisions and the findings its refusal lists are unchanged (the refusal's wording changed: R6-5 stopped naming a cause, R9 counts the orphan-chunk entry apart from sources, and R10 states the findings as readings of the maintained counts, since a drifted count can make a chunk with links read as unsourced) (on an owed index `ltm build` runs the audit instead of the gate, and the query path's refusal names `ltm build`). When the counts drift — `chunk_sources` or the counts changed other than through the triggers — the structural gate and the pre-change gate can disagree in either direction; only the whole-index audit detects that. (R1-5: the first version stated this without the condition.)
- The sound whole-index audit still exists. It runs on demand (`ltm build --audit`), at the end of the `ltm build` that completes from-scratch work, and before the scan of every incremental `ltm build` while an audit is owed. The query path never runs it: when the query path itself finishes an interrupted rebuild, the audit stays owed until the next `ltm build`, and the query path says so in its output (R2-4).
- Invariant 2 holds: the derived counts are recomputable from `chunk_sources`, and incremental equals full.
- Pre-change versus structural gate is measured in the same window, warm and cold, plus the build-context arm #60 handed over and a write-side arm for the trigger cost (R9-13).

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

`IndexDatabase` gains an audit that runs five checks and returns the counts of each kind of divergence:

1. the pre-change Q1 (`NOT IN` over `chunk_sources`);
2. the pre-change Q2 (`EXCEPT` over `chunk_sources`);
3. a recomputation of `source_count` per chunk, compared with the column;
4. a recomputation of `n` per source, compared with `source_chunk_counts`;
5. `chunk_sources` rows whose chunk does not exist (R5-2: `chunk_sources` has no foreign key and `chunks.id` reuses rowids, so after an outside deletion of a chunk a new turn could collide with the dangling link, take the upsert's `DO UPDATE` path and skip the INSERT trigger — checks 1–4 all read 0 before that write).

It runs at three moments:

- **`ltm build --audit`** — on an incremental build, runs it before the scan, in place of the structural gate. Nothing is merged before the audit passes. On a from-scratch build the index is discarded first, so only the end-of-build audit runs.
- **At the end of the build that completes from-scratch work.** A from-scratch build (`--full`, or a layout/revision mismatch) writes an `audit_pending` meta key in the same transaction as the new layout stamps. Whichever build finishes that work runs the audit after its last batch and removes the key only when the audit passes: the from-scratch build itself, or — if it was interrupted, so the stamps already match and the next build goes incremental — the next `ltm build`. A build that leaves sources unmerged (a bounded merge that ran out of budget) has not finished that work: it skips the audit and leaves the key. While the key is present, every incremental `ltm build` also runs the audit before the scan in place of the structural gate (R2-2: the gate reads exactly the counts that are not yet audited, so a failed audit's state was otherwise stopped by the gate with "run `--full`"). The query path passes `honorPendingAudit: false` and never audits; it reports `auditOwed`, and `ltm query`, the recall block and the MCP response each print one line naming `ltm build` (R2-4). When its gate refuses on an owed index it throws `stateUnreadableWhileAuditOwed`, whose own detail names `ltm build`, not `--full` — the remedy lives in the error because MCP prints the error as is (R3-1). When the merge is deferred because another process holds the lock, the query still reads the key and reports `auditOwed` (R3-2). (R1-3: without the key, an interrupted rebuild finished by later merges was never audited, and the first rebuild after an upgrade is the one most likely to be interrupted.)

Outcomes:

- **Before the scan, on an index that owes no audit, the counts diverge or a link dangles** → the index is recorded as owing an audit (R3-4: otherwise the next build trusts counts just found wrong), then `auditFailed` (R5 merged the former `derivedCountsDiverged` into it: the two differed only in where they occurred, which `moment` already says).
- **Before the scan, on an index that owes no audit, the counts agree and no link dangles, but the sound checks find orphans or missing cursors** → the existing `stateUnreadable` refusal.
- **On an owed index (before the scan or at the end), or at the end of a from-scratch build, anything fails** → `auditFailed(AuditFailure)`, carrying the counts, dangling links, coverage findings, the moment and `recorded`. **No attribution** (R5, user's decision, 2026-10-05): R2 to R4 tried to say whether a failure was an ltm defect or an outside change, and every round found a reachable shape that the rule misattributed — an outside write during the build, a trigger body replaced before the build, a dangling link meeting a reused rowid. ltm cannot know the cause, so the message states the findings, whether this build merged anything, that ltm cannot tell the cause, what the index will do next (later incremental `ltm build`s audit before the scan; a from-scratch rebuild discards the record and audits only at its end; queries never audit — they keep answering and merging while the structural gate admits, and are refused with "run `ltm build`" when the gate sees the problem, which it always does for a coverage-only failure unless the query's merge is deferred by another process's lock), and what the user can do: report with the numbers, or run `--full`, which regrows the index and audits it at the end but checks only the from-scratch paths. Source keys go on their own line marked for redaction. Every failure path writes the key when it is absent — the owed pre-scan and end-of-build paths too, when the key was removed during the build (R9: they only reported `recorded: false`, and the next build trusted counts just found wrong) — and reads it back (R9: a trigger can ignore the write without an error). `recorded: false` means the key was not visible on read-back — the write raised, a trigger ignored it, or the read itself failed — so the message says ltm could not confirm the record; `recorded: true` means it was visible on that connection at that moment, not that it is durable under `synchronous=NORMAL` (R10-4). The error still carries the findings, and the message says later incremental builds without `--audit` and queries run only the structural gate: while it admits they merge and answer without looking for these findings, and when it sees the problem both are refused with "run `ltm build --full`"; a from-scratch rebuild does not run the gate (R8: the message said unconditionally that queries keep answering and merging, yet a linked chunk whose `source_count` was set to 0 is refused by the gate). A failure never removes an existing key. Each audit's checks read one snapshot, and clearing the key happens in the same write transaction as the end-of-build audit (R6-1: the checks were separate statements and the key was cleared afterwards, so another SQLite connection could change a count between them), and before the audit's checks (R11-1: clearing it after a passing audit let a change the clear itself caused — a trigger on `meta` — commit unaudited; now a failing audit rolls the clear back with everything it caused). A clear that raises does not end the build: the audit still runs, and a passing build completes with the key present (R11-2). Writing the key after a failure happens outside the audit's transaction (R7-1: R6 put it inside, and a write failure that rolled back the transaction or surfaced at COMMIT replaced the findings with a raw SQLite error).
- **What clears the key.** A passing end-of-build audit, or any from-scratch rebuild (it discards the DB; the new build records its own owed audit and clears it when its end audit passes). Neither shows that an incremental-path problem is gone; the message's description of `--full` says so. An `ltm build` that completes (exits 0) with the key still present says so on stderr, without naming a cause it has not observed, and names `--full` as the way to discard a record that would not clear (R9: a trigger can ignore the clear, and the build reported two passing audits while every query said an audit was owed; R10: the first wording named an unreachable cause and offered only a loop). A failed audit says in its own message that the index owes an audit; a build that fails for any other reason after the stamps commit does not say so, and the next query's owed line does (R11-5).

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

The write-side arm times what the triggers add to writes — a bulk insert of new turns, and invalidating or deleting a source — with and without the triggers' work, so the record does not show the read-side gain alone (R9-13). No script prepares it yet either.

The measurement is deferred until after release by the user's choice (2026-10-03). Measuring before release on a side index under `LTM_DERIVED_ROOT` is possible; it was not chosen because a from-scratch build of the real corpus may take hours: `docs/measurements/2026-08-26-interrupted-full-build.md` observed one full build — one machine, one corpus, one run, before #44's batched commits — still running at 41 minutes (it records "小時量級") and supports no "T minutes" prediction; today's corpus has not been measured. (R3-11, R4-8: earlier paraphrases read the record as supporting either no claim or a prediction.) The 2026-10-03 deferral also cited "about 13 GiB free"; that number was the `Used` column of `df -h /` for the sealed system volume, not free space. `df -h /System/Volumes/Data` showed 241 GiB available on 2026-10-05, and the live derived directory is 5.5 GiB (`du -sh ~/.claude-ltm/derived`), so disk space does not constrain a side index (R2-13). The layout bump therefore ships before the issue's before/after measurement exists.

## Implementation Contract

**Observable behaviour**

- `IndexDatabase.layoutVersion == 6`. A fresh index has `chunks.source_count`, the `source_chunk_counts` table, the `chunks_unsourced` partial index and three triggers on `chunk_sources`.
- After any sequence of the shipped write paths, every chunk's `source_count` and every source's `n` equal a recomputation from `chunk_sources`. The write paths are: inserting new turns, re-observing a turn in the same source, adding a second source for a turn, deleting a source whose turns have other holders, deleting a source holding a turn's last link, re-parsing an invalidated source, and a from-scratch build. A source with no rows has no `source_chunk_counts` row.
- `sourcesWithoutCursor()` returns exactly what the pre-change implementation returns, for every state the existing tests construct and for a chunk whose last `chunk_sources` row is deleted directly.
- `ltm build --audit` exits:
  - 0 on a consistent index, and the final stdout report states that the audit ran before the scan and how many chunks and sources it checked;
  - on an index that owes no audit: non-zero with an `auditFailed` message naming the counts, dangling links and coverage findings, stating that nothing was merged and that ltm cannot tell the cause, and describing `ltm build --full`, when `source_count` or `source_chunk_counts` is hand-corrupted or a chunk is deleted from outside — and the index then owes an audit;
  - on an index that owes no audit: non-zero with the existing `stateUnreadable` message when a cursor row is deleted;
  - on an index that owes an audit: as for an owed `ltm build` below.
- `ltm build --full` runs the audit after rebuilding and exits 0 on a consistent rebuild, reporting it as run after the build.
- A from-scratch build interrupted after some batches, or bounded and stopped short, leaves `audit_pending`; the next `ltm build` audits before the scan and again at its end, and removes the key.
- While `audit_pending` is present, an incremental `ltm build` (with or without `--audit`) runs the audit before the scan in place of the structural gate and merges nothing when it fails.
- A failed audit — `--audit` before the scan, on an owed index, or at the end of a from-scratch build — raises `auditFailed`; the CLI states whether anything was merged, names counts, dangling links and coverage gaps only when they exist, says ltm cannot tell the cause, says the index owes an audit (or that ltm could not confirm the record was written — then, without the record, later incremental builds without `--audit` and queries run only the structural gate, refused with `--full` when it sees the problem), describes `--full` as checking only the from-scratch paths, and prints source keys on their own line marked for redaction. The key stays; when it is absent, it is written and read back.
- An `ltm build` that completes (exits 0) while the key is present says so on stderr, stating only what it observed; when its end audit passed, it also names `--full`.
- While the merge is deferred by the lock — another query's merge, or an `ltm build` such as a from-scratch build after its stamps commit — the query outputs, the recall block included, say another process is building or merging, and the owed line says that, if the lock holder is an `ltm build`, it runs the owed audit itself.
- The query path never runs the audit, owed or not; while one is owed — also when the merge is deferred by the lock — `ltm query`, the recall block and the MCP response carry one line naming `ltm build`, and a gate refusal throws `stateUnreadableWhileAuditOwed`, whose detail names `ltm build` instead of `--full`.
- The trigger and partial-index definitions are pinned per layout version (a detector, not an enforcement).
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
- `IndexBuilderTests`: the existing missing-cursor and empty-mirror tests pass unchanged; `--audit` covers the three outcomes and each of the three per-source corruptions; from-scratch builds run the audit; an interrupted rebuild is audited before the scan and at the end by the build that finishes it; a bounded rebuild that stops short leaves the audit owed; the query path leaves an owed audit and reports it; an owed audit fails before the scan and merges nothing (`anOwedAuditFailsBeforeTheScanAndMergesNothing`); a rebuild whose end audit fails stays owed and the next build stops before the scan (`aRebuildWhoseEndAuditFailsStaysOwed`); an owed build that passes its pre-scan audit and fails at the end stays owed (`anOwedBuildThatPassesThenFailsStaysOwed`); a failed `--audit` is remembered with its coverage findings (`aFailedAuditIsRemembered`); dangling links are caught by `--audit`, by an owed pre-scan audit and at the end of a build (`auditCatchesDanglingLinks`, `anOwedAuditCatchesDanglingLinksBeforeTheScan`, `theEndAuditCatchesDanglingLinks`); an existing key is not rewritten (`anExistingMarkerIsNotRewritten`); a failed marker write still reports the audit (`aFailedMarkerWriteStillReportsTheAudit`, `aRolledBackMarkerWriteStillReportsTheAudit`), and a silently ignored one is not reported as recorded (`aSilentlyIgnoredMarkerWriteIsNotReportedAsRecorded`); an unrecorded failure leaves the gate in charge, naming `--full` (`anUnrecordedFailureLeavesTheGateInCharge`); a marker removed during the build is re-recorded at the end (`anEndAuditFailureRerecordsARemovedMarker`); a failing end transaction still reports the audit (`anEndAuditFailureSurvivesAFailingTransaction`); a silently ignored clear leaves the report owed (`aSilentlyIgnoredClearIsReportedAsOwed`); a real layout-5 index is rebuilt (`aLayoutFiveIndexIsRebuilt`); gate-visible drift on an owed index is reported by the audit, and the query path throws `stateUnreadableWhileAuditOwed`; coverage gaps alone are named without counts.
- `CLICommandTests`: the report lines for both moments, `--audit` with a deleted cursor, `ltm query` answering on an index whose counts the audit would reject, and on an owed index: the query answers with the owed line, a gate refusal names `ltm build`, `ltm build` reports the failure without attributing it, and coverage gaps alone read consistently.
- `RetrievalToolRenderTests` and `LTMServiceTests`: the owed line in the MCP response and the recall block, with the deferred variant (`recallBlockSurfacesAnOwedAudit`, `owedAuditWhileDeferredUsesTheDeferredLine`); a deferred merge still reports an owed audit and its recall block says another process is running (`aDeferredMergeStillReportsAnOwedAudit`); the owed gate refusal carries its remedy as MCP prints it (`theOwedGateRefusalCarriesItsRemedy`); the audit message for each moment, dangling links, coverage only and a failed record write (`beforeScanMessage`, `afterBuildMessage`, `danglingLinksMessage`, `coverageOnlyMessage`, `notRecordedMessage`, `notRecordedCoverageOnlyMessage`, `notRecordedMessageScopesTheGate`), none of which attributes the cause; the orphan entry is not a path and a key beginning with `(` still is (`orphanEntryIsNotAPath`, `aSourceKeyStartingWithAParenIsStillAPath`); the message names the index file (`auditMessageNamesTheIndexFile`); the line for an owed audit left after a build (`owedAfterBuildMessage`).
- `CLICommandTests` (R3–R5): a failed `--audit` makes the next query show the owed line and the next build stop (`auditFromTheCLI`); the recall format carries the owed line (`theRecallFormatSurfacesAnOwedAudit`); with the lock held the CLI prints the deferred lines (`theCLIDescribesAnOwedAuditWhileTheLockIsHeld`); `ltm build` says when an owed audit did not clear (`theCLISaysWhenAnOwedAuditDidNotClear`).
- `GateProbeSQLSyncTests`: green after the probe follows the new SQL, its pins updated, not loosened; the copies of the gate SQL in `gate-matrix.sh` and `gate-harness` equal the gate and the audit's pre-change formulation, which in turn equals the frozen pre-#61 gate text.

**Scope**

- In: the `IndexDatabase` schema, gate and audit; `IndexBuilder` audit placement; the `LTMService` build parameter; the CLI flag and messages; the C probe, gate harness and `gate-matrix.sh`; tests; the measurement record; CHANGELOG; the spec deltas.
- Out: everything in Non-Goals; any change to retrieval ranking or the memory layer; `ltm mcp` connection handling. (The owed-audit line is added to the query outputs — `LTMService`, `RecallBlock`, `RetrievalTool` — without touching ranking.)

## Risks / Trade-offs

- [Every user pays one from-scratch rebuild on upgrade] → CHANGELOG states it. The layout mismatch already rebuilds on `ltm build` and names the remedy on the query path. One bump per release is coordinated at release time.
- [A trigger defect corrupts the counts on every write] → The equivalence tests cover every shipped write path, mutation proves each trigger is load-bearing, and the audit at the end of the build that completes from-scratch work checks the counts on real data. The audit cannot say whether a failure is such a defect or an outside change (R5), so its message gives the findings and the options. A fixed trigger reaches existing indexes through a layout bump: `countSchemaIsPinnedToTheLayoutVersion` turns red when trigger definitions change without one, so the fix rebuilds the index instead of leaving the old triggers in place (`CREATE TRIGGER IF NOT EXISTS`).
- [The per-build gate trusts the trigger bodies] → That is the trade this change makes: per-build soundness for #44's propositions moves from every build to `--audit`, the end of from-scratch work and every incremental build while an audit is owed. Within #44's threat model (a rolled-back transaction, an older binary's index, a deleted cursor row) the counts change in the same transactions as `chunk_sources`, so the refusal semantics hold; only changes made other than through the triggers diverge. The audit checks the counts the triggers have written, not the trigger definitions stored in the index file: a trigger replaced under the same name passes the audit until a write goes through it (R9; `CREATE TRIGGER IF NOT EXISTS` does not restore it). The user accepted this relaxation of #61's Expected ③ on 2026-10-04. The CHANGELOG states it.
- [A future write path uses REPLACE, or writes the counts directly] → The text-scan tests name the listed shapes; other shapes are bounded by the equivalence tests.
- [Every write to `chunk_sources` now also updates `chunks` and `source_chunk_counts`, and the build that completes from-scratch work — plus every incremental `ltm build` while an audit is owed, twice — runs a whole-index audit under the build lock] → Not measured. The trigger work on writes is task 6.1's write-side arm (R9-13). The whole-index audit's cost is in no arm of 6.1 (R11-8); no statement about either is made until a record exists.
- [The new index's page layout differs from an aged layout-5 index] → Both arms of the A/B run on the same file, so the comparison is fair. The record does not compare against #60's numbers, which were taken in other windows, on other days, on another layout.
- [The planner does not choose the partial index] → The `EXPLAIN QUERY PLAN` assertion in `DerivedCountTests` turns red.

## Migration Plan

1. Ship layout 6.
2. On the first `ltm build` after upgrade, the index is discarded and rebuilt, and the audit runs at the end of the build that finishes the rebuild — the same build, or the next `ltm build` if it was interrupted.
3. A query issued before that build is refused with the existing "run `ltm build --full`" message.
4. Rollback means installing the previous binary. It finds layout 6, treats it as a mismatch, and rebuilds at layout 5. No user data outside the derived directory is involved.

## Open Questions

- Should the audit also compare the trigger and partial-index definitions stored in the index file with the shipped text (R9-9)? Today it checks only the counts the triggers have written, so a trigger replaced under the same name passes until a write goes through it. Undecided; not part of this change.

(Trigger versus application maintenance, audit timing and the layout bump were decided in the #61 discussion on 2026-10-03.)
