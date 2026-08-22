## MODIFIED Requirements

### Requirement: Chunk granularity is one conversation turn with full pointer metadata

Indexing SHALL create exactly one chunk per conversation turn. A turn observed through several session files — as happens when a session is resumed or forked and its earlier turns are copied into a new file — SHALL yield one chunk, not one per file. Each chunk SHALL be addressable by the pointer tuple `(project, sessions, uuid, timestamp)` alongside its text and vector, and the tuple SHALL be returned with any retrieval hit derived from that chunk. The `sessions` component is a set held in `chunk_sources`, one entry per source file holding the chunk; the other three are scalar columns on the chunk row.

The chunk's identity SHALL be `(project fingerprint, turn identifier)`, matching the identity of the anchor that addresses it, so that one anchor corresponds to exactly one chunk. The session identifier SHALL NOT participate in chunk identity; it is navigation metadata.

An earlier form of this requirement said "exactly one chunk per jsonl conversation turn", which read as one chunk per turn per file and was implemented with a global uniqueness constraint on the turn identifier alone. Measured over the whole corpus of 8,324 files (`docs/measurements/2026-08-18-resume-duplication.md`), 12,488 turn identifiers appear in more than one file, 100% of them with identical content and 98.9% under different session identifiers — so that constraint caused an upsert to overwrite the stored session identifier, which in turn orphaned every anchor recorded against the earlier value.

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

## ADDED Requirements

### Requirement: A source file that disappears has its chunks invalidated

When a source file present in the previous scan state is absent from the current scan, indexing SHALL remove the chunks derived from it. A source that cannot be read SHALL NOT be treated as absent: the two conditions SHALL be distinguished, and an unreadable source SHALL be reported rather than causing deletion.

Without this, an incremental index retains chunks that a full rebuild would not produce, which violates the pure-derivative invariant while leaving retrievable text that points at a turn no longer in the corpus.

#### Scenario: Deleted source is invalidated

- **GIVEN** an index built over a corpus containing `s-A.jsonl`
- **WHEN** `s-A.jsonl` is deleted and an incremental build runs
- **THEN** chunks derived from `s-A.jsonl` are no longer retrievable, and the incremental result matches a full rebuild

#### Scenario: Unreadable source is reported, not silently invalidated

- **WHEN** a source file exists but cannot be opened during a scan
- **THEN** the build reports the unreadable source and does not delete that source's chunks

### Requirement: An incomplete trailing record is re-read on the next scan

When the tail of a source file contains a partial record — as happens when the file is appended to while being scanned — the recorded resume offset SHALL NOT advance past the last complete record. The verified prefix SHALL cover only the bytes whose records were fully parsed.

The count of records skipped because they were incomplete SHALL be reported separately from the count skipped because they were malformed. Conflating them reports ordinary concurrent writing as corpus corruption.

#### Scenario: A partially written record is indexed on the following scan

- **GIVEN** a scan that reads a source file while its final record is only partially written
- **WHEN** the record is completed and a subsequent incremental scan runs
- **THEN** that record is indexed, and it is not reported as malformed
