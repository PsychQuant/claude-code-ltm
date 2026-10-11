## Context

`CorpusScanner.chunk(from:…)` turns one jsonl record into one chunk. Its text comes from `indexableText(from:)`: a plain-string `message.content` is returned as is; a block array contributes each non-empty `text` block, one `⟨tool NAME field=value…⟩` marker per `tool_use` block (the seven fields in `toolMetadataFields`, each clipped to `toolMetadataFieldLimit`), and one `⟨tool_result ok|error⟩` marker per `tool_result` block. A record whose text is empty, or normalizes to empty, is skipped and counted as `noIndexableText`.

Claude Code writes each `tool_result` as its own `type: user` record whose content is only that block, and a `tool_use` usually sits alone in its own `type: assistant` record. So since #6 every tool result became a chunk whose whole text is one of two strings, and every metadata-less tool call became a chunk whose whole text is `⟨tool NAME⟩`. The #67 diagnosis counted them on the 2026-10-11 index (layout 5): 496,411 and 40,619 of 1,130,266 chunks, 224 distinct texts in all, with the read-only SQL in `issuecomment-6106114749`.

Stakeholders: every retrieval entry point (CLI, MCP, recall hook) reads the same vector channel; the #61 layout-6 change is unreleased and must ship in the same release.

## Goals / Non-Goals

**Goals:**

- A turn whose indexable content is nothing but tool-trace markers produces no chunk.
- No existing chunk changes its text, span or anchor because of this rule (mixed turns are untouched).
- The skipped turns are counted under their own category, so an unexpected change in the corpus format cannot hide inside them.
- Existing indexes are rebuilt once, together with #61's rebuild.

**Non-Goals:**

- Claims about query latency, index size on disk or build time. Those are measured after the release with #75 and #79; this change states only which rows are no longer produced.
- Attaching a tool result's success or failure to the `tool_use` chunk it belongs to. The result arrives in a later record; attaching it would rewrite an already indexed chunk (its anchor is content-addressed), and an incremental build would differ from a full rebuild.
- Filtering at retrieval time (#62's eligibility filter). It would leave the rows and vectors in the index.
- Identical-text duplicates among substantive turns (#77) and `tool_use` chunks that carry metadata fields (they are 407,230 distinct texts out of 455,605 and are the reason #6 indexes tool metadata).

## Decisions

### Trace-only is decided from the block structure, not from the text

A turn is trace-only when its `message.content` is a block array that contains at least one tool-trace block and no other block contributes indexable text after normalization. A tool-trace block is a `tool_result` block, or a `tool_use` block for which none of the `toolMetadataFields` holds a non-empty string. Text-pattern matching was rejected: a user who types `⟨tool_result ok⟩` as a plain-string prompt would lose that turn, and a text check could not tell a marker from a quotation of one.

The "has a metadata field" predicate is the one `toolUseMetadata(from:)` already uses to decide whether to append `field=value`; both call one shared helper so the two cannot drift.

### The rule applies per record; mixed turns are indexed as today

Alternative considered: drop the markers at block level everywhere. That changes the text, span and anchor of every mixed chunk (38 chunks with a result marker plus other text, and at most 501 multi-line chunks containing any tool marker, per the diagnosis) — rewriting indexed content for no retrieval gain. Per-record skipping touches no chunk that survives.

### Metadata-less tool_use blocks count as traces

Alternative considered: keep them, since they say which tool ran. With 40,619 chunks over 222 texts, the hit returned for a tool name is whichever rowid sorts first, so the name does not navigate to any particular turn. The user chose to drop them with the result-only turns (#67 discussion).

### A separate skip counter, `toolTraceOnly`

Alternative considered: count them as `noIndexableText`. Roughly half a million expected skips would then mask any future format change that empties real text. `SkipTally` gains `toolTraceOnly`, included in `total` and in `merge`, and `ltm build` lists it as its own item. The check order is: empty text first (`noIndexableText`), then trace-only (`toolTraceOnly`).

### Layout 6 → 7

Alternative considered: fold the change into the unreleased layout 6. An index already built as layout 6 by an unreleased build would then keep the trace chunks with no prompt to rebuild. Users coming from layout 5 rebuild once either way. `DerivedCountTests` pins the trigger and partial-index definitions per layout; the definitions do not change, so layout 7 gets a new row with the same digest and the layout-6 row stays.

## Implementation Contract

- **Observable behavior**: scanning a corpus yields no chunk for a trace-only turn and increments `skipped.toolTraceOnly` once per such turn; every other turn yields the same chunk, byte for byte, as before this change.
- **Interface**: `SkipTally.toolTraceOnly: Int` (public, default 0), counted in `total` and summed by `merge`; a scanner-internal predicate for trace-only content; `IndexDatabase.layoutVersion == 7`.
- **Command output**: `ltm build`'s skip breakdown gains one item for trace-only turns, next to "no indexable text"; nothing else in any command's output changes.
- **Failure modes**: none new. A malformed block (missing `type`, non-dictionary `input`) is treated exactly as `indexableText` treats it today; a block array with no trace block is never trace-only.
- **Acceptance**:
  - CorpusScannerTests cover: a lone `tool_result` record; a lone metadata-less `tool_use`; several trace blocks in one record; a whitespace-only `text` block next to a marker; a `tool_use` with a metadata field (kept); a mixed turn whose text and anchor span equal the pre-change values; a plain-string prompt equal to a marker literal (kept); and the two counters.
  - Removing the trace-only guard turns those tests red (mutation, CLAUDE.md recipe).
  - The full suite passes, including IncrementalEquivalenceTests and the layout-pin test with the new row.
- **Scope boundaries**: in scope — the scanner, `SkipTally`, the build report line, the layout constant and its pin, the listed docs and CHANGELOG. Out of scope — retrieval, the recall hook, MCP output, memory events, and any measurement of speed or size.

## Risks / Trade-offs

- [Lost signal: which tool calls failed] → `⟨tool_result error⟩` alone never said which call failed, so no navigation is lost; recovering it would need cross-record correlation, recorded as out of scope above.
- [Memory events anchored to trace chunks become orphans] → this machine has no event log (`~/.claude-ltm/memory/` does not exist); elsewhere the orphaned events point at chunks whose content was a marker. Forgetting is allowed; nothing is rewritten.
- [Coverage figures in older records read differently] → the #6 record's 13% → 83% counted trace-only turns as covered; an addendum says so instead of editing the old numbers.

## Migration Plan

Ship in the same release as #61. On first `ltm build` after upgrading, the layout-version mismatch discards the derived index and rebuilds it from nothing; until then the query path refuses with the existing "run `ltm build --full`" message. Rollback is the previous binary plus a full rebuild.

## Open Questions

(none)
