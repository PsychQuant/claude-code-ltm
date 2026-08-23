## Summary

Move the authority for a strategy's placement constraints out of the strategy instance and into a closed table the seam consults, and have the seam compose the two sources in one direction only: a strategy may add constraints to itself, never remove the ones its identifier carries.

## Motivation

Two members of the re-ranking protocol are self-reports the seam accepts without checking. One supplies a value (how far a candidate may move); the other supplies applicability (whether the tie-run check runs at all). Both are `{ get }` requirements, so a conforming type can implement either as a computed property. The seam re-reads them on every call and records nothing, so a strategy can present one answer when it suits and another when it does not.

The applicability member was previously described, in six places, as safe — the claim being that a strategy could only select from a vocabulary the seam owns, never weaken a check it had selected. A probe disproved that: the same instance, the same candidate list, the same cross-run reordering; the first call threw, the second was accepted.

What makes this worth fixing rather than annotating is the contrast sitting three lines below it in the same function. That loop takes each result's self-reported displacement and movement and compares them against the positions that actually changed, throwing if they disagree. The seam already knows how to distrust a strategy's account of itself. It just does not do it here.

There is no known wrong output today: all three shipped strategies declare both members as stored properties. This is depth of defence, not a live defect — and the reason it earns an issue rather than a comment is that it falsified a claim already written into the specification.

## Proposed Solution

A closed table in the strategy module maps each known identifier to the constraints that apply to it. The seam consults that table and takes the union with what the instance declares: a strategy may add constraints on itself, and declaring none leaves the table's intact. The looser answer never reaches a check.

Composing in one direction makes cross-call consistency checking unnecessary rather than solving it. A getter that alternates gains nothing it could not have obtained by declaring the empty set outright, and the empty set no longer removes anything. The seam therefore stays a pure function — no per-process state, no synchronisation, no snapshot to keep.

An identifier absent from the table is refused. Falling back to the instance's own declaration would leave exactly the door this change closes, reachable by naming a new strategy. Because in-package tests must construct deliberately misbehaving conformers with identifiers of their own, the table exposes a registration entry point that is not visible outside the package — the same boundary the validated-candidates token already relies on, and it is specified rather than left as an undocumented convenience.

**The displacement bound is not covered, and the reason is the same doctrine that covers the constraints.** The table is keyed by identifier, so it can only govern what the identifier determines. The protocol states that a strategy is defined by which signals it consumes and under what conditions it acts, and **never** by how far it adjusts — and the specification makes that concrete by requiring the bound to be configurable at construction, with a scenario in which a strategy built with a bound of three moves a candidate three positions. Two instances sharing an identifier can therefore hold different bounds, which is precisely what it means for the bound not to be part of the identity. An identity-keyed table has nothing to say about it.

So the issue's framing — that the two members are two instances of one problem — is half right. Both are unvalidated self-reports by the constrained party. Only one of them can be answered by an identity-keyed authority. The other needs an authority of a different shape (configuration, the caller, or a registry of configured instances rather than identifiers), and that remains an open question, exactly as the bound's own documentation has recorded for several versions.

## Non-Goals

- **Snapshot-and-verify.** Recording the first declaration and comparing later ones was the direct answer to cross-call variance. One-directional composition removes the need, and avoids putting process-lifetime state and synchronisation into a seam that is currently a pure function.
- **Accepting and documenting the gap for the constraints.** Naming it as a known limitation alongside the existing token escape hatch would leave two places where the seam takes a strategy's word, and would require restating what "the seam cannot be bypassed" is worth.
- **Answering the bound's authority question.** It stays open. This change states why an identity-keyed table cannot answer it, which is more than was known before, but it does not answer it.
- **Third-party strategies.** The table is closed. Nothing here opens the protocol to conformers outside this package; adding one remains a specification change.
- **Re-deciding what a strategy is.** This change assumes the documented axis — signals plus conditions, never magnitude — and places authority accordingly: the table governs the conditions and is silent on the magnitude. If that sentence is ever revised, the table's scope has to be revisited. The sentence is load-bearing after this change in a way it was not before.
- **Any claim about ranking quality.** Nothing here changes what the shipped strategies output.

## Alternatives Considered

**Leave the table in the service layer and have the seam ask for it.** The registry that maps identifiers to strategy instances already exists, but it lives above the strategy module, and the strategy module deliberately depends on nothing but the core value types. Reaching upward would invert that. Building a second table beside the seam instead would leave two definitions of which strategies exist, drifting apart on the next addition. The registry imports nothing from its current home, so it moves down whole and the layer above re-exports it.

**Have each strategy pass its constraints to the guard itself.** This is what the previous arrangement did for the tie-run check, and the reason it failed: the party being constrained decided whether the constraint ran.

## Impact

- Affected specs: `memory-strategy`
- Affected code:
  - Modified: `Sources/LTMQuery/MemoryStrategy.swift`, `Sources/LTMQuery/Strategies/ConservativeStrategy.swift`, `Sources/LTMQuery/Strategies/HumanLikeStrategy.swift`, `Sources/LTMQuery/Strategies/ArchivalStrategy.swift`, `Sources/LTMService/StrategyRegistry.swift`, `Sources/LTMService/LTMService.swift`, `Tests/LTMQueryTests/PlacementConstraintTests.swift`, `openspec/specs/memory-strategy/spec.md`, `CHANGELOG.md`, `CLAUDE.md`
  - New: `Sources/LTMQuery/StrategyAuthority.swift`
  - Removed: (none)
