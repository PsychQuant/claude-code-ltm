## Context

`Sources/LTMEval/ComparisonReport.swift` currently scores a live A/B interleaving comparison (two `MemoryStrategy` implementations, one candidate list, one interleaved presentation) into per-query-class `credit`/`penalty`/`rate` counts. This is a *preference* signal — it says which strategy the user interacted with more, not whether either strategy retrieved the right thing. Issue #16 (three independent verify lenses, 2026-08-11; extended by round R5, 2026-08-16) found two classes of gap against this capability's own stated intent:

1. **Missing metrics.** The spec never committed to Recall@20→nDCG@10 or per-channel (lexical/vector/fused) breakdown, even though the original issue that authorized `strategy-comparison` (#1) called for them. `ComparisonReport`'s existing preference-count output cannot answer "did the fused channel actually retrieve the right anchor" — it can only answer "which strategy did the user prefer among what was shown."
2. **Uncorrected confounds and inconsistent bookkeeping in the existing live comparison**: `startingSide` is recorded but never used to correct the reported rate; two candidate denominators exist for `StrategyScore.rate` and only one is wired up, but the unused one is still public API surface.

This change resolves the spectra-discuss decision recorded on issue #16 (2026-08-19): five independent sub-decisions, all converging toward the honesty-boundary side of the trade-off ("state the limitation" over "build a fragile workaround").

## Goals / Non-Goals

**Goals:**

- Give `strategy-comparison` a way to express "the anchor was never retrieved" as a distinct, more severe outcome than "the anchor was retrieved but ranked low" (Recall@20 → nDCG@10 two-stage metric).
- Give `strategy-comparison` a way to attribute a fused-channel win/loss to a specific retrieval channel, so single-channel degradation (e.g. Chinese BM25 failure) is distinguishable from genuine fused-ranking improvement (three-track reporting).
- Correct the existing live interleaving comparison's starting-side confound instead of only exposing it as a raw imbalance count.
- Make `StrategyScore.rate`'s denominator unambiguous — one field, one meaning, no unused parallel candidate.
- Write down, as spec text, the two limitations this capability is *not* going to solve right now (query-class script coverage; negative-case collection), so a future reader does not mistake silence for an oversight.

**Non-Goals:**

- Assembling the ground-truth `(query, expected turn)` dataset. See proposal.md's Non-Goals for the full rationale. Consequence for this design: the two-stage metric and three-track reporting are delivered as **pure, ground-truth-agnostic scoring functions**, proven correct against synthetic fixtures (the same pattern already used throughout `Tests/LTMEvalTests/` and `Tests/LTMIndexTests/IncrementalEquivalenceTests.swift` — construct a small synthetic corpus/event set, assert the scoring function's output on it). Wiring these functions to a real ground-truth dataset and running them over live data is deferred to whoever builds that dataset.
- Expanding the query-class label set beyond `cjk-2char`/`cjk-3char`/`cjk-4plus`/`latin-alnum`/`mixed`.
- Collecting negative cases (queries known to have no retrievable answer).

## Decisions

### Recall@20 → nDCG@10 is a two-stage function, not two independent metrics

The function signature is `score(retrieved: [Anchor], expected: Anchor, k: Int = 20) -> RecallNDCGOutcome`, where:

```swift
enum RecallNDCGOutcome: Sendable, Equatable {
    case notRecalled                  // expected anchor absent from retrieved[0..<20]
    case recalled(ndcgAt10: Double)   // expected anchor present; nDCG@10 computed treating it as the sole relevant item
}
```

**Why an enum, not two optional Doubles**: a `(recall: Bool, ndcg: Double?)` pair lets the two fields disagree (`recall == false` with a non-nil `ndcg`) — a state with no meaning that a consumer could still read and misinterpret. The enum makes "not recalled → no ranking-quality number exists" a compile-time fact, following this repo's established pattern of encoding "this field has no meaning in this state" as a case rather than a nullable pair (e.g. `Dereference`, `AnchorStatistics.malformation`).

**Alternative considered and rejected**: computing nDCG@10 unconditionally (treating a non-recalled item as contributing 0 to the DCG sum) and reporting recall as a separate boolean. Rejected because it lets an aggregate nDCG number silently absorb recall failures as "just a low score," which is exactly the severity-ordering issue #16 asked to fix — a missing anchor and a rank-15 anchor would both just look like "somewhat low nDCG," collapsing the distinction the two-stage design exists to preserve.

### Three-track reporting is a report shape, not three separate comparison runs

