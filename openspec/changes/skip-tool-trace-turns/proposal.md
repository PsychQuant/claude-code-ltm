## Why

Claude Code writes every `tool_result` as its own `type: user` record, and #6 made the scanner emit `⟨tool_result ok⟩` or `⟨tool_result error⟩` for those blocks, so every such record became a chunk. On the 2026-10-11 index (layout 5, 1,130,266 chunks) 496,411 chunks carry only one of those two texts and 40,619 more are a `tool_use` marker with no metadata field: 537,030 chunks drawn from 224 distinct texts (#67 diagnosis, `issuecomment-6106114749`, which gives the read-only SQL). Identical text means an identical vector. The vector channel ranks every chunk by dot product and breaks ties by rowid, so whenever that vector is close to a query, the channel's candidate slice fills with interchangeable chunks and substantive turns lose their vector contribution (#62's synthetic reproduction ranks `⟨tool_result ok⟩` third). Such a chunk has no content that could cue it back individually: it occupies retrieval slots without ever being retrievable by what it says.

## What Changes

- **BREAKING (derived layout)**: layout version 6 → 7. Layout 6 has not shipped (#61, CHANGELOG Unreleased), so users on layout 5 rebuild once either way; a layout-6 index built from an unreleased build is rebuilt instead of silently keeping the trace chunks.
- A turn whose every indexable part is a tool-trace marker — a `tool_result` block, or a `tool_use` block carrying none of the seven metadata fields — produces no chunk.
- A turn that mixes such markers with any other indexable part is indexed exactly as today: its text, span and anchor do not change.
- The scan's skip tally gains a separate counter for these turns, and `ltm build` reports it as its own item, apart from "no indexable text".
- The corpus-indexing requirement on chunk granularity no longer claims a chunk for every turn, and a new requirement states the closed enumeration of turns that produce no chunk.
- Documentation of what reaches the index is corrected: the scanner's doc comment on indexable text, the "what reaches the index" table in the measurement rules document, and a dated addendum to the #6 payload-share record noting that its 13% → 83% coverage figure counted trace-only turns as covered.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `corpus-indexing`: which turns produce a chunk, and a new skip category for turns that are only tool traces.

## Impact

- Affected specs: corpus-indexing
- Affected code:
  - Modified: Sources/LTMIndex/CorpusScanner.swift, Sources/LTMIndex/IndexDatabase.swift, Sources/ltm/Commands.swift, Tests/LTMIndexTests/CorpusScannerTests.swift, Tests/LTMIndexTests/DerivedCountTests.swift, docs/measurements/README.md, docs/measurements/2026-08-26-tool-payload-share.md, CHANGELOG.md
