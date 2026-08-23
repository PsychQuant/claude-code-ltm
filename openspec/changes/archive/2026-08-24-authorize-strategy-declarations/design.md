## Context

The re-ranking seam runs three post-conditions over what a strategy returns: the reordering is a permutation of the input, bands are preserved, and no candidate moved further than allowed. It then walks the results and checks each one's self-reported displacement and movement against the positions that actually changed, throwing if they disagree.

Two inputs to those checks come from the strategy itself. The bound is read twice — once to reject a negative value, once as the argument to the guard. The constraint set is read once, driving a loop that runs the tie-run check for each constraint declared. Both are `{ get }` protocol requirements. Neither is recorded, and neither is compared against anything.

A probe established that the constraint set can differ between calls on one instance: first call threw, second was accepted, with everything else held fixed. The bound's two reads within a single call both feed the permissive direction — one clears a floor, the other supplies a ceiling — so alternating there yields nothing that declaring the larger value outright would not. The reachable hole for both members is across calls, not within one.

Nothing is wrong in the shipped product. All three strategies declare both members as stored constants. What the probe falsified is a sentence, repeated in six artifacts, asserting that a strategy could select from the seam's vocabulary but never weaken a selection.

## Goals / Non-Goals

**Goals:**

- Make it impossible for a strategy to be subjected to fewer placement constraints than its identifier carries, whatever its declaration returns and however often it is read.
- Keep the seam a pure function of its arguments.
- Leave one definition of which strategies exist.
- Leave the three shipped strategies' output unchanged.

**Non-Goals:**

- Recording declarations and comparing them across calls.
- Opening the protocol to conformers outside this package.
- Revisiting what defines a strategy. This change reads the existing answer and places authority to match; it does not re-open it.
- Any claim about ranking quality.

## Decisions

### Compose in one direction, so cross-call variance stops mattering

The seam holds an authority for each strategy identifier and combines it with the instance's declaration before running the constraint check. The composition takes the union, which moves one way only: toward the stricter of the two.

A getter that alternates then buys nothing. Whichever answer it gives on any call, the union already contains the authority's constraints. The looser answer never reaches a check.

This is why the seam needs no memory of what it read last time. The property "a strategy cannot be checked less strictly than the authority allows" holds per call, from the composition's shape, without reference to any other call.

**Alternative rejected — snapshot the first declaration and compare subsequent ones.** It addresses the observed behaviour directly, and it is what the issue proposed first. The cost is that the seam stops being a pure function: it needs a table keyed by something that survives across calls, plus synchronisation, in a type that is `Sendable` and whose conformers are value types with no identity. Keying by identifier would work, but only by introducing exactly the process-lifetime state this alternative exists to justify. Composition gets the same guarantee with none of it.

### The table governs the constraints and is silent on the bound, because it is keyed by identifier

The protocol states that a strategy is distinguished by which signals it consumes and under what conditions it acts, and never by magnitude. Constraints are the conditions half, so they are determined by the identifier and an identifier-keyed table can carry them. A strategy may still add to its own set — holding itself to a narrower rule than its identifier requires is coherent, and the union preserves the table's floor regardless.

The bound is the excluded half, and the specification makes that concrete: the bound is required to be configurable at construction, with a scenario in which a strategy built with a bound of three moves a candidate three positions. Two instances sharing an identifier can therefore carry different bounds. That is what it means for the magnitude not to be part of the identity — and it is exactly why a table keyed by identifier has nothing to say about it. Giving the table a ceiling for each identifier would either contradict that requirement or make the construction parameter inert.

**This narrows what the issue claimed.** It described the two members as two instances of one problem, both being unvalidated self-reports by the constrained party. That much is true and unchanged. What is now established is that only one of them is answerable by an identity-keyed authority. The other needs an authority of a different shape — configuration, the caller, or a registry of configured instances rather than identifiers — and it stays open, as the bound's own documentation has recorded for several versions.

**Alternative rejected — give the table a generous ceiling anyway, say a hundred positions.** It would catch a strategy declaring an absurd bound while leaving realistic configuration intact, so "both members are covered" would remain true in a weak sense. The number would have no basis: this project does not pick parameters without a measurement supporting them, and there is none. A limit chosen to be beyond anything anyone would configure is a limit that catches nothing, dressed as a guarantee.

### The authority table lives beside the seam, and the existing registry moves down to join it

Two tables of which strategies exist would drift, and drift silently: the next strategy gets added to whichever one the author is looking at.

The registry that maps identifiers to instances imports only the foundation and the core value types — nothing from the layer it currently sits in. It moves whole into the strategy module, and the layer above re-exports what its callers use. One file then answers both "which strategies exist" and "what is each authorised to do".

