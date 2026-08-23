## Context

The re-ranking seam declares that a strategy is defined by two things: which event kinds it consumes, and under what condition it acts. Only the first has a protocol member. The second lives wherever each strategy happens to put it.

Today exactly one strategy has such a condition. `conservative` reorders only within a *tie run* — a maximal span of consecutive candidates that share a relevance band and an exactly equal base score. It enforces that itself, by calling the guard's tie-run entry point from inside its own re-ranking body.

Two other placement constraints are already enforced elsewhere. Band preservation and the displacement bound are checked by the seam's post-condition block, which runs after every strategy returns, on every path through the public re-ranking entry point. Those two are enforced by a party that is not the one being constrained. The tie-run condition is not.

The gap was found by mutation, not by reading: substituting the plain permutation check for the tie-run check inside `conservative` leaves the entire `LTMQuery` suite green. The test whose name claims to cover the constraint never constructs the strategy — it builds a crossing permutation by hand and passes it directly to the guard. So the guard's own logic is covered; its use on the production path is not.

A constraint enforced by the party it constrains is not a constraint. This design moves the enforcement, and gives the second half of the strategy axis the declaration point it has been missing.

## Goals / Non-Goals

**Goals:**

- Give `MemoryStrategy` a declaration point for a strategy's additional acting condition, symmetric in shape with the existing signal-set member.
- Enforce every declared condition from the seam's post-condition block, alongside band and bound.
- Make the enforcement line load-bearing: a deliberately misbehaving conformer must be rejected when it passes through the seam, and the test proving it must go red when the enforcement is removed.
- Turn the specification's "and the condition under which it acts" clause from prose into an enforceable Requirement.

**Non-Goals:**

- Deciding who has the authority to set the displacement bound. Its value is still supplied by the strategy; that hole stays open, and the member documenting it remains the source of truth for why. This change must not edit that documentation to suggest the question has been settled.
- Introducing constraint cases with no caller. The enum ships with the one case that has one.
- Changing any strategy's output. Every ordering produced before this change is produced after it.
- Making the guard's tie-run entry point private or removing it. It remains the implementation of the constraint; only its caller changes.

## Decisions

### The declaration carries no data

The strategy names a constraint; it does not describe one.

The guard derives tie runs itself, by walking the candidate list and starting a new run wherever the band or the base score differs from the previous candidate. Both inputs are already in the seam's hands before any strategy is invoked. So a strategy that declares the tie-run constraint contributes nothing the guard needs — it only selects which of the guard's checks apply to it.

This is the property that distinguishes this change from the displacement bound. There, the strategy supplies the *value* the guard compares against, so a strategy can widen its own limit by declaring a larger number, and the guard cannot tell. Here there is no value to supply. A strategy can decline a constraint, which is a visible choice recorded in its declaration and reviewable in the specification; it cannot weaken one it has declared.

**Alternative rejected — a grouping function supplied by the strategy.** A member returning an equivalence class per candidate position would generalise beyond tie runs. It also reproduces exactly the defect being fixed: the constrained party would define the relation the seam then checks against, and a strategy could return one class covering every position to make the check vacuous. Generality is not worth reintroducing the hole.

### A closed enum, not a boolean

The member is a set of cases from an enum owned by the seam, mirroring the signal-set member's shape.

A boolean would work for one constraint. A second constraint would need a second boolean, and the protocol surface becomes an enumeration spread across members, where each addition is a separate source-breaking change and nothing ties them together as one axis.

An enum is itself an enumeration, and this project's standing rule is that enumerations leak while properties do not. The rule holds; this case is inside its documented narrow exception. What leaks is an enumeration maintained in prose, where nothing forces it to stay complete. This one lives in the seam: every case has an implementation in the guard, the set of cases is closed, and adding one is a specification change that ships with the code enforcing it. The same reasoning admits the query-class label set — a closed, small value domain owned by the system, where callers select rather than define.

**Alternative rejected — no declaration at all, apply the constraint universally.** Simplest, and wrong: `human-like` legitimately reorders across tie runs within a band, so a universal check would reject correct behavior. The declaration carries real information about which strategies opt in, which is why deleting it breaks something.

### Default is the empty set

A protocol extension supplies the empty set, so the two strategies that have no additional condition need no edit and gain no constraint.

