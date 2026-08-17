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

Indexing SHALL create exactly one chunk per jsonl conversation turn. Each chunk SHALL store the pointer tuple `(project, sessionId, uuid, timestamp)` alongside its text and vector, and the tuple SHALL be returned with any retrieval hit derived from that chunk.

#### Scenario: Every chunk is pointered

- **WHEN** a fixture corpus of 3 projects and 50 turns is indexed
- **THEN** the index contains 50 chunks and each chunk row carries non-empty values for all four pointer fields
