## Why

The 6-AI verify of #24 Stage 1 returned FAIL with 109 findings (3 CRITICAL, 35 HIGH). Two of them are design errors rather than implementation slips, and both were traced to a root cause with isolated evidence:

- **The relevance band is populated with the fused rank.** Every candidate therefore occupies a band of its own, so "the other candidates sharing this band" is always the empty set and no strategy can move anything. The failure is silent — no guard fires, the exit code is 0, and `--strategy human-like` returns byte-identical output to `archival`. An isolated probe (same projection, same strategy, band construction as the only variable) produced displacements `[0,0,0]` for per-rank bands against `[1,-1,0]` for a shared band. This is not merely a code defect: the retrieval spec explicitly states "The fused rank SHALL define each candidate's `RelevanceBand`", so the spec must change too. It also makes the strategy-comparison capability inert, because interleaving two strategies that necessarily agree yields a null comparison.
- **`uuid` is treated as a global primary key.** Measured over 300 real corpus files: 5,722 uuids appear in more than one file, all 5,722 with identical content, 4,337 of them under a different `sessionId`. The cause is session resume/fork copying a turn into a new session file. Because `Anchor.source` is the `sessionId` and the upsert rewrites `chunks.session_id`, previously recorded events dereference to `.orphaned(.turnMissing)` — usage history evaporates whenever a session is resumed, and the orphan reason misreports a turn that is still present.

The second failure is the **second instance of one pattern**: addressing content by something that changes. The first instance was chunk identifiers, and its lesson was recorded in `Anchor`'s doc comment — but as a list of forbidden identifiers rather than as the property, so `sessionId` (not index-produced, but equally mutable) walked straight through it.

Stage 2 of #24 (MCP server, plugin shell) must not be built on this.

## What Changes

- Relevance bands become an actual stratification instead of a per-candidate rank. The candidate rule is the count of retrieval channels a candidate matched (multiple-encoding: three channels > two > one), which is parameter-free — the project has no evaluation set (#16) with which to calibrate bucket counts or score boundaries. **BREAKING** for the retrieval spec's fusion requirement.
- Anchors stop addressing corpus text by `sessionId`. The `source` component becomes a value that is stable across session resume, so a turn copied into a new session file remains one memory rather than two. **BREAKING** for the memory-events anchor requirement.
- Turn de-duplication is defined by content rather than by file, and the index's uniqueness constraint follows from that definition rather than from the accident that `uuid` looked unique.
- Reading usage history stops requiring `--record`; `--strategy` no longer silently degrades to an empty projection when events are not being written.
- The implementation defects the verify surfaced are fixed alongside: the query path taking the single-writer lock, sidecar-before-pointer commit ordering, containment checks on the memory root and on an overridden corpus root, embedded-NUL truncation in SQLite binding, `--k` validation, sidecar/`vector_count` reconciliation, deleted-source invalidation, incomplete-tail handling, FTS row removal on upsert, and unreachable `stateUnreadable`.
- Tests that cannot fail are replaced: the RRF test that recomputes the formula instead of calling `search`, the privacy assertion whose needle is longer than the query, the revision test whose stub ignores the revision, and the shipped-guard path that no test exercises.
- Performance claims without a named measurement record are removed, and the comments that contradict the code they annotate are corrected.

## Non-Goals

- Indexing tool payloads (#6) — coverage of roughly 19% of real turns stays as it is; that decision is tracked separately and would change what a "memory" is.
- Building the evaluation set (#16). Without it no ranking-quality claim can be made here, and none is.
- MCP server, `.mcpb`, signing, plugin shell — Stage 2 of #24.
- Spreading activation (#15), query expansion (#7), conservative-tier revival (#17).
- Deciding which memory strategy is better. This change restores the ability to compare them; it does not compare them.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `retrieval`: the relevance band a candidate receives is no longer its fused rank
- `memory-events`: the anchor's source component must be stable across session resume
- `corpus-indexing`: turn identity and de-duplication are defined by content, not by file, and the pointer stored per chunk follows from that
- `ltm-cli`: reading usage history is decoupled from recording it, and `--k` is validated

## Impact

- Affected specs: `retrieval`, `memory-events`, `corpus-indexing`, `ltm-cli` (all four already shipped; `memory-strategy` and `strategy-comparison` are unchanged in wording but stop being inert once the band fix lands)
- Affected code:
  - Modified: Sources/LTMService/LTMService.swift, Sources/LTMIndex/RetrievalEngine.swift, Sources/LTMIndex/IndexDatabase.swift, Sources/LTMIndex/IndexBuilder.swift, Sources/LTMIndex/CorpusScanner.swift, Sources/LTMIndex/DerivedLocation.swift, Sources/ltm/Commands.swift, Sources/ltm/Arguments.swift, Sources/LTMCore/Anchor.swift, Tests/LTMIndexTests/, Tests/LTMServiceTests/, Tests/LTMQueryTests/
  - New: (none — no new module; the change is corrective)
  - Removed: (none)
- Migration: existing derived indexes and event logs become unreadable under the new anchor definition. Since the index is a pure derivative it is simply rebuilt; the event log is not, so the change must state what happens to events recorded under the old anchor form.
