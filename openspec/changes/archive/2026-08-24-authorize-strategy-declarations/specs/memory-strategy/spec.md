## ADDED Requirements

### Requirement: An authority table, not the strategy, decides which constraints govern it

The seam SHALL resolve, from a closed table keyed by strategy identifier, the placement constraints that govern a strategy. That table SHALL be the authority. A strategy's own declaration SHALL be treated as an addition to it, never as a substitute for it.

The effective constraint set SHALL be the union of the authority's set and the strategy's, and every check SHALL read that union. A strategy may add constraints on itself; declaring none leaves the authority's intact.

**Union composition is what makes cross-call variance stop mattering, and it is why the seam needs no memory.** A declaration read afresh on each call may differ between calls; the union already contains the authority's constraints, so the looser answer never reaches a check. The guarantee therefore holds per invocation, from the composition's shape, without reference to any other invocation. An implementation SHALL NOT record declarations across calls to obtain this property, and the seam SHALL remain a pure function of its arguments.

**The table governs the constraints and SHALL NOT govern the displacement bound.** The table is keyed by identifier, so it can only carry what the identifier determines. This specification distinguishes strategies by which signals they consume and under what conditions they act, and never by magnitude — and it requires the bound to be configurable at construction, so two instances sharing an identifier may hold different bounds. A per-identifier ceiling would either contradict that requirement or make the construction parameter inert. Who decides the bound therefore remains open, and this Requirement MUST NOT be read as closing it; what is now established is that an identity-keyed authority is the wrong shape to close it with.

A strategy whose identifier has no entry in the table SHALL be refused before any reordering occurs, with a named failure. Falling back to the strategy's own declaration SHALL NOT occur: that fallback is reachable by naming a new strategy, which is the cheapest thing to do accidentally.

The table SHALL admit registration from within the package that defines it, and SHALL NOT expose that entry point outside it. This exists because the checks this seam performs are locked by tests that construct deliberately misbehaving conformers, and such a conformer must carry an identifier that is not any shipped strategy's. Without a registration point those tests are unwritable; with one visible outside the package, the closed table would not be closed. This is the same boundary the validated-candidates token relies on, and it is recorded here for the same reason that one is recorded — an unstated trust boundary is indistinguishable from an oversight.

The table SHALL be the single declaration of which strategies exist. An implementation SHALL NOT maintain a second enumeration of strategy identifiers alongside it, because the next strategy is added to whichever one its author is looking at and the two then disagree silently.

#### Scenario: A declaration that varies between calls is composed away

- **GIVEN** a strategy whose constraint declaration returns its authority's set on one read and the empty set on the next
- **WHEN** it is invoked repeatedly through the seam with an ordering that violates the authority's constraint
- **THEN** every invocation fails with that constraint's violation

#### Scenario: A strategy may hold itself to more than its authority requires

- **GIVEN** a strategy whose authority declares no constraints and which declares the tie-run constraint
- **WHEN** it returns an ordering that leaves a tie run
- **THEN** the invocation fails with the crossing-tie-runs violation

#### Scenario: An unknown identifier is refused rather than trusted

- **GIVEN** a strategy whose identifier has no entry in the authority table
- **WHEN** it is invoked through the seam
- **THEN** the invocation fails with a named failure and no reordering is performed

#### Scenario: The shipped strategies are unaffected

- **WHEN** any of the three shipped strategies is invoked through the seam
- **THEN** it returns the ordering it returned before the authority table existed, because each already declares what its authority entry says

#### Scenario: The displacement bound still governs movement exactly as before

- **GIVEN** a strategy constructed with a bound of three, registered with no constraints
- **WHEN** a heavily reinforced candidate is reordered within its band
- **THEN** it moves by up to three positions, unaffected by the presence of the authority table

##### Example: Composition against a strategy that reports loosely

Candidates in band 1 with base scores `A: 0.5`, `B: 0.5`, `C: 0.3` form two tie runs, `{A, B}` and `{C}`. The authority for `conservative` is the tie-run constraint.

| Instance declares | Effective constraints | Returned ordering | Outcome |
|---|---|---|---|
| `{}` | tie-run (union) | `[C, A, B]` | rejected — crossing tie runs |
| `{}` | tie-run (union) | `[B, A, C]` | accepted — swap within the run |
| tie-run | tie-run | `[B, A, C]` | accepted — identical to today |

The first row is the point: what the instance declares does not reach the check, so the ordering is judged by the authority either way.

## MODIFIED Requirements

### Requirement: A strategy's additional acting condition is declared, and the seam enforces it

