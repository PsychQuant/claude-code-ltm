## Context

The four libraries (LTMCore, LTMMemory, LTMQuery, LTMEval) implement anchors, the event store, the strategy seam, and the comparison layer — everything downstream of retrieval. Nothing produces `Candidate` values. The retrieval design was validated empirically (docs/measurements/2026-08-08-baseline.md for the 4-layer baseline and the no-ANN decision; docs/measurements/2026-08-10-fts5-tokenizer.md for the trigram+segment tokenizer configuration, issue #2), but only as a spike (scripts/probe-tokenizer.swift). Constraints inherited from CLAUDE.md: the corpus at `~/.claude/projects/` is read-only (invariant 1); the index is a pure derivative (invariant 2); every hit carries `(project, sessionId, uuid, timestamp)` (invariant 3); Chinese requires `NLContextualEmbedding`; vectors are not comparable across embedding revisions; zero external network channels.

## Goals / Non-Goals

**Goals:**

- A runnable retrieval path: corpus scan → chunk → index → query → banded candidates → strategy reranking → pointered results
- The `ltm` executable (`build`, `query`) as the first consumer, making invariant 2 testable
- An `LTMService` facade shaped so Stage 2 (issue #24: MCP server + plugin shell) adds an adapter without touching engine internals

**Non-Goals:**

- MCP server, plugin shell, `.mcpb`, signing pipeline (Stage 2 of #24)
- ANN indexing (rejected in docs/measurements/2026-08-08-baseline.md; brute-force cosine is sufficient at current corpus scale)
- Query expansion (#7), nDCG evaluation harness (#16), spreading activation (#15), conservative-tier revival (#17)
- Any performance claim not backed by a named measurement record (repo honesty boundary)

## Decisions

### Single `ltm` binary with subcommands

One executable target `ltm` with `build` and `query`; a future `mcp` subcommand is reserved for Stage 2. Alternative (separate CLI and server binaries) was rejected: it doubles the signing/notarization and release surface in Stage 2 for no isolation benefit — the server is the same engine behind a different transport.

### LTMService facade with thin adapters

`LTMService` (new library target) owns the contract: staleness detection, index lifecycle, retrieval, strategy application, event emission. Adapters translate I/O only — the CLI formats text, the future MCP adapter formats tool responses. Depth check: deleting the facade breaks every consumer (deep module); deleting an adapter removes one surface only. Logic in an adapter is a defect by construction.

### Derived index under ~/.claude-ltm/derived

One SQLite database file holding the two FTS5 tables (trigram and segment, per the #2 tokenizer decision) plus chunk metadata and pointer columns; embedding vectors in a flat sidecar file loaded for Accelerate brute-force cosine. A layout-version stamp and the embedding revision are recorded in the index; any mismatch invalidates the whole derivative. `rm -rf ~/.claude-ltm/derived && ltm build` MUST reproduce an equivalent index (invariant 2) — this is a test, not documentation.

### Staleness policy: incremental continue, revision refuse

At query time the facade compares `state.json` prefix hashes per source file: on a match with new trailing bytes it re-reads only the tail before answering (the jsonl "not assumed append-only, but exploited" rule); on a prefix mismatch it re-parses that file. On an `NLContextualEmbedding.revision` mismatch it refuses the query with a message naming `ltm build` — silent cross-revision cosine returns meaningless distances without error, so refusal is the only honest behavior. Alternative (serve stale results with a warning) was rejected: a warning next to plausible-looking results does not stop them from being used.

### RRF fusion of FTS5 and embedding channels

Per-query: both FTS5 tables and the cosine channel each produce a ranked list; reciprocal-rank fusion merges them into one ranking, from which `Candidate` values get `baseScore` (fused score) and `band` (fused rank). The tokenizer configuration and its recall figures are the ones recorded in docs/measurements/2026-08-10-fts5-tokenizer.md — this design cites and does not restate them.

### Default strategy is archival

`ltm query` applies the archival strategy (no reordering, per the memory-strategy spec) unless `--strategy` names another. Pure retrieval order is the honest default for an inspection tool; usage-history reordering is opt-in.

### Event sink injectable, CLI records only with --record

The facade takes an event sink (backed by `FileEventStore`); emitting `shown`/`opened` is the sink's consumer's choice. `ltm query` defaults to NOT recording — developer and inspection queries would pollute the usage history that feeds strategy comparison — and `--record` opts in. Stage 2's MCP adapter always records (user decision on #24). Alternative (CLI always records) rejected: it biases the very data the comparison layer exists to collect.

### Chunk granularity is one conversation turn

One chunk per jsonl turn: FTS5 row, one embedding vector, and pointer metadata per turn. Anchors remain content-addressed (memory-events spec: anchors survive chunking changes), so a later sub-turn chunking config does not orphan history.

## Implementation Contract

**Commands**

- `ltm build [--full]` — scans `~/.claude/projects/**/*.jsonl` read-only; writes only under `~/.claude-ltm/derived`. Default incremental (prefix-hash resume); `--full` rebuilds from nothing. Exit 0 on success; non-zero with a named reason (corpus root missing, embedding model unavailable) on failure.
- `ltm query <text> [--k N] [--project NAME | --all-projects] [--strategy archival|human-like] [--record] [--json]` — prints up to N (default 20) hits. Human output: rank, project, timestamp, snippet, pointer. `--json`: array of objects each carrying `project`, `sessionId`, `uuid`, `timestamp`, `snippet`, `score`, `band`, plus the strategy's `displacement`/`reason` fields when a reordering strategy is active.

**Scope default**: when the working directory maps to exactly one project directory under the corpus root, that project is the default scope; otherwise the command exits non-zero instructing `--project` or `--all-projects` (mirrors the #4 decision that unscoped search is opt-in).

**Failure modes**: embedding revision mismatch → exit non-zero, message names `ltm build`; index absent → exit non-zero, message names `ltm build`; corpus unreadable → exit non-zero naming the path. No failure path writes anywhere outside `~/.claude-ltm/`.

**Acceptance criteria**

- Rebuild equivalence: build over a fixture corpus, capture query results; `rm -rf` derived, rebuild, same queries return identical results (test)
- Incremental equivalence: append to a fixture jsonl, incremental build ≡ full rebuild for query results (test)
- Read-only corpus: builds and queries perform no writes under the corpus root — guarded by the existing `CorpusLocation` inode check (test)
- Revision refuse: index stamped with a different revision string → query exits non-zero without returning results (test)
- Pointer completeness: every hit in `--json` output carries all four pointer fields (test)
- Zero third-party dependencies: Package.swift gains no external package requirements (review check)

**Scope boundaries**: in scope — LTMIndex, LTMService, `ltm` executable, their tests, Package.swift target wiring. Out of scope — MCP transport, plugin shell, marketplace, signing (Stage 2); any change to the four existing libraries' public APIs (consume only); eval-harness automation (#16).

## Risks / Trade-offs

- [FTS5 trigram tokenizer availability varies with the system SQLite] → capability probe at startup; a missing feature fails loudly naming the SQLite version, never silently degrades to LIKE-scans
- [Embedding 280k chunks is slow on first build] → incremental resume makes it one-time; no throughput number is promised anywhere until docs/measurements/ records one
- [Query while a build is running] → single-writer lock file under `~/.claude-ltm/derived`; queries read through SQLite WAL snapshots; vectors sidecar is swapped atomically (write-new + rename)
- [Vector working set grows with corpus] → flat sidecar is mmap-ed, not eagerly loaded; brute-force stays the strategy until a measurement record justifies revisiting (per baseline doc's re-evaluation trigger)

## Migration Plan

New feature — no data migration. Rollback: delete `~/.claude-ltm/derived` and drop the new targets; the four existing libraries are untouched.

## Open Questions

(none — the four questions raised in issue #24's diagnosis are resolved for Stage 1 scope by the decisions above; Stage 2 questions stay with #24)
