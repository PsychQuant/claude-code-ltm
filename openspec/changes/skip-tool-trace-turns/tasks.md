## 1. Tests first

- [x] 1.1 Add scanner tests for "Turns with no text or only tool results produce no chunk" in `Tests/LTMIndexTests/CorpusScannerTests.swift`, one per row of the spec's example table. Each asserts the chunk texts and both `skipped.toolResultOnly` and `skipped.noIndexableText` (the shared helpers `expectSkippedAsResultOnly` and `expectKept` assert all three). Verify: `swift test --filter CorpusScannerTests` failed to compile before 2.2 because the counter did not exist.
- [x] 1.2 Add the mixed-turn anchor test for design decision "The rule applies per record; mixed turns are indexed as today": a record with a `text` block and a metadata-less `tool_use` produces a chunk whose text is `<text>\n⟨tool NAME⟩` and whose anchor span is `0..<text.unicodeScalars.count`, the same values the scanner produced before this change. Verify: the test passes before and after 2.1.
- [x] 1.3 Keep the unit test "tool_result 只記成敗，不記內容" on `indexableText` as it was (both outcomes, payload sentinel), and add `aMixedTurnKeepsOnlyTheResultOutcome`, which runs a `text` block plus an `is_error` `tool_result` through `chunk(from:)` and asserts the exact text and the absent payload. Verify: both pass.

## 2. Scanner, tally, layout

- [x] 2.1 Implement design decision "Result-only is decided from the block structure, not from the text": `isToolResultOnly` is true only for a block-array content with at least one `tool_result` block, no `tool_use` block, and no `text` block that is non-empty after `Anchor.normalize`; other block types are ignored. `chunk(from:…)` checks empty text first (`noIndexableText`), then the predicate (`toolResultOnly`). `toolUseMetadata(from:)` is unchanged from before this change. Verify: every test from 1.1–1.3 passes.
- [x] 2.2 Add `SkipTally.toolResultOnly` per design decision "A separate skip counter, `toolResultOnly`": public, default 0, included in `total`, summed by `add`. Verify: `skipTallyCountsToolResultOnly`, and the existing `ParallelScanTests` still pass with `noIndexableText == 8`.
- [x] 2.3 `ltm build` prints the new counter as its own item (`只有 tool_result N`) in the skip breakdown, next to the "no indexable text" item. Verify: `buildReportsToolResultOnlySkipsSeparately` finds the item with count 1 on a fixture with one result-only record.
- [x] 2.4 Bump `IndexDatabase.layoutVersion` from 6 to 7 per design decision "Layout 6 → 7"; add a `7:` row with the unchanged digest to `pinnedCountSchemaSHA256`, leaving the `6:` row; pin the bump with a literal `7` in `aLayoutFiveIndexIsRebuilt`. Verify: with the constant changed back to 6, `aLayoutFiveIndexIsRebuilt` fails by name (2.5).
- [x] 2.5 Mutation checks with the CLAUDE.md backup-and-restore recipe, one mechanism at a time, each restored and confirmed with `git hash-object` against the pre-mutation value (`43d07af3554ef98448cbabfe57a1b822d331aebb` for `CorpusScanner.swift`, `5de2a0466e8f4d358010bd053eaa533fc3ebd263` for `IndexDatabase.swift`, both the files committed with this task): (a) the guard in `chunk(from:)` replaced by `false` → the four result-only scanner tests, the non-text-block test, `buildReportsToolResultOnlySkipsSeparately` and the IncrementalEquivalenceTests property fail; (b) the `tool_use` branch changed to `continue` → `aNameOnlyToolUseWithAToolResultIsKept` fails; (c) the branch for other block types changed to `return false` → `aNonTextBlockNextToAToolResultIsResultOnly` fails; (d) `layoutVersion` changed to 6 → `aLayoutFiveIndexIsRebuilt` fails.

## 3. Whole-suite equivalence

- [x] 3.1 Add a result-only record to the skip lines `IncrementalEquivalenceTests` writes into every generated file, and assert that the full rebuild counts it under `toolResultOnly`. Run the full `swift test`. Verify: everything passes except the known issue in `BaselineQueryFileTests` that predates this change; record the counts and delete the `ltm-*` directories the run leaves in `TMPDIR`.

## 4. Documentation

- [x] 4.1 Rewrite the `indexableText` doc comment and the `toolResultOnly` field comment in `Sources/LTMIndex/CorpusScanner.swift` so they say which turns produce no chunk and under which counter, and that metadata-less `tool_use` turns are kept. Verify: content review against the spec's example table.
- [x] 4.2 Update the `tool_use` and `tool_result` rows of the "what reaches the index" table in `docs/measurements/README.md`, the dated note next to the paragraph that cites #67's 41.7% share, and the confounders listed for #62's before/after comparison. Verify: content review; `BaselineQueryFileTests` still passes.
- [x] 4.3 Add a dated addendum to `docs/measurements/2026-08-26-tool-payload-share.md` stating that its 13.0% → 83.0% coverage figure counted result-only turns as covered, which this change stops indexing; the original numbers stay as recorded. Verify: content review.
- [x] 4.4 CHANGELOG under Unreleased: layout 7 (one rebuild together with #61), result-only turns produce no chunk, metadata-less `tool_use` turns kept, the new skip counter in `ltm build` and in the `⚠` skip line; no effect numbers. Verify: content review against the honesty rule in CLAUDE.md.
- [x] 4.5 Replace statements that the release ships layout 6: `docs/measurements/2026-09-07-gate-first-touch.md`, the main corpus-indexing spec's scenario "The orphan check uses the partial index", and the conditional in #61's CHANGELOG entry. Verify: `grep` for "layout 6" / "layout-6" finds only historical statements.

## 5. Measurement

- [x] 5.1 The row recount, index size, build time and #62's two query groups' top three cannot be measured until a release rebuilds the real index; they are tracked in #84 (user decision `issuecomment-6109083299`). Verify: #84 exists and names #67.