`RecallNDCGOutcome` is computed three times per (query, expected) pair — once per channel's retrieved list (lexical-only, vector-only, fused) — using the *same* scoring function from the decision above. The three results are carried together:

```swift
struct ChannelBreakdown: Sendable, Equatable {
    let lexical: RecallNDCGOutcome
    let vector: RecallNDCGOutcome
    let fused: RecallNDCGOutcome
}
```

**Why the same function three times, not a parallel implementation per channel**: the failure mode this guards against is a per-channel special case silently drifting from the fused case's semantics (this repo has hit exactly that shape of bug — three near-identical switch statements each carrying their own partial fix — in the `RankingReason` history described in `Sources/LTMQuery/Strategies/HumanLikeStrategy.swift`). One function, three call sites, is the same discipline applied here.

**Alternative considered and rejected**: reporting only a fused/lexical delta or fused/vector delta rather than three independent outcomes. Rejected because a delta can be zero for two different reasons (both channels equally good, or both channels equally bad) and #16's stated purpose — detecting single-channel degradation — needs the three absolute outcomes to tell those apart.

### Starting-side correction uses a fixed-effect model, not stratified win rates

Concrete worked example (confirmed with the user during spectra-discuss): 100 presentations, 60 started with A, 40 started with B. The correction fits `outcome ~ policy + startingSide` over all 100 observations and reports one side-corrected preference estimate, rather than computing "A's win rate when A started" and "A's win rate when B started" as two separate, smaller-sample numbers.

**Why a fixed effect over stratification**: with realistic per-class sample sizes (a single query class may have well under 100 observations), splitting into two strata makes each stratum's estimate unreliable on its own, while a fixed effect uses every observation and reports one corrected number plus its uncertainty.

**Alternative considered and rejected**: keep only the existing raw imbalance count (`StartingSideCounts`, `isSeverelyImbalanced`) and stop there. Rejected in the discuss session because "showing that an imbalance exists" and "correcting for it" are different capabilities, and #16 explicitly asked for the second.

### `StrategyScore.presented` is the sole denominator; `PresentationRecord.presentedCount(for:)` is removed

Current state (verified against `Sources/LTMEval/ComparisonReport.swift:8-21` and `Sources/LTMEval/PresentationRecord.swift:129`): `StrategyScore.presented` (driven by counted `.shown` events) is already the field `ComparisonScorer` uses for `rate`'s denominator. `PresentationRecord.presentedCount(for:)` is a second, unused method computing "how many positions this side contributed to the record" — a different quantity (record-structural) from "how many times this side was actually shown" (event-observed).

**Why remove rather than keep both public**: two public methods answering superficially similar questions ("how many things were presented") with different actual semantics is exactly the kind of ambiguity #16 flagged. Since only one of the two is wired to any consumer, and the wired one is the semantically correct one (a comparison's exposure unit is "what the user was actually shown," not "what the record structurally allocated"), the unused one is removed rather than left as a trap for a future caller.

**Alternative considered and rejected**: keep `presentedCount(for:)` as a diagnostic-only method to detect divergence between "record says N positions" and "N `.shown` events observed." Considered because such a divergence *could* be a useful signal (e.g. a caller under-reporting `.shown` events). Rejected for this change because no consumer currently needs it and speculative diagnostic surface is out of scope; if a real need for this comparison emerges, it can be re-added with a concrete consumer in a follow-up.

### Query-class coverage and negative-case exclusion are spec text, not code

Both are documented as new prose in `openspec/specs/strategy-comparison/spec.md` (see specs artifact). No code changes accompany these two decisions; `QueryClassifier`'s five-value closed set (`Sources/LTMEval/QueryClass.swift`) is unchanged.

## Implementation Contract

**Behavior**:
- `RecallNDCGOutcome` and `ChannelBreakdown` are new pure value types in `Sources/LTMEval/`, computed by a new function (name: `scoreRecallAndRanking(retrieved:expected:k:)` or equivalent — exact name decided during implementation) that takes a ranked list of anchors and one expected anchor and returns `RecallNDCGOutcome`. This function has no dependency on `EventStore`, `PresentationRecord`, or any live-comparison type — it is a standalone scoring primitive that could be called from a future ground-truth harness without pulling in the interleaving machinery.
- Starting-side correction is a new function taking the existing `[PresentationRecord]` + scored events (the same inputs `ComparisonReport.build(...)` already consumes) and returning a corrected preference estimate alongside the existing raw `StartingSideCounts`. It does not replace the existing `ComparisonReport.classRows`/`aggregate` output — it adds to it.
- `StrategyScore.rate`'s existing behavior (nil when `presented == 0`, else `net/presented`) does not change. `PresentationRecord.presentedCount(for:)` is deleted; any test currently calling it is updated or removed.

