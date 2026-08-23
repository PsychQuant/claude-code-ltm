All tasks implement the `memory-strategy` requirement **"A strategy's additional acting condition is declared, and the seam enforces it"**. Each task names the design decision it carries out.

## 1. Declaration point

- [x] 1.1 Implements design decision **"A closed enum, not a boolean"**. Add a public closed enum `PlacementConstraint` to the re-ranking seam module with a single case denoting "may reorder only among candidates sharing a relevance band and an exactly equal base score". Behavior: the case is the seam's own vocabulary — a strategy names it, never defines it. Verify: the enum compiles as `public`, `Sendable`, `Hashable`, and has exactly one case.
- [x] 1.2 Implements design decision **"The declaration carries no data"**. Add a get-only `placementConstraints: Set<PlacementConstraint>` requirement to the `MemoryStrategy` protocol, documented as the second half of the strategy axis alongside `consumedSignals` — "under what condition it acts", the half the protocol previously left undeclared. Verify: the protocol declares the member and its documentation states why the declaration carries no data (the seam derives tie runs from band and base score, both of which it already holds).
- [x] 1.3 Implements design decision **"Default is the empty set"**. Add a protocol extension supplying the empty set as the default. Document the direction: defaulting to *constrained* would reject `human-like`'s correct output and the failure would look like a strategy bug; defaulting to *unconstrained* makes a forgotten declaration an under-check visible in review against the specification. Verify: `ArchivalStrategy` and `HumanLikeStrategy` compile with no edit and report an empty set.

## 2. Seam enforcement

- [x] 2.1 Satisfies requirement **"A strategy's additional acting condition is declared, and the seam enforces it"** — its clause that the seam enforce declared constraints after the strategy returns, and that a strategy SHALL NOT check its own. In the public re-ranking entry point's post-condition block, enforce each declared constraint after the existing permutation, band, and displacement-bound checks. Behavior: a declared-and-violated tie-run constraint throws the existing crossing-tie-runs violation; a strategy declaring the empty set is not subjected to the check. Verify: the enforcement is in the seam's entry point, not in any strategy, and reads the constraint set from the protocol member.
- [x] 2.2 Confirm the seam's own guard does not gain a second implementation of tie-run derivation — it must call the guard's existing tie-run entry point rather than recompute runs. Verify: exactly one function in the module walks candidates to assign run identifiers.

## 3. Conservative strategy

- [x] 3.1 Implements design decision **"The strategy still computes placements, but stops checking"**. Declare the tie-run case in `ConservativeStrategy.placementConstraints` and remove its own call to the guard's tie-run entry point. Obtain placements from the guard's permutation entry point instead. Behavior: output is byte-identical to before for every input the existing tests cover. Verify: the strategy's re-ranking body contains no call that enforces a placement constraint.
- [x] 3.2 Update the strategy's documentation where it narrates the three prior rounds of "the constrained party supplied the constraint". Keep the history — it explains why the shape matters — and update only the conclusion, which now reads that the tie-run condition is declared and seam-enforced. Verify: the passage still names all three prior defects and does not claim the displacement-bound question is resolved.

## 4. Guard documentation

- [x] 4.1 Update the guard's tie-run entry point documentation to name its new caller (the seam) instead of the strategy. Verify: the passage stating that the "constrained party supplies the constraint value" hole is *not* closed remains present and unaltered in meaning — it concerns the displacement bound, which this change does not touch.

## 5. Regression locks

- [x] 5.1 Add a test conformer that declares the tie-run constraint and deliberately returns an ordering moving a candidate out of its run, and assert that invoking it through the seam's public entry point throws the crossing-tie-runs violation. The conformer must reach the seam through the ordinary public path, not by calling the guard directly. Verify: the test fails if the conformer is invoked through a path that bypasses the seam.
- [x] 5.2 Prove the lock in 5.1 is load-bearing: remove the seam's constraint enforcement, run the suite, and confirm the test in 5.1 goes red *because the expected violation was not raised* — not because of a compile error or an unrelated assertion. Restore the enforcement afterwards. Record the observed failure in the change's completion notes. Verify: the removal was actually performed and the failure actually observed, not asserted.
- [x] 5.3 Add a test conformer that declares the empty set, returns an ordering crossing a tie-run boundary within one band and within the displacement bound, and assert the seam accepts it. Verify: this test fails if the default is flipped to constrained.
- [x] 5.4 Run the full test suite and confirm every existing strategy test passes unchanged, including the ones pinning that `conservative` never reorders candidates with differing base scores, that it stays within its relevance band, and that it terminates on non-finite base scores when the seam is bypassed.

## 6. Specification

- [x] 6.1 Confirm the delta spec's requirement **"A strategy's additional acting condition is declared, and the seam enforces it"** and its scenarios describe what shipped, including the three-row example table. Verify: the example's third row (empty declaration, crossing ordering, accepted) matches the behavior of the test in 5.3.
- [x] 6.2 Confirm no artifact in this change claims the displacement-bound authority question is resolved. Verify: the member documenting that question is unchanged, and the strategy and guard documentation both still point at it as the source of truth.

## Completion notes

### Task 5.2 — the observed failure

The seam's constraint enforcement was actually removed and the suite actually run. Result:

```
✘ Test aDeclaredTieRunConstraintIsEnforcedBySeamOnAViolatingStrategy() recorded an issue
  at PlacementConstraintTests.swift:78:5:
  Expectation failed: an error was expected but none was thrown
✘ Test run with 72 tests in 0 suites failed after 0.011 seconds with 1 issue.
```

The failure is the expected violation not being raised — not a compile error, not an
unrelated assertion. Exactly one test failed, so the lock is precisely targeted rather than
incidentally coupled to something else. Enforcement was restored and the suite returned to
72 passing.

### Task 1.3 — the default direction was also proven, not just argued

The design argued that defaulting to *constrained* would reject `human-like`'s correct
output and that the failure would look like a strategy bug. That was tested by flipping the
protocol extension's default to `[.withinTieRuns]` and running the suite:

```
✘ humanLikePromotesACitedBandPeer() — Caught error: .movedAcrossTieRuns
✘ aCandidatePromotedBecauseAPeerSankAlsoSaysWhyItMoved() — Caught error: .movedAcrossTieRuns
✘ promotionsHappenWhereverTheyAreNeededNotOnlyAtTheHead() — Caught error: .movedAcrossTieRuns
✘ aLargerBoundActuallyProducesALargerPromotionThroughARealStrategy() — Caught error: .movedAcrossTieRuns
  (and four more, all of the same shape)
```

Every one of those is a strategy behaving correctly and being rejected by its own seam, and
the error name points at the tie-run check rather than at the default that caused it — which
is precisely the "looks like a strategy bug" failure mode the design predicted. The default
was restored.
