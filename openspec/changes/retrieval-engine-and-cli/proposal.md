## Why

claude-LTM's four libraries implement everything *after* retrieval — the strategy seam takes `Candidate(anchor, baseScore, band)` as input, but nothing in the tree produces candidates. The retrieval engine exists only as a measurement spike (scripts/probe-tokenizer.swift) and recorded baselines (docs/measurements/). Until the engine and a first executable consumer exist, the project's north star ("Claude can quickly recall memory") has no runnable path, and invariant 2's `ltm build` equivalence cannot even be tested. This is Stage 1 of issue #24; Stage 2 (MCP server + plugin shell) builds on the facade introduced here.

## What Changes

- New corpus indexing pipeline: read-only scan of `~/.claude/projects/**/*.jsonl`, chunking, and a derived index (FTS5 trigram+segment plus `NLContextualEmbedding` vectors) under `~/.claude-ltm/derived`, with incremental resume keyed on `state.json` prefix hash.
- New retrieval path: query → FTS5 + brute-force cosine (Accelerate) → RRF fusion → banded `Candidate` list → existing `MemoryStrategy` reranking → pointered results. Every hit carries `(project, sessionId, uuid, timestamp)`.
- New `LTMService` facade owning the full lifecycle: staleness detection (incremental continue on prefix-hash match; refuse-and-instruct on embedding revision mismatch), retrieval, strategy application, and an injectable event sink (consumed by CLI opt-in now, MCP server in Stage 2).
- New `ltm` executable target with `build` and `query` subcommands — the first runnable consumer of the four libraries, and the concrete referent of invariant 2's `rm -rf ~/.claude-ltm/derived && ltm build` equivalence.

## Capabilities

### New Capabilities

- `corpus-indexing`: read-only corpus scanning, chunking, derived-index construction, incremental resume, and rebuild equivalence
- `retrieval`: query execution over the derived index — candidate generation, RRF fusion, strategy application, pointered output, and staleness/revision policy
- `ltm-cli`: the `ltm` executable surface — `build` and `query` subcommands, their output contracts and exit behavior

### Modified Capabilities

(none — the existing memory-strategy and memory-events capabilities are consumed through their published APIs; no requirement changes)

## Impact

- Affected specs: three new capabilities (`corpus-indexing`, `retrieval`, `ltm-cli`); existing specs unchanged
- Affected code:
  - New: Sources/LTMIndex/ (corpus reader, chunker, FTS5 + vector index), Sources/LTMService/ (facade), Sources/ltm/ (CLI executable), Tests/LTMIndexTests/, Tests/LTMServiceTests/
  - Modified: Package.swift (new targets; system SQLite3 / NaturalLanguage / Accelerate only — no third-party or network dependencies, preserving the zero-egress privacy boundary)
  - Removed: (none)
