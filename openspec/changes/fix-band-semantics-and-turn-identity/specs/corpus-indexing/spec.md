## MODIFIED Requirements

### Requirement: Chunk granularity is one conversation turn with full pointer metadata

Indexing SHALL create exactly one chunk per conversation turn. A turn observed through several session files — as happens when a session is resumed or forked and its earlier turns are copied into a new file — SHALL yield one chunk, not one per file. Each chunk SHALL store the pointer tuple `(project, sessionId, uuid, timestamp)` alongside its text and vector, and the tuple SHALL be returned with any retrieval hit derived from that chunk.

The chunk's identity SHALL be `(project fingerprint, turn identifier)`, matching the identity of the anchor that addresses it, so that one anchor corresponds to exactly one chunk. The session identifier SHALL NOT participate in chunk identity; it is navigation metadata. When a turn has been observed through several session files, the stored `sessionId` SHALL be the most recently observed one, because that is the session a reader is most likely able to open.

An earlier form of this requirement said "exactly one chunk per jsonl conversation turn", which read as one chunk per turn per file and was implemented with a global uniqueness constraint on the turn identifier alone. Measured over the whole corpus of 8,324 files (`docs/measurements/2026-08-18-resume-duplication.md`), 12,488 turn identifiers appear in more than one file, 100% of them with identical content and 98.9% under different session identifiers — so that constraint caused an upsert to overwrite the stored session identifier, which in turn orphaned every anchor recorded against the earlier value.

#### Scenario: Every chunk is pointered

- **WHEN** a fixture corpus of 3 projects and 50 turns is indexed
- **THEN** the index contains 50 chunks and each chunk row carries non-empty values for all four pointer fields

#### Scenario: A turn observed through two session files yields one chunk

- **GIVEN** a corpus where turn `t-1` appears in session file `s-A.jsonl` and again, with identical text, in `s-B.jsonl`
- **WHEN** the corpus is indexed
- **THEN** exactly one chunk exists for `t-1`, its pointer names `s-B` as the session, and a query matching that text returns it once

##### Example: De-duplication across a resume

| Source file | Turn id | Text | Session |
| ----------- | ------- | ---- | ------- |
| s-A.jsonl | t-1 | "the tokenizer decision" | s-A |
| s-B.jsonl | t-1 | "the tokenizer decision" | s-B |
| s-B.jsonl | t-2 | "and its measurement" | s-B |

Indexing yields two chunks (`t-1`, `t-2`), not three. `t-1`'s pointer reports session `s-B`.

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