A strategy SHALL declare, as part of its public interface, a set of placement constraints it holds itself to **in addition to** those its authority imposes. That set SHALL be drawn from a closed enumeration owned by the seam; a strategy SHALL NOT define a constraint of its own. The default SHALL be the empty set, which leaves the strategy subject to its authority's constraints and to those that apply to every strategy.

The seam SHALL enforce every constraint in the composed set — the union of the authority's and the strategy's — after the strategy returns and before the result reaches the caller, on the same path that already enforces band preservation and the displacement bound. A strategy SHALL NOT be the party that checks its own constraints. A violation SHALL fail loudly rather than being clamped, downgraded, or ignored.

The enumeration SHALL contain only cases the seam can evaluate from information it already holds about the candidates. A strategy therefore cannot *define* what a constraint means: the seam owns the derivation, and no value supplied by the strategy enters it.

**A strategy cannot be checked less strictly than its authority requires, and the reason is the composition, not the strategy's good behaviour.** The declaration is still read afresh on every call and is still neither recorded nor validated — a conformer implementing it as a computed property can still return different sets on different reads. What changed is that the read no longer determines what applies: the union with the authority's set does.

This wording is narrower than an earlier draft's, which claimed a strategy "cannot weaken a check it has selected". That claim was false, and was disproved by execution: a conformer returning the tie-run constraint once and the empty set thereafter had the same run-crossing ordering rejected on its first invocation and accepted on its second, from the same instance. The claim was withdrawn, and this Requirement records both the withdrawal and what closed the gap, because a reader who finds only the repaired claim cannot tell whether it was ever tested.

**The relationship to the displacement bound is now understood, but only one of the two is settled.** An interim draft described them as differing in surface but not in kind — both unvalidated per-call self-reports by the constrained party — and stated that neither the bound's authority question nor this residual gap was resolved. That description was accurate. What is now known is why they cannot be closed the same way: constraints are part of the axis that defines a strategy, so an identity-keyed authority carries them; magnitude is explicitly not part of that axis, and this specification requires the bound to be configurable at construction, so no table keyed by identifier can carry it. This Requirement closes the constraint half and leaves the bound's authority question open, in the same state its own documentation has recorded for several versions.

One case ships: reordering confined to a *tie run*, meaning a maximal span of consecutive candidates sharing a relevance band and an exactly equal base score. The authority for `conservative` imposes it. The authorities for `archival` and `human-like` impose nothing, because `human-like` legitimately reorders across tie runs within a band and a universal constraint would reject correct behavior.

This Requirement exists because the previous arrangement was unenforceable in a way no test detected. The tie-run check was performed by `conservative` on itself; substituting a check that verifies only permutation left the entire strategy suite passing, because the test naming the constraint invoked the guard directly and never constructed the strategy. A constraint enforced by the party it constrains is not a constraint, and a regression lock that never reaches the production path does not lock it.

#### Scenario: A declared constraint is enforced on a strategy that violates it

- **GIVEN** a strategy whose composed constraints include the tie-run constraint and which returns an ordering that moves a candidate out of its tie run
- **WHEN** it is invoked through the seam
- **THEN** the invocation fails with the crossing-tie-runs violation, whether or not the strategy performed any check of its own

#### Scenario: A strategy whose composed set is empty is not subjected to the constraint

- **GIVEN** a strategy whose authority imposes no constraints and which declares none, returning an ordering that moves a candidate across a tie-run boundary while staying within its relevance band and displacement bound
- **WHEN** it is invoked through the seam
- **THEN** the invocation succeeds

##### Example: The composed set is what gates, not the instance's declaration alone

Candidates in band 1 with base scores `A: 0.5`, `B: 0.5`, `C: 0.3` form two tie runs, `{A, B}` and `{C}`.

| Authority imposes | Instance declares | Composed | Returned ordering | Outcome |
|---|---|---|---|---|
| tie-run | tie-run | tie-run | `[B, A, C]` | accepted — `A` and `B` swap within their run |
| tie-run | tie-run | tie-run | `[C, A, B]` | rejected with the crossing-tie-runs violation |
| tie-run | empty | tie-run | `[C, A, B]` | rejected — the instance's empty set does not remove the authority's |
| empty | empty | empty | `[C, A, B]` | accepted — band preserved and displacement within bound |

The third row is what this change adds: an earlier arrangement accepted that ordering, because the instance's declaration was the whole story.

#### Scenario: Removing the seam's enforcement is detectable

- **GIVEN** the enforcement of composed constraints is removed from the seam
- **WHEN** the strategy suite runs
- **THEN** the test covering a violated constraint fails, and it fails because the expected violation was not raised
