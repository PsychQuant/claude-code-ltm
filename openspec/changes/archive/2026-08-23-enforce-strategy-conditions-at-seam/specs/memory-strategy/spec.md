## ADDED Requirements

### Requirement: A strategy's additional acting condition is declared, and the seam enforces it

A strategy SHALL declare, as part of its public interface, the set of placement constraints that govern where it may move a candidate. That set SHALL be drawn from a closed enumeration owned by the seam; a strategy SHALL NOT define a constraint of its own. The default SHALL be the empty set, so a strategy that declares nothing is subject only to the constraints that apply to every strategy.

The seam SHALL enforce every declared constraint after the strategy returns and before the result reaches the caller, on the same path that already enforces band preservation and the displacement bound. A strategy SHALL NOT be the party that checks its own declared constraints. A violation SHALL fail loudly rather than being clamped, downgraded, or ignored.

The enumeration SHALL contain only cases the seam can evaluate from information it already holds about the candidates. This is what makes the declaration safe: a strategy selects which checks apply to it, and cannot weaken a check it has selected. It contrasts with the displacement bound, whose *value* is supplied by the strategy and which therefore remains subject to the open question recorded on that member — a question this Requirement does not resolve and MUST NOT be read as resolving.

One case ships: reordering confined to a *tie run*, meaning a maximal span of consecutive candidates sharing a relevance band and an exactly equal base score. `conservative` declares it. `archival` and `human-like` declare the empty set, because `human-like` legitimately reorders across tie runs within a band and a universal constraint would reject correct behavior.

This Requirement exists because the previous arrangement was unenforceable in a way no test detected. The tie-run check was performed by `conservative` on itself; substituting a check that verifies only permutation left the entire strategy suite passing, because the test naming the constraint invoked the guard directly and never constructed the strategy. A constraint enforced by the party it constrains is not a constraint, and a regression lock that never reaches the production path does not lock it.

#### Scenario: A declared constraint is enforced on a strategy that violates it

- **GIVEN** a strategy that declares the tie-run constraint and returns an ordering that moves a candidate out of its tie run
- **WHEN** it is invoked through the seam
- **THEN** the invocation fails with the crossing-tie-runs violation, whether or not the strategy performed any check of its own

#### Scenario: A strategy that declares no constraint is not subjected to it

- **GIVEN** a strategy that declares the empty constraint set and returns an ordering that moves a candidate across a tie-run boundary while staying within its relevance band and displacement bound
- **WHEN** it is invoked through the seam
- **THEN** the invocation succeeds

##### Example: The declaration is what gates, not the ordering alone

Candidates in band 1 with base scores `A: 0.5`, `B: 0.5`, `C: 0.3` form two tie runs, `{A, B}` and `{C}`.

| Declared constraints | Returned ordering | Outcome |
|---|---|---|
| tie-run | `[B, A, C]` | accepted — `A` and `B` swap within their run |
| tie-run | `[C, A, B]` | rejected with the crossing-tie-runs violation — `C` leaves its run |
| empty | `[C, A, B]` | accepted — band preserved and displacement within bound |

The third row is the point: the same ordering is accepted or rejected depending on what the strategy declared, which is what makes the declaration load-bearing rather than decorative.

#### Scenario: Removing the seam's enforcement is detectable

- **GIVEN** the enforcement of declared constraints is removed from the seam
- **WHEN** the strategy suite runs
- **THEN** the test covering a declared-and-violated constraint fails, and it fails because the expected violation was not raised

#### Scenario: Shipped strategies are unaffected in output

- **GIVEN** any of the three shipped strategies and any candidate list and projection they already accept
- **WHEN** each is invoked through the seam before and after this change
- **THEN** the returned ordering, displacements, and reasons are identical
