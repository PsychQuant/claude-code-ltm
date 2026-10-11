## Context

`CorpusScanner.chunk(from:…)` turns one jsonl record into one chunk. Its text comes from `indexableText(from:)`: a plain-string `message.content` is returned as is; a block array contributes each non-empty `text` block, one `⟨tool NAME field=value…⟩` marker per `tool_use` block (the seven fields in `toolMetadataFields`, each clipped to `toolMetadataFieldLimit`), and one `⟨tool_result ok|error⟩` marker per `tool_result` block. A record whose text is empty, or normalizes to empty, is skipped and counted as `noIndexableText`.

Claude Code writes each `tool_result` as its own `type: user` record whose content is only that block. So since #6 every tool result became a chunk whose whole text is one of two strings. The #67 diagnosis counted 496,411 of them among 1,130,266 chunks on the 2026-10-11 index (layout 5), with the read-only SQL in `issuecomment-6106114749`. It also counted 40,619 chunks whose whole text is a metadata-less `⟨tool NAME⟩`; this change keeps those (see below).

Stakeholders: every retrieval entry point (CLI, MCP, recall hook) reads the same vector channel; the #61 layout-6 change is unreleased and must ship in the same release.

## Goals / Non-Goals

**Goals:**

- A result-only turn produces no chunk.
- No existing chunk changes its text, span or anchor because of this rule (mixed turns are untouched).
- The skipped turns are counted under their own category, so an unexpected change in the corpus format cannot hide inside them.
- Existing indexes are rebuilt once, together with #61's rebuild.

**Non-Goals:**

