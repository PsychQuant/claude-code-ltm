## Why

`strategy-comparison`'s stated purpose is "interleaved evaluation of a pair of strategies **over live usage**". The scoring side of that exists and is tested. The producing side does not: nothing in the service or CLI layer ever constructs a presentation record, and `InterleavingHarness` has no caller outside its own tests. Recording events with the existing opt-in flag writes `shown` events carrying a presentation identifier that no record describes, so every one of them is discarded by the scorer as belonging to an untracked presentation.

The consequence is that `ComparisonReport` has never had an input and cannot acquire one by waiting. The corrected starting-side estimate is structurally always absent. Two other issues are blocked behind this: neither the spreading-activation tier nor the restored tie-breaker tier can have its effect quantified, and the honesty boundary recorded in the project's own instructions — that strategy comparison has no measurement support — cannot move.

The retrieval side has a different and smaller gap. The two-stage recall-then-ranking outcome and the per-channel breakdown are implemented and specified, but nothing calls them, because they need pairs of a query and the turn it should retrieve. That material is cheap: an earlier measurement already built it by extracting a query from a chunk and treating that chunk as the gold answer, generating the queries at measurement time and discarding them immediately. It requires no usage history at all.

These two gaps were conflated in the issue that prompted this change. They are separable, and separating them is what makes the work tractable.

## What Changes

**A comparison mode on the query path.** A new opt-in flag runs two strategies over the same candidate list, interleaves their orderings through the existing harness, records a presentation describing which side contributed each position, and writes that record alongside the events. From then on, ordinary use accumulates the material the comparison scorer was written to consume.

**A known-item retrieval evaluation.** A committed generator samples chunks from a corpus, derives a query from each, and pairs it with the chunk it came from. A harness feeds each pair through the three retrieval channels and scores all three with the existing two-stage function, producing the per-channel breakdown that has so far had no caller. The result lands as a dated record under the measurements directory.

**Specification updates.** The comparison capability gains a requirement that presentations must be produced by the same path that serves queries, and that recording a comparison is opt-in. The CLI capability gains a requirement describing the flag, its interaction with the existing event-recording flag, and what the command prints in comparison mode.

## Non-Goals

- **A strategy-comparison measurement record.** This change delivers the machinery and the retrieval record only. A comparison record requires accumulated real usage, which cannot be manufactured; when the first one becomes possible depends on how much the system is used and is deliberately left unpredicted.
- **Synthetic usage history.** Rejected on the merits — see Alternatives.
- **Lifting the honesty boundary.** After this change, strategy comparison still has no measurement support. What changes is that it moves from "no mechanism" to "mechanism ready, awaiting data". No artifact may state or imply otherwise.
- **Negative cases.** The comparison capability already records that it does not collect them from real usage, because the no-query-text policy makes it structurally impossible. That exclusion stands and the evaluation population inherits it.
- **Making comparison mode the default.** It changes what the user sees; it stays opt-in, like event recording.

## Alternatives Considered

- **Synthesise a usage history and compare strategies offline.** Rejected. An offline comparison must score orderings against an expected ordering, and "better ordering" has no definition in this system — the analogy the project reasons from supplies constraints, not an objective function. A synthesised history would measure which strategy best matches an invented behaviour model. Interleaving avoids the question entirely: it does not ask which ordering is better, it asks which side the user chose, and the choice is the criterion.
- **Export the real event log as a portable dataset.** Rejected. Events are bound to real anchors in a private corpus; the dataset could not leave the machine, and "reproducible" would degrade into "reproducible on one machine". Committing the mechanism rather than the data keeps the measurements directory's convention of shipping a re-runnable script.
- **Build only the retrieval half now.** Viable, and it would produce a record sooner. Rejected because it leaves the actual blocker untouched: the producer is what starts the clock on the data everything else waits for, so deferring it defers every dependent question by the same amount.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `strategy-comparison`: gains the requirement that interleaved presentations are produced on the live query path, and the requirement describing the known-item retrieval evaluation.
- `ltm-cli`: gains the requirement describing the comparison flag and its output.

## Impact

- Affected specs: `strategy-comparison`, `ltm-cli`
- Affected code:
  - New: `Sources/LTMEval/KnownItemHarness.swift`, `scripts/measure-retrieval-quality.swift`, `Tests/LTMEvalTests/KnownItemHarnessTests.swift`, `Tests/LTMServiceTests/ComparisonModeTests.swift`, `docs/measurements/2026-08-23-retrieval-quality.md`
  - Modified: `Sources/LTMService/LTMService.swift`, `Sources/ltm/Commands.swift`, `openspec/specs/strategy-comparison/spec.md`, `openspec/specs/ltm-cli/spec.md`
  - Removed: (none)