**Interface / data shape**:
- `RecallNDCGOutcome` (enum, two cases: `notRecalled`, `recalled(ndcgAt10: Double)`) — new type in `Sources/LTMEval/`.
- `ChannelBreakdown` (struct: `lexical`, `vector`, `fused`, each a `RecallNDCGOutcome`) — new type in `Sources/LTMEval/`.
- The starting-side correction's output type and exact statistical form (e.g. an odds ratio, a corrected rate, a confidence interval) is decided during implementation — the requirement is that it derive from a model fit across all observations rather than from stratified subsets, per the Decision above.

**Failure modes**:
- `scoreRecallAndRanking` on an empty `retrieved` list: `.notRecalled` (the expected anchor cannot be present in an empty list — no special-cased error path).
- Starting-side correction with an empty or single-side-only observation set (e.g. all 100 presentations started with A): the function must not crash or silently report a spurious "correction." It returns `nil` (no correction computable) rather than a number derived from a degenerate model fit — mirroring this repo's established pattern of returning `nil` rather than a value with no real meaning (`StrategyScore.rate`, `ComparisonReport.aggregate`).

**Acceptance criteria**:
- `Tests/LTMEvalTests/ComparisonReportTests.swift` (or a new `Tests/LTMEvalTests/RecallNDCGTests.swift`, decided during implementation) has synthetic-fixture tests covering: a recalled-and-well-ranked case, a recalled-but-poorly-ranked case, a not-recalled case, and the three-track breakdown disagreeing across channels (e.g. lexical `.notRecalled`, vector `.recalled`, fused `.recalled`).
- A starting-side-correction test constructs a synthetic imbalanced observation set (mirroring the 60/40 worked example above) and asserts the corrected estimate differs from the naive uncorrected rate in the expected direction.
- `PresentationRecord.presentedCount(for:)` no longer exists in the compiled module; `swift build` fails if any caller still references it (this is the acceptance check for the removal, not a runtime test).
- `openspec/specs/strategy-comparison/spec.md` contains new Requirements documenting the query-class script-coverage limitation and the negative-case exclusion, each with at least one Scenario.

**Scope boundaries**: In scope — the four new/changed pieces above (two-stage metric function, three-track breakdown type, starting-side correction function, denominator cleanup) plus the two spec-only documentation additions. Out of scope — building or wiring a ground-truth dataset consumer; changing `ComparisonReport.classRows`/`aggregate`'s existing shape or the live interleaving mechanism itself; expanding `QueryClass`'s value domain.

## Risks / Trade-offs

- [The two-stage/three-track scoring functions ship with no real caller until a ground-truth dataset exists, so they are effectively untested against real data] → Mitigation: synthetic-fixture tests are the acceptance bar for this change (consistent with how `IncrementalEquivalenceTests.swift` and `RetrievalEngineTests.swift` validate structural correctness without live corpus dependency); real-data validation is explicitly deferred to whoever builds the dataset, not silently assumed to have happened here.
- [A fixed-effect model for starting-side correction is a larger implementation than a stratified count, and this repo has no existing statistical-modeling dependency] → Mitigation: the exact model form is left to implementation (Open Questions below); a from-scratch closed-form fixed-effect estimator for a binary outcome with one binary covariate is a small, well-understood calculation and does not require a new external dependency (this repo's zero-third-party-dependency policy for the CLI — see `Package.swift` comment on `LTMQuery` — extends by convention to `LTMEval`).
- [Removing `presentedCount(for:)` is a breaking change to `PresentationRecord`'s public API] → Mitigation: grep-confirmed zero non-test callers before this design was written; the only test callers are updated in the same change.

## Open Questions

- Exact statistical form of the starting-side fixed-effect correction (closed-form logistic-style adjustment vs. a simpler mean-difference correction) — left to implementation; the Decision above constrains it to "derived from all observations, not stratified subsets," not the specific formula.
- Whether the two-stage/three-track types belong in `ComparisonReport.swift` directly or a new file (e.g. `RecallNDCG.swift`) under `Sources/LTMEval/` — left to implementation, decided by file-size/cohesion judgment at that time (this repo's coding-style guidance prefers many small files over few large ones).
