## Why

Every incremental build — and therefore every `ltm query`, which merges before retrieving — runs the #44 cursor-coverage gate (`sourcesWithoutCursor()`), and both of its queries walk b-trees whose size grows with the whole index: Q1 ("every chunk has at least one source") probes the `chunk_sources` primary key once per chunk, and Q2 ("every source has a cursor") walks all of `chunk_sources_by_source`. #60 measured that the gate's cost is set by whether those pages are in the OS page cache — about 3 s cold and about 0.22–0.26 s warm on the 2026-09 index (`docs/measurements/2026-09-07-gate-first-touch.md`, tables 1–4) — and that the four trees total 71,829 pages, 59% for Q1 and 41% for Q2 (table 4). A sound per-build audit of a universal proposition must scan everything it quantifies over, so the cost cannot be removed while the gate stays an audit (#61 diagnosis; #58 rejected count-diff for assuming the thing being audited).

## What Changes

- **BREAKING (derived layout)**: layout version 5 → 6. Existing indexes are rebuilt from nothing on the next `ltm build`; the query path refuses with the existing "run `ltm build --full`" message.
- `chunks` gains a derived column `source_count`, and a new derived table records how many `chunk_sources` rows each `source_key` holds. Both are maintained only by SQLite triggers on `chunk_sources`, inside the writing transaction.
- A partial index over chunks with `source_count = 0` lets the gate's Q1 read only orphan chunks; Q2 reads the per-source table instead of the `chunk_sources` source index. The gate's rejection semantics and messages do not change.
- The original whole-index Q1/Q2 plus a recomputation of both derived counts become an audit, run by `ltm build --audit` and automatically after every from-scratch build. A mismatch is a named, non-zero failure that recommends `ltm build --full`.
- Tests pin that the trigger-maintained counts equal a full recomputation after every write path, that removing a trigger turns them red, that no SQL writes `chunk_sources` with `REPLACE` conflict resolution, and that application SQL never writes the derived counts directly.
- The C probe, the gate harness and `scripts/probes/gate-matrix.sh` follow the new gate SQL; a measurement record compares the pre-change and structural gate in the same window, warm and cold, plus a build-context arm handed over by #60.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `corpus-indexing`: adds the cursor-coverage gate as a requirement (today it exists only in code) with its structural form, and the two trigger-maintained derived counts as part of the pure derivative.
- `ltm-cli`: `ltm build` gains `--audit`, and from-scratch builds end with the audit.

## Impact

- Affected specs: `corpus-indexing`, `ltm-cli`
- Affected code:
  - Modified: Sources/LTMIndex/IndexDatabase.swift, Sources/LTMIndex/IndexBuilder.swift, Sources/LTMService/LTMService.swift, Sources/ltm/Commands.swift, scripts/probes/gate-first-touch.c, scripts/gate-harness/main.swift, scripts/probes/gate-matrix.sh, Tests/LTMIndexTests/GateProbeSQLSyncTests.swift, Tests/LTMIndexTests/IncrementalEquivalenceTests.swift, Tests/LTMIndexTests/IndexBuilderTests.swift, Tests/LTMServiceTests/CLICommandTests.swift, CHANGELOG.md
  - New: Tests/LTMIndexTests/DerivedCountTests.swift, and a measurement record under docs/measurements/ whose name is the measurement date followed by gate-structural-count
  - Removed: (none)
- Users pay one from-scratch rebuild on upgrade. If another change in the same release also changes the derived schema (#67 is undiagnosed), both ride one layout bump; that is coordinated at release time, not here.