- Claims about query latency, index size on disk, build time or retrieval quality. The row recount, index size, build time, query latency and #62's two query groups' top three are measured in #84, on one corpus snapshot in side-path indexes built with and without this change. This change states only which rows are no longer produced.
- Attaching a tool result's success or failure to the `tool_use` chunk it belongs to. The result arrives in a later record; attaching it would rewrite an already indexed chunk (its anchor is content-addressed), and an incremental build would differ from a full rebuild.
- Filtering at retrieval time (#62's eligibility filter). It would leave the rows and vectors in the index.
- Identical-text duplicates among substantive turns (#77) and `tool_use` chunks that carry metadata fields (they are 407,230 distinct texts out of 455,605 and are the reason #6 indexes tool metadata).

## Decisions

### Result-only is decided from the block structure, not from the text

A turn is result-only when its `message.content` is a block array with at least one `tool_result` block and every block that is not a `tool_result` block yields no text in `indexableText` after normalization: no `tool_use` block at all (with or without metadata it yields `⟨tool NAME…⟩`), every `text` block empty after normalization, and any other block type (`thinking`, `image`, `document`, …) or a block without `type`, which `indexableText` never reads. Text-pattern matching was rejected: a user who types `⟨tool_result ok⟩` as a plain-string prompt would lose that turn, and a text check could not tell a marker from a quotation of one.

### The rule applies per record; mixed turns are indexed as today

Alternative considered: drop the markers at block level everywhere. That changes the text, span and anchor of every mixed chunk (38 chunks with a result marker plus other text, and at most 501 multi-line chunks containing any tool marker, per the diagnosis) — rewriting indexed content for no retrieval gain. Per-record skipping touches no chunk that survives.

### Metadata-less tool_use blocks are kept

The first version of this change dropped them too, reasoning that with 40,619 chunks over 222 texts a tool name returns whichever rowid sorts first and so navigates to no particular turn. Verify R1 refuted that for the long tail. Its method: a read-only scan of `~/.claude/projects/**/*.jsonl` on 2026-10-11 (19,441 files), parsing only lines that contain `"tool_use"`, re-implementing the first version's predicate in Python, keeping records it classified as trace-only that hold a `tool_use`, deduplicating by (project directory, uuid) — the shape of the index's identity key — and grouping by the sequence of tool names, printing only a histogram. Result, counted in records: 43,327 records over 235 texts; 96 texts occur at most three times (about 150 records); the top five texts hold 82%. This measures frequency only: a rare tool name may be the only cue to its turn, but whether a query by that name actually ranks the turn first was not measured (`tool_use` chunks with metadata for the same tool and prose that names it compete for the same hits). Keeping only the frequent names would make a chunk's existence depend on corpus-wide statistics, which breaks invariant 2, so the choice is the whole class or none. The user kept the whole class (`issuecomment-6109083299`, which also records the original spectra-discuss decisions).

### A separate skip counter, `toolResultOnly`

Alternative considered: count them as `noIndexableText`. Roughly half a million expected skips would then mask any future format change that empties real text. `SkipTally` gains `toolResultOnly`, included in `total` and summed by `add`, and `ltm build` lists it as its own item. The check order is: empty text first (`noIndexableText`), then result-only (`toolResultOnly`); a result-only turn always has the non-empty text `⟨tool_result ok|error⟩`, so the two never overlap. Because `total` includes it, the `⚠ 併入時跳過 N 筆紀錄` stderr line printed by the commands that merge before they run counts these turns too.

### Layout 6 → 7

Alternative considered: fold the change into the unreleased layout 6. An index already built as layout 6 by an unreleased build would then keep the result-only chunks with no prompt to rebuild. Users coming from layout 5 rebuild once either way. `DerivedCountTests` pins the trigger and partial-index definitions per layout; the definitions do not change, so layout 7 gets a new row with the same digest and the layout-6 row stays. That table passes at either layout, so the bump itself is pinned by a literal `7` in `aLayoutFiveIndexIsRebuilt` (verify R1 found that comparing with the constant left a revert to 6 green).

## Implementation Contract

- **Observable behavior**: scanning a corpus yields no chunk for a result-only turn and increments `skipped.toolResultOnly` once per such turn; every other turn yields the same chunk, byte for byte, as before this change.
- **Interface**: `SkipTally.toolResultOnly: Int` (public, default 0), counted in `total` and summed by `add`; a scanner-internal predicate `isToolResultOnly`; `IndexDatabase.layoutVersion == 7`.
- **Command output**: every count that is derived from which records produce chunks changes accordingly. Today that means: `ltm build`'s skip breakdown gains one item for result-only turns, next to "no indexable text"; the `⚠ 併入時跳過 N 筆紀錄` stderr line counts them in N; and the query footer `查詢前併入 N 個來源檔的新內容` no longer counts a source whose only new records since the last merge are result-only (its cursor still advances), so the footer can disappear where it used to show such a source. MCP responses carry neither the skip tally nor that footer, so they do not change.
- **Failure modes**: none new. A malformed block (missing `type`) is skipped exactly as `indexableText` skips it; a block array with no `tool_result` block is never result-only.
- **Acceptance**:
  - CorpusScannerTests cover every row of the spec's example table, each asserting the chunk texts and both counters, plus a mixed turn whose text and anchor span equal the pre-change values.
  - Each mechanism has its own red test (mutation, CLAUDE.md recipe): the guard in `chunk(from:)`, the `tool_use` branch, the branch for other block types, and the layout constant.
  - IncrementalEquivalenceTests mixes a result-only record into every generated file and asserts that the full rebuild counts it.
  - The full suite passes.
- **Scope boundaries**: in scope — the scanner, `SkipTally`, the build report line, the layout constant and its pin, the listed docs and CHANGELOG. Out of scope — retrieval, the recall hook, MCP output, memory events, and any measurement of speed or size.

## Risks / Trade-offs

- [Lost signal: which tool calls failed] → `⟨tool_result error⟩` alone never said which call failed, so no navigation is lost; recovering it would need cross-record correlation, recorded as out of scope above.
- [Memory events anchored to result-only chunks become orphans] → this machine has no event log (`~/.claude-ltm/memory/` does not exist); elsewhere the orphaned events point at chunks whose content was a marker. Forgetting is allowed; nothing is rewritten. The orphaning is silent: the anchor resolves to `turnMissing` although the turn is still in the corpus, and since such a turn can never again be a candidate, no ranking reason ever mentions it.
- [Coverage figures in older records read differently] → the #6 record's 13% → 83% counted result-only turns as covered; an addendum says so instead of editing the old numbers.

## Migration Plan

Ship in the same release as #61. On first `ltm build` after upgrading, the layout-version mismatch discards the derived index and rebuilds it from nothing; until then the query path refuses with the existing "run `ltm build --full`" message. Rollback is the previous binary plus a full rebuild.

## Open Questions

(none)
