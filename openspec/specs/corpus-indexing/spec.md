# corpus-indexing Specification

## Purpose

TBD - created by archiving change 'retrieval-engine-and-cli'. Update Purpose after archive.

## Requirements

### Requirement: The corpus is read and never written

Index construction SHALL open files under the corpus root (`~/.claude/projects/`) for reading only. No code path in indexing, retrieval, or the CLI SHALL create, modify, or delete any file under the corpus root. Path containment SHALL be decided by the inode-identity guard already provided by `CorpusLocation` (symlink- and firmlink-resistant), not by string comparison.

#### Scenario: A build leaves the corpus untouched

- **WHEN** `ltm build` runs over a fixture corpus and completes
- **THEN** the corpus tree's file contents, metadata set, and directory structure are byte-identical to before the build, and all build products reside under `~/.claude-ltm/derived`

#### Scenario: A write attempt inside the corpus is refused

- **WHEN** any component asks the index layer to place an output file at a path that resolves into the corpus root
- **THEN** the operation fails with an error before any byte is written

---
### Requirement: The derived index is a pure derivative of the corpus

Deleting the entire derived directory and rebuilding SHALL produce an index that returns identical results for identical queries. Nothing SHALL live only in the index: any datum needed to answer queries MUST be recomputable from the corpus and the build configuration.

#### Scenario: Delete-and-rebuild equivalence

- **WHEN** queries Q1..Qn are executed and their results recorded, then `~/.claude-ltm/derived` is deleted entirely and `ltm build` runs again
- **THEN** re-executing Q1..Qn returns results identical to the recorded ones

---
### Requirement: Incremental builds resume from a verified prefix

For each source file, the build SHALL record a prefix hash and processed byte count. On a subsequent build, a file whose stored prefix hash matches SHALL be read only from the recorded offset; a file whose prefix hash does not match SHALL be re-parsed from the beginning. An incremental build SHALL be result-equivalent to a full rebuild over the same corpus state.

#### Scenario: Appended-only file is read from the tail

- **WHEN** bytes are appended to a jsonl file after a build and an incremental build runs
- **THEN** only the appended region of that file is parsed, and subsequent queries return the same results a full rebuild would return

#### Scenario: A rewritten file is fully re-parsed

- **WHEN** a jsonl file's existing bytes change (prefix hash mismatch) and an incremental build runs
- **THEN** that file is re-parsed from offset zero and stale chunks derived from its former content are no longer retrievable

---
### Requirement: The index declares its layout version and embedding revision

The derived index SHALL record the index layout version and the `NLContextualEmbedding` revision it was built with. A layout version different from the running binary's SHALL cause the next build to start from nothing. Vectors from different embedding revisions SHALL NOT coexist in one index.

#### Scenario: Layout version mismatch triggers a from-scratch build

- **WHEN** the derived index carries a layout version other than the one the binary expects and `ltm build` runs
- **THEN** the build discards the existing derivative and rebuilds from nothing, exiting 0

---
### Requirement: Chunk granularity is one conversation turn with full pointer metadata

Indexing SHALL create exactly one chunk per jsonl conversation turn. Each chunk SHALL be addressable by the pointer tuple `(project, sessions, uuid, timestamp)` alongside its text and vector, and the tuple SHALL be returned with any retrieval hit derived from that chunk. The `sessions` component is a set held in `chunk_sources`, one entry per source file holding the chunk; the other three are scalar columns on the chunk row.

**A chunk is routinely held by more than one source file.** Session resume copies the same turn into a new file, so one turn commonly exists in several session files; deduplication is by content, so those copies produce exactly one chunk. The chunk SHALL therefore additionally carry the set of session identifiers of every source file that holds it — one entry per holding source, each entry being that source's own session identifier. **This capability owns the definition of that set**; the `retrieval` and `ltm-cli` capabilities reference it and specify only how their own layer surfaces it.

**There is no privileged single source.** A chunk SHALL NOT carry a scalar "the" session identifier, and no consumer SHALL treat any element of the source set as a representative. The set MAY be ordered by source key for display determinism, but that order carries no meaning and element zero is not special.

This replaces an earlier rule that stored one chosen session identifier per chunk ("the most recently observed one"). That rule never held: resume copies preserve the original message timestamp, so the timestamp comparison it relied on always tied, and the outcome was decided by source-key ordering — that is, by file *path*, which is position rather than content. It was also unstable: measurement showed the chosen value changing for a turn whose content never changed, simply because another resume copy appeared and moved the extremum of the set. The `chunks.session_id` column was therefore removed in index layout 5; `chunk_sources` is the only place session identity lives. (Measured in `docs/measurements/2026-08-18-resume-duplication.md`: 12,488 turns across 8,324 files with identical content, 98.9% of them under differing session identifiers.)

`timestamp` SHALL remain a single value. Every source holding a given turn carries that turn's original message timestamp, so the set would have exactly one distinct member — measured at 0.00% divergence across the 2,736 cross-file turns that actually become chunks (8,744 files scanned) (`docs/measurements/2026-08-18-resume-duplication.md`, "補量" section). That measurement describes the corpus as it stands, not a guarantee from the writer of these files: were resume copies ever to rewrite the timestamp, this scalar would acquire exactly the instability that removed the session scalar, and SHALL then be revisited the same way.

#### Scenario: Every chunk is pointered

- **WHEN** a fixture corpus of 3 projects and 50 turns is indexed
- **THEN** the index contains 50 chunks and each carries a non-empty `project`, `uuid` and `timestamp` plus a `sessions` set with at least one entry

#### Scenario: A turn held by two sources carries both session identifiers

- **GIVEN** two session files holding the same turn with identical content and identical message timestamps, as session resume produces
- **WHEN** the corpus is indexed and that turn's chunk is examined
- **THEN** the chunk carries a source set of two entries, one per holding file, each with that file's own session identifier

##### Example: resume copy under differing session identifiers

- **GIVEN** file `s-B.jsonl` holds turn `t-1` under session `s-B`, and file `s-A.jsonl` holds the identical turn `t-1` under session `s-A`, both with the same message timestamp
- **WHEN** the corpus is indexed
- **THEN** exactly one chunk exists for `t-1` and its source set is `{s-A, s-B}` — neither is designated as the chunk's session

#### Scenario: A turn held by one source carries a single-entry set

- **GIVEN** a turn appearing in exactly one session file
- **WHEN** the corpus is indexed and that turn's chunk is examined
- **THEN** the chunk's source set has exactly one entry, holding that file's session identifier

<!-- @trace
source: return-all-navigation-sources
updated: 2026-08-21
code:
  - CHANGELOG.md
  - Sources/LTMIndex/IndexDatabase.swift
  - Sources/LTMIndex/RetrievalEngine.swift
  - Tests/LTMServiceTests/LTMServiceTests.swift
  - Tests/LTMServiceTests/CLICommandTests.swift
  - Tests/LTMIndexTests/IndexDatabaseTests.swift
  - Sources/ltm/Commands.swift
  - Sources/LTMService/LTMService.swift
-->