The direction matters. Defaulting to *constrained* would silently reject `human-like`'s correct output the first time anyone ran it, and the failure would look like a bug in the strategy rather than in the default. Defaulting to *unconstrained* means a new strategy that forgets to declare its condition is under-checked rather than wrongly rejected — the failure is a missing declaration, visible in review against the specification, rather than a false rejection at runtime.

### The strategy still computes placements, but stops checking

`conservative` currently obtains its per-candidate placements as a by-product of calling the tie-run check. After this change it obtains them from the guard's permutation entry point, which computes displacement without enforcing any placement constraint.

This is deliberate: computing where each candidate moved is not the same act as deciding whether that movement was allowed. The strategy needs the first to build its results; only the seam performs the second.

## Implementation Contract

**Behavior.** Ordering output is unchanged for every strategy. What changes is which code rejects a violation: a conformer that moves a candidate out of its tie run while declaring the tie-run constraint is now rejected when it returns through the seam's public re-ranking entry point, regardless of whether it performed any check of its own.

**Interface and data shape.**

- `MemoryStrategy` gains a get-only member returning a set of `PlacementConstraint`.
- `PlacementConstraint` is a public, closed enum. Its sole case denotes "may reorder only among candidates sharing a relevance band and an exactly equal base score".
- A protocol extension provides the empty set as the default value of the new member.
- The public re-ranking entry point enforces each declared constraint after the existing permutation, band, and displacement-bound checks, and before it returns.
- `ConservativeStrategy` declares a set containing the single case, and no longer calls the guard's tie-run entry point.

**Failure modes.** A declared-and-violated tie-run constraint throws the existing strategy-violation case for crossing tie runs. No new error case is introduced, and no violation is clamped, downgraded, or silently ignored. A strategy declaring the empty set is not subjected to the check at all — that is the intended path for `archival` and `human-like`, not a fallback.

**Acceptance criteria.**

1. A test conformer that deliberately reorders across tie runs while declaring the tie-run constraint throws the crossing-tie-runs violation when invoked through the seam's public re-ranking entry point. The conformer must reach that point through the ordinary public path, not by calling the guard directly.
2. Removing the seam's enforcement of declared constraints makes the test in (1) fail. This must be confirmed by actually removing it and observing the failure, not asserted. The failure must be the crossing-tie-runs expectation going unmet, not an unrelated compile or assertion error.
3. A test conformer declaring the empty set may reorder across tie runs within a band and is accepted, provided it satisfies the band and displacement-bound constraints.
4. The existing `conservative` behavior tests pass unchanged, including the ones pinning that it never reorders candidates whose base scores differ, that it stays within its relevance band, and that it terminates on non-finite base scores when the seam is bypassed.
5. The whole test suite passes.

**Scope boundaries.**

In scope: the new protocol member and its default, the enum, the seam's enforcement of declared constraints, `conservative`'s declaration and the removal of its self-check, the new Requirement and its scenarios in the strategy specification, and the tests in the acceptance criteria.

Out of scope: the displacement bound's value authority; any additional constraint case; any change to the guard's tie-run derivation; any change to strategy output; the documentation on the displacement-bound member, which describes an unresolved question and stays as it is.

**Documentation constraint.** The guard's tie-run entry point carries documentation, recently corrected, stating that the "constrained party supplies the constraint value" hole is *not* closed. That statement remains true after this change, because it concerns the displacement bound, not the tie-run condition. It must not be rewritten to claim the hole is closed.


---

## Post-verify correction (2026-08-23, #32 verify)

The central claim in this document — that a strategy "can only *select* a constraint, never
define **or weaken** one" — was **falsified by execution** during verify. `placementConstraints`
is a `{ get }` requirement, so a conformer may implement it as a computed property; the seam
re-reads it on every call and neither records nor validates it. A conformer whose getter
returns the tie-run constraint on the first read and the empty set thereafter had the *same*
run-crossing ordering rejected on its first invocation and accepted on its second, from the
same instance.

What survives: a strategy cannot **define** what a constraint means — the seam owns the tie-run
derivation and no strategy-supplied value enters it. What does not survive: the claim that a
*declared* constraint cannot be weakened, and with it the claim that this differs **in kind**
from `displacementBound`. Both are unvalidated per-call self-reports; they differ in surface
(a value on a continuum versus a subset of a seam-owned closed vocabulary), not in kind.

The live specification carries the corrected wording. The residual gap is tracked in #34.
