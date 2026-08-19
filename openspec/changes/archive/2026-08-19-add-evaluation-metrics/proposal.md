## Why

The `strategy-comparison` capability currently reports only interleaving preference counts (credit/penalty/rate) per query class. Issue #16 (2026-08-11, three independent verify lenses) found that two decisions from the original Clarity Surface were never implemented, and a subsequent review round (R5) deferred three more decisions into this capability's scope. Until these gaps close, CLAUDE.md's honesty boundary applies literally: no claim of one strategy being better than another has any measurement support, because the comparison mechanism cannot yet distinguish "no recall" from "wrong ranking," cannot detect single-channel retrieval degradation, and reports a starting-side-imbalanced win rate without correcting for the imbalance.

## What Changes

- Add a two-stage primary metric: Recall@20 confirms an anchor was retrieved at all; nDCG@10 then scores ranking quality only among comparisons that passed the recall stage. Missing recall is reported separately from — and is treated as more severe than — a correct anchor ranked poorly.
- Add three-track reporting: every comparison reports lexical-only, vector-only, and fused channel results separately, so that a fused-track win can be attributed to (or ruled out as) single-channel degradation (e.g. Chinese BM25 failure).
- Add starting-side-corrected scoring: `startingSide` is fit as a fixed effect (`outcome ~ policy + startingSide`) rather than left as an uncorrected confound; the existing raw A/B imbalance counts remain but are no longer the only signal.
- Change `StrategyScore.rate`'s denominator source of truth to `StrategyScore.presented` (the count of `shown` events actually recorded by the caller); deprecate `PresentationRecord.presentedCount(for:)` as the denominator.
- Document, in the `strategy-comparison` spec, that the query-class label set (`cjk-2char`/`cjk-3char`/`cjk-4plus`/`latin-alnum`/`mixed`) is validated only for Chinese and English input; queries in other scripts fall into `latin-alnum` and their classification is not reliable.
- Document, in the `strategy-comparison` spec, that this capability does not attempt to collect "known-unreachable" negative cases (queries the user knows should hit something but that returned nothing) — the query text required to construct such a case cannot be retained under the existing no-query-text policy, and no query-class-only substitute carries acceptable information budget under the closed-label-set exception. The evaluation set is therefore known to exclude event-log-invisible failures (the zero-event selection-bias class), and this is a stated, accepted limitation rather than a bug.

## Non-Goals

- **Building the ground-truth dataset** (a set of `(query, expected turn)` pairs) is explicitly out of scope for this change. The two-stage metric and three-track reporting require it to produce real numbers, but assembling that dataset is an independent, likely much larger effort (per issue #16's own framing) and is tracked separately, not as a task here.
- **Expanding the query-class label set** to cover scripts beyond Chinese/English (Japanese kana, Hangul, Cyrillic, etc.) is out of scope. CLAUDE.md's own governing principle — "opening the value domain turns a statistic back into content" — requires measurement on those scripts before the set can be widened responsibly, and no such measurement exists yet.
- **Collecting negative cases** (queries known to have no answer in the retrievable set) is explicitly rejected as an approach in this change, not merely deferred — see the "What Changes" section above for why the closed-label-set exception does not extend to cover it.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `strategy-comparison`: adds the two-stage Recall@20→nDCG@10 metric, three-track (lexical/vector/fused) reporting, starting-side fixed-effect correction, the `StrategyScore.rate` denominator change, and two new documented limitations (query-class script coverage, negative-case exclusion).

## Impact

- Affected specs: `openspec/specs/strategy-comparison/spec.md`
- Affected code:
  - Modified: `Sources/LTMEval/ComparisonReport.swift`, `Sources/LTMEval/PresentationRecord.swift`
  - New: two-stage/three-track scoring logic within `Sources/LTMEval/ComparisonReport.swift` (or a new file under `Sources/LTMEval/` if the scoring logic grows large enough to warrant splitting out — decided during implementation)
  - Tests: `Tests/LTMEvalTests/ComparisonReportTests.swift`
