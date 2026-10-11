## MODIFIED Requirements

### Requirement: Chunk granularity is one conversation turn with full pointer metadata

Indexing SHALL create exactly one chunk per jsonl conversation turn, except the turns enumerated in "Turns with no text or only tool results produce no chunk", which produce none. Each chunk SHALL be addressable by the pointer tuple `(project, sessions, uuid, timestamp)` alongside its text and vector, and the tuple SHALL be returned with any retrieval hit derived from that chunk. The `sessions` component is a set held in `chunk_sources`, one entry per source file holding the chunk; the other three are scalar columns on the chunk row.

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

### Requirement: Turns with no text or only tool results produce no chunk

This requirement covers records whose top-level `type` is `user` or `assistant`, whose pointer fields are present and valid, and that carry a `message` object. Among those records, indexing SHALL produce no chunk in exactly the following two cases, and in no other case on account of the turn's content. This is a closed enumeration: a further case SHALL NOT be added by analogy to these two.

1. **No indexable text**: the turn's indexable text is empty, or empty after normalization. The scan SHALL count it under `noIndexableText`.
2. **Tool results only**: the turn's `message.content` is a block array that contains at least one `tool_result` block, and every other block yields no indexable text: it is not a `tool_use` block (a `tool_use` block always yields a `⟨tool NAME…⟩` marker, whether or not it has metadata fields), and if it is a `text` block its text is empty after normalization. Blocks of any other type yield no indexable text. The scan SHALL count such a turn under `toolResultOnly`. Case 1 is checked first; a turn counted under case 1 SHALL NOT also be counted under case 2. (A turn in case 2 always has the non-empty indexable text `⟨tool_result ok⟩` or `⟨tool_result error⟩`, so the two cases do not overlap in practice.)

A turn whose content is a plain string SHALL NOT fall under case 2, whatever the string says: the decision is made from the block structure, never by matching the text against a marker. Every turn covered by this requirement and falling under neither case SHALL be indexed with exactly the text, span and anchor it would have had without this requirement — in particular a turn that holds a `tool_use` block, with or without metadata fields.

Both counters SHALL be part of the scan's skip tally, included in its total and summed when tallies are combined, so that a change in either count is visible on its own.

#### Scenario: A record holding only a tool result produces no chunk

- **WHEN** a corpus whose only conversation turn is a `type: user` record with one `tool_result` block is scanned
- **THEN** the scan produces no chunk, `skipped.toolResultOnly` equals 1, and `skipped.noIndexableText` equals 0

#### Scenario: A tool call without metadata fields is still indexed

- **WHEN** a `type: assistant` record holds one `tool_use` block named `TodoWrite` whose `input` has none of the metadata fields
- **THEN** the record produces one chunk whose text is `⟨tool TodoWrite⟩`, and nothing is counted under `toolResultOnly`

#### Scenario: A tool call with a metadata field is still indexed

- **WHEN** a `type: assistant` record holds one `tool_use` block named `Bash` whose `input.command` is `ls`
- **THEN** the record produces one chunk whose text is `⟨tool Bash command=ls⟩`

#### Scenario: A block that yields no text does not keep a tool result

- **WHEN** a `type: assistant` record holds a `thinking` block followed by a `tool_result` block
- **THEN** the record produces no chunk and is counted under `toolResultOnly`

#### Scenario: A mixed turn keeps its text and anchor

- **WHEN** a `type: assistant` record holds a `text` block `checking the build` followed by a `tool_use` block without metadata fields
- **THEN** the record produces one chunk whose text, span and anchor equal those produced before this requirement existed

##### Example: which records produce a chunk

| Content of the record | Chunk | Counted under |
| --- | --- | --- |
| block array: one `tool_result` | none | `toolResultOnly` |
| block array: two `tool_result` blocks | none | `toolResultOnly` |
| block array: whitespace-only `text` block and one `tool_result` | none | `toolResultOnly` |
| block array: `thinking` block and one `tool_result` | none | `toolResultOnly` |
| block array: `image` block and one `tool_result` | none | `toolResultOnly` |
| block array: `tool_use` named `TodoWrite` with no metadata field | `⟨tool TodoWrite⟩` | — |
| block array: `tool_use` with no metadata field and one `tool_result` | `⟨tool TodoWrite⟩` and the marker, on two lines | — |
| block array: `tool_use` named `Read` with `file_path` set | `⟨tool Read file_path=…⟩` | — |
| block array: `text` block and `tool_result` | text and marker, unchanged | — |
| plain string equal to `⟨tool_result ok⟩` | the string, unchanged | — |
| block array: whitespace-only `text` block only | none | `noIndexableText` |

#### Scenario: A plain-string prompt that looks like a marker is kept

- **WHEN** a `type: user` record's `message.content` is the plain string `⟨tool_result ok⟩`
- **THEN** the record produces one chunk with that text and nothing is counted under `toolResultOnly`
