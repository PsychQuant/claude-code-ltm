## Why

Every incremental build — and therefore every `ltm query`, which merges before retrieving — runs the #44 cursor-coverage gate (`sourcesWithoutCursor()`), and both of its queries walk b-trees whose size grows with the whole index: Q1 ("every chunk has at least one source") probes the `chunk_sources` primary key once per chunk, and Q2 ("every source has a cursor") walks all of `chunk_sources_by_source`. #60 measured that the gate's cost is set by whether those pages are in the OS page cache — about 3 s cold and about 0.22–0.26 s warm on the 2026-09 index (`docs/measurements/2026-09-07-gate-first-touch.md`, tables 1–4) — and that the four trees total 71,829 pages, 59% for Q1 and 41% for Q2 (table 4). A sound per-build audit of a universal proposition must scan everything it quantifies over, so the cost cannot be removed while the gate stays an audit (#61 diagnosis; #58 rejected count-diff for assuming the thing being audited).

## What Changes

- **BREAKING (derived layout)**: layout version 5 → 6. Existing indexes are rebuilt from nothing on the next `ltm build`; the query path refuses with the existing "run `ltm build --full`" message.
- `chunks` gains a derived column `source_count`, and a new derived table records how many `chunk_sources` rows each `source_key` holds. Both are maintained only by SQLite triggers on `chunk_sources`, inside the writing transaction.
- A partial index over chunks with `source_count = 0` lets the gate's Q1 read only orphan chunks; Q2 reads the per-source table instead of the `chunk_sources` source index. For every index that owes no audit and whose counts agree with `chunk_sources`, the gate's decisions and the findings it lists do not change (its refusal's wording changed: it no longer names a cause, counts the orphan-chunk entry apart from sources, and states its findings as readings of the maintained counts); when the counts have drifted (changed other than through the triggers), the two forms can disagree, and only the audit detects it. This trades per-build soundness for #44's two propositions for an on-demand and end-of-rebuild audit (#61 R1-5, R2-18; the user accepted the trade on 2026-10-04).
- The original whole-index Q1/Q2, a recomputation of both derived counts and a check for `chunk_sources` rows whose chunk is missing become an audit. It runs on `ltm build --audit` (incremental builds), at the end of the build that completes from-scratch work, and before the scan of every incremental `ltm build` while an audit is owed; a failure leaves the index owing an audit (each failure path writes the record when it is absent and reads it back; when it cannot confirm the record, the message says so). The failure message states what was found and what the user can do, without attributing the cause (ltm cannot tell its own defect from an outside change); it describes `--full` as regrowing the index while checking only the from-scratch paths. The query path never audits; it keeps answering and merging while the structural gate admits, is refused when the gate sees the problem — told to run `ltm build` when an audit is owed, `ltm build --full` otherwise — and says when an audit is owed.
- Tests pin that the trigger-maintained counts equal a full recomputation after every write path and that removing a trigger turns them red; two source scans name the common ways application SQL could write `chunk_sources` with `REPLACE` or write the counts directly (only the listed shapes are guaranteed to be recognised); and the trigger and partial-index definitions are pinned per layout version.
- The C probe, the gate harness and `scripts/probes/gate-matrix.sh` follow the new gate SQL; a measurement record compares the pre-change and structural gate in the same window, warm and cold, plus a build-context arm handed over by #60 and a write-side arm for the cost the triggers add (a bulk insert, a source invalidation or deletion).

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `corpus-indexing`: adds the cursor-coverage gate as a requirement (today it exists only in code) with its structural form, and the two trigger-maintained derived counts as part of the pure derivative.
- `ltm-cli`: `ltm build` gains `--audit`; the build that completes from-scratch work ends with the audit; an owed audit runs before the scan of every incremental `ltm build` and is surfaced by the query path.

## Impact

- Affected specs: `corpus-indexing`, `ltm-cli`
- Affected code:
  - Modified: Sources/LTMIndex/IndexDatabase.swift, Sources/LTMIndex/IndexBuilder.swift, Sources/LTMService/LTMService.swift, Sources/LTMService/RecallBlock.swift, Sources/LTMMCP/RetrievalTool.swift, Sources/ltm/Commands.swift, scripts/probes/gate-first-touch.c, scripts/gate-harness/main.swift, scripts/probes/gate-matrix.sh, Tests/LTMIndexTests/GateProbeSQLSyncTests.swift, Tests/LTMIndexTests/IncrementalEquivalenceTests.swift, Tests/LTMIndexTests/IndexBuilderTests.swift, Tests/LTMServiceTests/CLICommandTests.swift, Tests/LTMServiceTests/LTMServiceTests.swift, Tests/LTMMCPTests/RetrievalToolRenderTests.swift, CHANGELOG.md, README.md, plugin/skills/ltm-setup/SKILL.md, docs/measurements/2026-09-07-gate-first-touch.md
  - New: Sources/LTMService/AuditMessage.swift, Tests/LTMIndexTests/DerivedCountTests.swift, and a measurement record under docs/measurements/ whose name is the measurement date followed by gate-structural-count
  - Removed: (none)
- Users pay one from-scratch rebuild on upgrade. If another change in the same release also changes the derived schema (#67 is undiagnosed), both ride one layout bump; that is coordinated at release time, not here.
