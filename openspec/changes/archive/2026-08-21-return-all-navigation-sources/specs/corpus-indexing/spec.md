## MODIFIED Requirements

### Requirement: Chunk granularity is one conversation turn with full pointer metadata

Indexing SHALL create exactly one chunk per jsonl conversation turn. Each chunk SHALL store the pointer tuple `(project, sessionId, uuid, timestamp)` alongside its text and vector, and the tuple SHALL be returned with any retrieval hit derived from that chunk.

**A chunk is routinely held by more than one source file.** Session resume copies the same turn into a new file, so one turn commonly exists in several session files; deduplication is by content, so those copies produce exactly one chunk. The chunk SHALL therefore additionally carry the set of session identifiers of every source file that holds it — one entry per holding source, each entry being that source's own session identifier. **This capability owns the definition of that set**; the `retrieval` and `ltm-cli` capabilities reference it and specify only how their own layer surfaces it.

The `sessionId` of the pointer tuple SHALL be the session identifier of the holding source whose source key sorts first lexicographically. This value is **a stable representative of the source set and carries no claim about observation order**. An earlier rule described it as "the most recently observed source", which was never true in practice: resume copies preserve the original message timestamp, so the timestamp comparison that rule relied on always tied, and the outcome was decided by source-key ordering alone (measured in `docs/measurements/2026-08-18-resume-duplication.md`: 12,488 turns across 8,324 files with identical content, 98.9% of them under differing session identifiers).

`timestamp` SHALL remain a single value. Every source holding a given turn carries that turn's original message timestamp, so the set would have exactly one distinct member; this is a consequence of the measured resume behavior cited above, and is to be revisited if that behavior changes.

#### Scenario: Every chunk is pointered

- **WHEN** a fixture corpus of 3 projects and 50 turns is indexed
- **THEN** the index contains 50 chunks and each chunk row carries non-empty values for all four pointer fields

#### Scenario: A turn held by two sources carries both session identifiers

- **GIVEN** two session files holding the same turn with identical content and identical message timestamps, as session resume produces
- **WHEN** the corpus is indexed and that turn's chunk is examined
- **THEN** the chunk carries a source set of two entries, one per holding file, each with that file's own session identifier

##### Example: resume copy under differing session identifiers

- **GIVEN** file `s-B.jsonl` holds turn `t-1` under session `s-B`, and file `s-A.jsonl` holds the identical turn `t-1` under session `s-A`, both with the same message timestamp
- **WHEN** the corpus is indexed
- **THEN** exactly one chunk exists for `t-1`, its source set is `{s-A, s-B}`, and its pointer `sessionId` is `s-A` (source key `s-A.jsonl` sorts first)

#### Scenario: A turn held by one source carries a single-entry set

- **GIVEN** a turn appearing in exactly one session file
- **WHEN** the corpus is indexed and that turn's chunk is examined
- **THEN** the chunk's source set has exactly one entry, whose session identifier equals the pointer tuple's `sessionId`
