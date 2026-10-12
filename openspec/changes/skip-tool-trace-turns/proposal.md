## Why

Claude Code writes every `tool_result` as its own `type: user` record, and #6 made the scanner emit `⟨tool_result ok⟩` or `⟨tool_result error⟩` for those blocks, so every such record became a chunk. On the 2026-10-11 index (layout 5, 1,130,266 chunks) 496,411 chunks carry only one of those two texts (#67 diagnosis, `issuecomment-6106114749`, which gives the read-only SQL). Identical text means an identical vector. The vector channel ranks every chunk by dot product and breaks ties by rowid, so whenever that vector is close to a query, the channel's candidate slice fills with interchangeable chunks and substantive turns lose their vector contribution (#62's synthetic reproduction ranks `⟨tool_result ok⟩` third; no `docs/measurements/` record covers how often this happens on the real index). Such a chunk has no content that could cue it back individually.

## What Changes

- **BREAKING (derived layout)**: layout version 6 → 7. Layout 6 has not shipped (#61, CHANGELOG Unreleased), so users on layout 5 rebuild once either way; a layout-6 index built from an unreleased build is rebuilt instead of silently keeping the result-only chunks.
- A turn whose content is a block array with at least one `tool_result` block, and whose every block that is not a `tool_result` yields no text after normalization, produces no chunk ("result-only").
- Every other turn is indexed exactly as today: its text, span and anchor do not change. That includes a `tool_use` with no metadata field (`⟨tool NAME⟩`): the diagnosis also counted 40,619 of those, and the first version of this change dropped them too, but verify R1 found that many tool names occur only once to three times in the corpus, so a name can be the only cue to its turn, so the user kept the whole class (`issuecomment-6109083299`). Strictly, R1 measured how rare those names are, not how well a query by name finds them.
- The scan's skip tally gains a separate counter for these turns, and `ltm build` reports it as its own item, apart from "no indexable text". Because the tally's total includes it, the `⚠ 併入時跳過 N 筆紀錄` line that `ltm query` (and the other commands that merge before they run) print on stderr counts these turns too; that line already appears on most merges, since non-turn records are counted there.
- The corpus-indexing requirement on chunk granularity no longer claims a chunk for every turn, and a new requirement states the closed enumeration of turns that produce no chunk.
- Documentation of what reaches the index is corrected: the scanner's doc comment on indexable text, the "what reaches the index" table in the measurement rules document, and a dated addendum to the #6 payload-share record noting that its 13% → 83% coverage figure counted result-only turns as covered, and the confounders listed for #62's before/after comparison.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `corpus-indexing`: which turns produce a chunk, and a new skip category for result-only turns.

## Impact

- Affected specs: corpus-indexing
- Affected code:
  - Modified: Sources/LTMIndex/CorpusScanner.swift, Sources/LTMIndex/IndexDatabase.swift, Sources/ltm/Commands.swift, Tests/LTMIndexTests/CorpusScannerTests.swift, Tests/LTMIndexTests/DerivedCountTests.swift, Tests/LTMIndexTests/IndexBuilderTests.swift, Tests/LTMIndexTests/IncrementalEquivalenceTests.swift, Tests/LTMServiceTests/CLICommandTests.swift, scripts/probes/gate-matrix.sh, docs/measurements/README.md, docs/measurements/2026-08-26-tool-payload-share.md, docs/measurements/2026-09-07-gate-first-touch.md, openspec/specs/corpus-indexing/spec.md, CHANGELOG.md
