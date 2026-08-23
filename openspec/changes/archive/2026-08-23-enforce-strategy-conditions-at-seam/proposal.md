## Summary

Move enforcement of a strategy's *additional acting condition* from the strategy itself onto the seam, by giving `MemoryStrategy` a declaration point for it — closing the last case where the constrained party performs its own check.

## Motivation

`MemoryStrategy`'s own documentation, and `memory-strategy` spec's "A strategy is defined by the signals it consumes and the condition under which it acts" Requirement, both define the strategy axis as two halves: **which signals it consumes**, and **under what condition it acts**.

The first half has a protocol member (`consumedSignals`). The second half has none. So `conservative`'s defining condition — that it may only reorder within a run of candidates sharing a relevance band and an exactly equal base score — exists only inside its own `rerankChecked` body, and the only place that can enforce it is the strategy itself.

That is the same defect class the seam already closed for two other constraints. Band preservation and the displacement bound are both enforced by `MemoryStrategy.rerank`'s post-condition block calling `RankingGuard.check`. The tie-run condition has neither a normative Requirement nor a seam enforcement point.

It is not hypothetical. Replacing the `RankingGuard.checkTieRunsOnly` call inside `ConservativeStrategy` with `RankingGuard.verifyPermutation` leaves the whole `LTMQuery` suite passing — 67 of 67 — because the test that names the constraint never invokes the strategy at all; it hands a manually built crossing permutation straight to the guard. The one line that enforces the tier's defining property is deletable, and nothing notices.

A test alone cannot fix this. A strategy does not violate its own condition, so there is no way to drive a violation through the real implementation. The enforcement has to move to the party that is not the one being constrained.

## Proposed Solution

Give `MemoryStrategy` a second declaration member alongside `consumedSignals`:

- `placementConstraints: Set<PlacementConstraint>`, where `PlacementConstraint` is a closed enum whose only case for now expresses "may reorder only within a run of candidates sharing band and base score".
- A protocol extension supplies the empty set as the default, so `archival` and `human-like` need no change and keep their current freedom to reorder anywhere within a band.
- `MemoryStrategy.rerank` enforces each declared constraint in its post-condition block, next to the existing band and displacement-bound checks.
- `ConservativeStrategy` declares the constraint and drops its own guard call, obtaining placements from `RankingGuard.verifyPermutation` instead.

The declaration carries no data. `RankingGuard` derives tie runs itself from each candidate's band and base score — values the seam already holds — so a strategy can only *select* a constraint, never define one. That is what separates this from the displacement bound, where the strategy supplies the value and the hole therefore stays open.

## Non-Goals

- **Deciding who has the authority to set the displacement bound.** The bound's value is still supplied by the strategy. That is a separate, genuinely open design question, and `MemoryStrategy.displacementBound`'s documentation is its source of truth. This change does not resolve it and MUST NOT edit that documentation to claim otherwise.
- **Adding further constraint cases.** The enum ships with exactly the one case that has a caller. Adding a case is a deliberate specification change with a seam-side implementation, not an anticipatory placeholder.
- **Changing what any strategy does.** Ordering output is identical before and after; only the party performing the check changes.

## Alternatives Considered

- **A boolean member** (`reordersOnlyWithinTieRuns`). Rejected: a second constraint would need a second protocol member, so the shape is an enumeration spread across the protocol surface rather than a single closed one.
- **A closure or grouping function supplied by the strategy** (`equivalenceGroups(for:)`). Rejected as the central trap: the constrained party would define the constraint the seam then checks against, reproducing the displacement bound's shape exactly.
- **Adding a test that drives the existing self-check.** Rejected: a strategy cannot be made to violate its own condition through its real implementation, so no such test can exist without a deliberately misbehaving conformer — and once such a conformer exists, the check belongs at the seam it must pass through.

## Impact

- Affected specs: `memory-strategy`
- Affected code:
  - Modified: `Sources/LTMQuery/MemoryStrategy.swift`, `Sources/LTMQuery/Strategies/ConservativeStrategy.swift`, `Sources/LTMQuery/RankingGuard.swift`, `Tests/LTMQueryTests/ConservativeStrategyTests.swift`
  - New: (none)
  - Removed: (none)