**Alternative rejected — leave the registry where it is and have the seam ask upward.** The strategy module depends on the core value types and nothing else, deliberately: strategies cannot see the event store. Reaching up would invert that dependency for a lookup table.

### The table is registrable from inside the package, so tests can construct misbehaving conformers

The checks in this seam exist because strategies can misbehave, and the tests that lock them work by constructing conformers that misbehave deliberately — returning a non-permutation, lying about displacement, crossing a tie run. Those conformers need identifiers of their own precisely because they must not be any shipped strategy.

A closed table refuses them, which would leave the seam's own violation tests unwritable. The table therefore exposes a registration entry point visible inside the package and nowhere else, and the specification says so rather than leaving it as an undocumented convenience.

This is the boundary the validated-candidates token already relies on, and that boundary is already specified as what it is — a capability, not a proof. Recording this one the same way keeps the count of "places the module trusts its own tests" at one kind rather than adding an unrecorded second.

**Alternative rejected — have the test conformers borrow shipped identifiers.** No new interface, but every shipped identifier already carries constraints, so a test needing an unconstrained conformer could not be written at all — and that is most of them.

### An unknown identifier is refused

A strategy whose identifier is not in the table is rejected rather than falling back to its own declaration. The fallback would reopen the hole for anyone naming a new strategy, which is the cheapest thing to do accidentally.

Refusal is safe because the set is closed and adding to it is a specification change. The three shipped strategies are all in the table.

## Implementation Contract

**Behavior.**

Before any post-condition runs, the seam resolves the authority for the strategy's identifier. If none exists, it throws and no re-ranking occurs. Otherwise the effective constraints are the union of the authority's and the instance's, and the constraint check reads that union. The displacement bound is untouched: it is read from the instance as before.

The three shipped strategies produce byte-identical output: each already declares what its authority entry says, so the union returns the existing set.

**Interface and data shape.**

- A closed lookup from identifier to the constraint set that identifier is held to lives in the strategy module, alongside the registry that maps identifiers to instances. Both are answered by one file. A registration entry point on that lookup is visible inside the package only.
- The protocol keeps the constraint member. It no longer means "what applies to me" but "what I additionally hold myself to", and its documentation says so in place rather than in a note elsewhere. The bound member is unchanged.
- The seam gains one failure for an identifier with no authority entry, alongside the existing violations.
- The layer above re-exports the registry so its callers are unaffected.

**Failure modes.**

- Unknown identifier: named failure before re-ranking. Not a fallback, not a warning.
- Instance declares fewer constraints than its authority: the authority's still apply. Not an error — the composition absorbs it, which is the point.
- Instance declares a larger bound: unchanged behaviour. The bound is outside this change; the existing rejection of a negative bound stays exactly as it was.
- A strategy that genuinely violates the composed constraints or its own bound fails exactly as before, with the same violations.

**Acceptance criteria.**

1. A conformer whose constraint getter alternates between the authority's set and the empty set is checked against the authority's set on every call. Asserted by calling the seam repeatedly on one instance with a reordering that violates the constraint, and requiring every call to throw. The existing test conformer declares stored properties and cannot exhibit this; a new one must.
2. A conformer registered with no constraints is not subjected to any, and the displacement bound it declares at construction still governs its movement exactly as before this change. Asserted against the existing bound tests, unedited.
3. A conformer declaring constraints its authority does not require is held to both. The union is not merely the authority's set.
4. A strategy whose identifier has no authority entry fails with the named failure, before any re-ranking, and produces no results.
5. The three shipped strategies return output identical to before this change, for the same inputs. Asserted against the existing strategy tests, not freshly written expectations.
6. Exactly one table names which strategies exist. Asserted by there being one declaration site — a search for the identifiers turns up the table and the strategies' own `id` properties, nothing else.
7. The whole test suite passes.

**Scope boundaries.**

In scope: the authority table and its in-package registration point, the registry's move, the seam's constraint composition, the constraint member's documentation, the specification's requirement for it, and the tests in the acceptance criteria.

Out of scope: the displacement bound and who decides it — that question stays open, and this change states why an identity-keyed table cannot close it; what the strategies do; the ranking guard's own logic, including how tie runs are cut; the protocol's other members; the token escape hatch tracked separately; opening the strategy set to third parties.

**Documentation constraint.** The claim this change repairs was stated in six artifacts and disproved by a probe. The replacement claim — that a strategy cannot be checked less strictly than its authority allows — is narrower and true, and holds because of the composition's direction, not because a strategy is trusted to behave. Any artifact restating it says why it holds. The project's note recording the earlier retraction stays; this change adds what closed it, and does not edit the record of its having been open.
