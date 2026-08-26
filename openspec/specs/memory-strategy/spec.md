# memory-strategy Specification

## Purpose

The pluggable re-ranking seam plus its three shipped implementations, including displacement provenance on every returned item.

## Requirements

### Requirement: What this change makes pluggable, and what it does not

The pluggable axis introduced here is **reranking**: a strategy receives an ordered candidate list and a projection, and returns a reordering. The **projection formula is not on that axis**. Decay shape, per-event-kind weights, and the reduction of an event sequence to `reinforcement` and `suppression` are computed by a single shared function before any strategy is selected, and both arms of a comparison receive the same projection object.

A strategy's declared `consumedSignals` therefore describes which signals it takes into account when reordering; it does not constrain how the projection was computed. A strategy that wanted a different decay shape, a different weighting, or the raw per-kind timing could not express it: the aggregation is lossy and happens upstream.

This is a real limitation of the interface shape, not merely of the implementation, and it is recorded here rather than left to be rediscovered. Issue #1 asks that the memory model not be a hard-wired architectural premise; for the *ordering* layer this change delivers that, and for the *projection* layer it does not. Widening the axis — passing strategy-neutral evidence that preserves event kind and timestamp, or letting one policy describe both projection and reranking — is a separate interface change. It was considered and **declined** (#19, closed 2026-08-24), and the reason is not cost: there is no evaluation set, so no claim about which projection is better has any measurement behind it, and both widening options pay an interface cost for a difference nothing can currently adjudicate. The evidence-passing option carries a second unresolved question — a type preserving kind and timestamp is much larger than `AnchorStatistics`, and it would have to be re-established that it does not violate the memory layer's hard constraint of storing only pointers, statistics, and closed-vocabulary labels. Reopening this decision SHALL begin by asking whether an evaluation set exists; without one, substituting a different projection only substitutes a differently-indefensible default.

#### Scenario: Two strategies in one comparison share a projection

- **WHEN** the interleaving harness compares two strategies
- **THEN** both receive the same projection value, computed once by the shared projection function

---
### Requirement: MemoryStrategy is the sole seam between retrieval and memory

The system SHALL expose exactly one abstraction through which usage history influences result ordering. That abstraction SHALL take an ordered candidate list carrying base scores and relevance bands, together with a projection of per-anchor statistics, and SHALL return a reordered result list. Retrieval SHALL NOT read the event store directly, and no strategy SHALL read the corpus directly.

**Those two prohibitions bind implementations, not the compiler, and this specification SHALL NOT be read as claiming otherwise.** A dependency graph controls which types a module can name; it does not control what a module can do. Any module that can open a file can read the event file or the corpus using the standard library alone, against a line-delimited JSON format that is not secret. Two directions have been proposed for making the prohibitions type-level facts — moving the event type's coded representation out of the shared core module, and making the corpus-reading protocol and the anchor dereference method internal — and neither achieves it. The reason is not that the refuting counter-examples avoided those types: one of the two used the corpus-reading protocol and would stop compiling if it were made internal. The reason is that either counter-example can be rewritten against the standard library and pass again, so hiding the type removes a particular piece of code rather than the capability it exercised. The prohibitions are stated because the design intends them, and the paragraphs below name what is enforced instead.

**Ordering correctness is enforced at the seam, by fourteen checks.** Twelve of them run on every invocation. Two are conditional, and each states its own gate where it is listed: item 7 runs only for a strategy that declares it consumes history, and item 11 runs only for a strategy whose effective placement constraints are non-empty. Neither gate is a weakness — each exists because the check would otherwise reject correct behaviour — but a reader who assumes every listed check fires on every call will mis-diagnose the two that did not. "Conditional" here means gated on something the strategy declares about itself, and nothing else: on an empty candidate list most of these checks inspect nothing, but that is ordinary vacuity, it applies to items 5, 6, 9 and 12 alike, and it is not what items 7 and 11 are being distinguished by. They are enumerated here rather than summarised, because a summarising criterion acquires cases the enumeration never agreed to. They are listed in the order the entry point performs them: twelve numbered items, of which item 12 states that it is three checks rather than one, giving fourteen — one name each, which is why the count of names below is the same number. (An earlier revision said twelve checks and ten unconditional. That was off by one in both: it counted item 12 as two checks, from before the history check was added to it. The arithmetic is stated here so the next reader can redo it rather than trust it.)

1. The strategy's reported identifier has an entry in the authority table; a strategy whose identifier has none is refused before any reordering occurs. Violation: `unauthorizedStrategy`.
2. The reported displacement bound is non-negative. Violation: `negativeDisplacementBound`.
3. The reported displacement bound does not exceed the ceiling the authority table grants that identifier. Violation: `unauthorizedDisplacementBound`. The table cannot carry the bound's *value* — the specification requires it to be configurable at construction, so one identifier has many instances with different bounds — but it can carry an upper limit. Composition is therefore by minimum, where placement constraints compose by union: a strategy may tighten its bound and may not loosen it, just as it may add a constraint and may not drop one. Both guarantees come from the direction of the composition rather than from remembering what a strategy declared on some earlier call. **Exceeding the ceiling is refused, not silently clamped**: a caller that asked for one bound and received another has no signal, and would believe its strategy is doing something it is not.
4. A strategy reporting a shipped strategy's identifier is in fact that strategy's type. Violation: `impersonatedShippedStrategy`. The authority resolved by items 1 and 3 is keyed by the identifier, and the identifier is itself a per-call self-report of exactly the shape those items were introduced to constrain; this check is what ties the two together. It applies only to identifiers the registry can construct, so the package-internal test identifiers — which name no shipped strategy and therefore impersonate nothing — pass through it. See the authority-table Requirement for what this establishes and what it leaves open.
5. Every candidate's base score is finite. Violation: `nonFiniteBaseScore`. This is a precondition rather than a formatting preference: a non-finite score makes equality comparison false against itself, and both the equal-segment split and the guard's permutation comparison are built on equality — an earlier revision hung in an infinite loop instead of failing.
6. Relevance bands are non-decreasing across the input order. Violation: `bandsOutOfOrder`. This is what makes the band fence meaningful: the guard verifies bands positionally, and positional comparison is equivalent to "no cross-band movement" only when each band occupies a single contiguous run of the input.
7. Every statistic in the projection is finite and non-negative. Violation: `malformedStatistics`. This is the first conditional check — it runs only when the strategy declares a non-empty set of consumed signals. It validates the whole projection rather than only the anchors in play, so that a malformed statistic surfaces here rather than at an unrelated query later.
8. The returned list is a permutation of the input candidates, compared as a multiset so that a duplicate cannot mask an omission. Violation: `candidateSetChanged`.
9. Each position's relevance band equals the band at that position in the input order. Violation: `crossedRelevanceBand`.
10. No candidate moves further than the displacement bound permits. Violation: `displacementBoundExceeded`.
11. Every placement constraint in the union of the authority table's entry and the strategy's own declaration holds. Violation: `movedAcrossTieRuns` for the tie-run constraint. This is the second conditional check: the union is empty for a strategy the authority table grants no constraints and which declares none, and an empty union means the check performs nothing. Of the three shipped strategies only one carries a tie-run constraint; for the other two this check is structurally inert, each for a stated reason recorded at its authority-table entry.
12. Each result's reported displacement, and separately its reported movement, equal the position change that actually occurred; and a reported history that claims counted signals, or claims the anchor is orphaned, matches what the projection actually supports. Violations: `misreportedDisplacement`, `misreportedMovement` and `misreportedHistory` — three checks rather than one, because a strategy can report an honest displacement beside a fabricated movement, and an honest movement beside a fabricated history.

    The history check is deliberately asymmetric: **a strategy may under-report, and may not fabricate.** A reported history of "none" is always accepted, because declining to consume usage history is a legitimate strategy contract — the archival strategy's contract is to produce the same output for any projection, so reporting none is what it *should* do. A reported history that names signals must name the signals the projection holds, with the same net strength. This asymmetry was established empirically: a first implementation required strict equality and turned sixteen tests red, all of them correctly.

    This is not a third conditional check in the sense of items 7 and 11. Those are gated on what the **strategy** declares about itself. This one is decided by the **result being examined**, which is the same shape as every other check in this list.

Each violation named above is raised by a `throw` reachable from the entry point that performs the checks — not from the checked method, which raises none of them, and which is itself public. That distinction is the whole of the gap named further below, so the enumeration's scope must be stated as the entry point that checks, never as "the public entry point": the protocol has two. Every such `throw` appears in this list. The correspondence is mechanically checkable and the check is stated so a reader need not reconstruct it: the fourteen names above SHALL match, one for one, both the cases of the `StrategyViolation` enumeration and the distinct violations thrown at the `throw StrategyViolation.` sites reachable from the public entry point.

**This list was wrong when it was first written, and the way it was wrong is the reason the check is now stated rather than asserted.** It named eight violations and claimed every reachable `throw` appeared in it. Three did not: the precondition checks now listed as items 3 through 5 run inside the public entry point, before the checked method is reached, and were verified only from the checked method inward. An enumeration nobody can check against the implementation is a summary wearing a list's clothes — but an enumeration that asserts its own completeness without stating how to test it is worse, because the assertion is indistinguishable from a completed check.

A strategy that reads the corpus still cannot return an ordering these checks accept unless that ordering was already a legal reordering — at which point what it read did not change the legality of what it returned.

**The privacy boundary is enforced at the bytes that land, not at the seam.** The memory layer's canonical stores compare each line's decoded-then-re-encoded form against the original bytes, so a value that is not exactly what the schema produces is rejected. That check is indifferent to what any component read: reading corpus text is not the hazard the privacy boundary addresses; corpus text reaching the memory layer's files is, and that is where it is caught.

**The checked method cannot be used to obtain seam-validated candidates outside a seam call.** The checked method is itself a public protocol requirement, and it takes a validated-candidates value whose initialiser is package-internal — so no outside caller can manufacture one. That alone was not enough: a conforming strategy is handed one on every call, so storing that one and invoking the checked method later skipped every check enumerated above. A review demonstrated this rather than arguing it — a strategy returning three results for five candidates raised nothing.

The value now expires when the seam call that created it returns. A stored copy carries no candidates: reading them traps and names the reason. The route therefore leads to a dead token rather than to validated candidates, which was the only thing that made taking it worthwhile.

**What that does not close, stated so nobody has to rediscover it.** A strategy may copy the candidate array during the call — that is data, not authority, and it carries no force of having passed the checks, because that force comes from the results being re-checked on the way back out. A concrete type may also declare its own method of the same name, which a caller holding that concrete type selects statically; and anyone may construct results without touching this seam at all. Neither is a bypass in the sense that matters: they do not skip a check in order to obtain something that claims to have passed it, and nothing anywhere asserts that their output was checked.

What the package-internal initialiser buys is narrower than unbypassability and is worth stating exactly, because the wider claim was made here once and was false: an outside caller cannot fabricate a candidate list out of nothing and present it as validated, and inside the package the value can be constructed, which is what makes the seam's own violation tests writable. That is a deliberate trust boundary rather than an omission. It is not a guarantee that the checks cannot be skipped.

One question remains open rather than answered by this requirement: whether a strategy's reported identifier and displacement bound require an authority of their own. It is tracked; it is not discharged here.

#### Scenario: Retrieval is unchanged when the strategy is swapped

- **WHEN** the same candidate list is passed to two different strategies
- **THEN** both invocations produce results over exactly the same set of candidates, differing only in order and in reported displacement

#### Scenario: A strategy cannot introduce candidates

- **WHEN** a strategy returns its result list
- **THEN** the returned list is a permutation of the input candidates, with no candidate added and none removed

#### Scenario: A strategy that reads the corpus gains nothing the seam will accept

- **GIVEN** a strategy that reconstructs candidate text by reading the corpus itself
- **WHEN** it returns an ordering that violates any of the checks enumerated above
- **THEN** the invocation fails with the named violation for that check, exactly as it would for a strategy that read nothing

#### Scenario: The prohibitions are not compile-time facts

- **GIVEN** a module that does not depend on the memory layer
- **WHEN** it reads the event file using only the standard library
- **THEN** it succeeds, and this specification's prohibition is not thereby satisfied by the type system

##### Example: What removing the convenience types would and would not change

- **GIVEN** the two refuting tests written during the review that produced this requirement — one writing and reading an event file without importing the memory layer, one reconstructing corpus text through the public corpus-reading protocol — neither of which was committed, so this example records what they did rather than pointing at code a reader can run
- **WHEN** the event type's coded representation is moved out of the shared core module and the corpus-reading protocol is made internal
- **THEN** the second test stops compiling, the first still passes, and a rewrite of either against the standard library passes again — so the prohibition remains an implementation obligation either way

#### Scenario: A conformer that was never handed a token cannot reach the checked method

- **GIVEN** a strategy conformer defined in another module, which has never been handed a validated-candidates value
- **WHEN** a caller in that module attempts to invoke the checked method directly
- **THEN** it cannot, because it has no way to obtain the value the method requires: that value's initialiser is not visible outside the defining package

#### Scenario: A token that was handed out is dead once the call returns

- **GIVEN** a strategy conformer that retains the validated-candidates value it is handed during a normal invocation
- **WHEN** any code holding that retained value reads its candidates after that invocation has returned
- **THEN** it traps, naming the reason — the retained value carries no candidates once the seam call that created it has finished


<!-- @trace
source: name-seam-enforcement-points
updated: 2026-08-25
code:
  - Sources/LTMQuery/Module.swift
  - Sources/LTMQuery/MemoryStrategy.swift
  - Package.swift
  - Tests/LTMQueryTests/MemoryStrategyTests.swift
-->

---
### Requirement: Every result carries displacement and a reason with two independent axes

Each returned result SHALL carry its position displacement relative to the input candidate order, and a reason composed of **two independent fields**:

- **history** — the state of *this candidate's own* recorded history: none (including a history whose net strength is zero), counted (naming the contributing signals), or orphaned.
- **movement** — whether the candidate is unmoved, advanced, or receded relative to pure retrieval order, and by how many positions.

The two SHALL NOT be collapsed into a single value. Three successive review rounds found a defect of the same class in a single-value encoding — a result that had moved reporting "no adjustment"; a candidate promoted by a sinking peer reporting a negative displacement; a candidate with positive history that was pushed down reporting that its history had promoted it; an orphan that moved reporting only that its history was ignored. Each round added a case; the defect was that one value cannot state two independent facts.

The reason SHALL NOT assert a *cause* for the movement. A candidate can advance because its own history is strong, because a neighbour was suppressed, or both, and a bounded reordering does not retain enough information to distinguish them. Naming the signals and stating the direction is what the implementation can support; attributing the cause is not.

The `archival` strategy is the exception to consulting history at all: its reason SHALL report history as none regardless of the projection, because its contract is to produce identical output for every projection.

#### Scenario: Reason names the contributing events

- **GIVEN** an anchor whose projection includes three `cited` events
- **WHEN** a strategy moves that anchor upward
- **THEN** the result's history field names the citation signal and its movement field reports the advance

#### Scenario: A candidate with its own history that is pushed down says it receded

- **GIVEN** a band of two where both candidates have positive history and the second is stronger
- **WHEN** `human-like` reorders the band
- **THEN** the first candidate's history reports its own counted signals and its movement reports a recession

#### Scenario: An orphan that moved reports both facts

- **GIVEN** a band of two where the first anchor is orphaned and the second has recorded history
- **WHEN** `human-like` reorders the band
- **THEN** the first candidate's history reports orphaned and its movement reports a recession

---
### Requirement: The archival strategy performs no reordering

The `archival` strategy SHALL return the candidate list in its input order. Every result it returns SHALL carry a displacement of zero. It SHALL produce identical output regardless of the projection it is given.

#### Scenario: Archival ignores usage history entirely

- **GIVEN** a candidate list and two projections, one empty and one containing many reinforcing events
- **WHEN** the `archival` strategy is invoked with each projection in turn
- **THEN** both invocations return the same order, and every displacement is zero

---
### Requirement: Reordering is confined to a relevance band

A strategy that reorders SHALL move a candidate only among candidates sharing its relevance band. Attempting to move a candidate across a band boundary SHALL fail loudly rather than being silently clamped or ignored.

#### Scenario: Cross-band movement is rejected

- **WHEN** a strategy attempts to place a candidate from a lower relevance band above a candidate from a higher band
- **THEN** the invocation fails and reports the attempted band violation

#### Scenario: Within-band promotion is permitted

- **GIVEN** two candidates in the same relevance band, one with recorded `cited` events and one with none
- **WHEN** the `human-like` strategy is invoked
- **THEN** the candidate with citations is ordered above the other and its reason names the citation signal

---
### Requirement: Displacement is bounded in both directions

A strategy that reorders SHALL move a candidate by at most a configured number of positions, **in either direction**. The bound SHALL be supplied as configuration rather than compiled in. The default SHALL be one position, and SHALL be documented as provisional: its correct value is not derivable before an evaluation set exists. Attempting to move a candidate beyond the bound SHALL fail loudly rather than being clamped.

An intermediate draft of this requirement made the bound apply to promotion only, on the argument that a symmetric bound necessarily caps a whole band's promotions at the bound. **That argument was false** — with a bound of one, a band of four can go from `[A,B,C,D]` to `[B,A,D,C]`, which has two promotions and no displacement above one. What the measurement behind that draft actually refuted was one particular reordering algorithm, not the contract; the contract was changed when the algorithm should have been. The requirement is symmetric again and the algorithm was replaced with one that satisfies it by construction.

#### Scenario: Movement beyond the bound is rejected in either direction

- **WHEN** a strategy attempts to move a candidate more positions than the configured bound allows, whether up or down
- **THEN** the invocation fails and reports the attempted bound violation

#### Scenario: A candidate displaced by a promoted peer says so

- **GIVEN** a band of two in which the second candidate has recorded history and the first has none
- **WHEN** `human-like` reorders the band
- **THEN** the first is reported with a displacement of minus one, a history of none, and a movement of receded — not a movement of unmoved

  (An earlier wording required the reason to state "it was displaced by a peer". That is a causal claim, which the same specification forbids two requirements above, and which the implementation cannot support: a bounded reordering does not retain who overtook whom. The observable facts are the direction and the absence of the candidate's own counted history.)

#### Scenario: Promotions occur wherever they are needed, not only at the head of the band

- **GIVEN** a band of four in which the second and fourth candidates have recorded history and the first and third have none
- **WHEN** `human-like` reorders the band with a bound of one
- **THEN** both reinforced candidates carry a positive displacement, and every displacement is within the bound

#### Scenario: A non-finite base score is rejected before any reordering

- **WHEN** any candidate carries a base score that is not finite
- **THEN** every strategy rejects the input with a named error rather than reordering it

#### Scenario: The bound is configurable at construction

- **GIVEN** a strategy constructed with a bound of three positions
- **WHEN** a heavily reinforced candidate is reordered within its band
- **THEN** the candidate moves by at most three positions

##### Example: Bound applied within a band

A candidate is promoted past peers whose strength is strictly lower, up to the bound, and the peers it overtakes sink correspondingly — also within the bound.

| Configured bound | Input position | Reinforcing events | Other reinforced peers | Resulting position |
| ---------------- | -------------- | ------------------ | ---------------------- | ------------------ |
| 1                | 5              | 10 citations       | none                   | 4                  |
| 3                | 5              | 10 citations       | none                   | 2                  |
| 3                | 5              | 0                  | none                   | 5                  |

The last column is exact only for the single-promoter case shown. With several reinforced candidates competing for the same positions, each still moves at most `bound`, but which of them advances depends on their relative strengths — a symmetric bound cannot let two candidates both pass the same peer when that peer may sink only one place. That is a property of the bound, not a defect: it is the sense in which the bound limits how far memory may override retrieval order.

---
### Requirement: The human-like tier's reinforcement decays with age

`human-like` SHALL weight each deliberate event by a factor that is non-increasing in the event's age at the evaluation instant, so that the same event contributes strictly less at a later evaluation instant than at an earlier one, all else equal. The decay's form is power-law and its exponent SHALL be configuration, not a compiled-in constant.

Without this requirement an implementation that counts deliberate events linearly and never reads a timestamp satisfies every other `human-like` scenario — and decay is the mechanism the tier is named for. The exponent's default is taken from an external source (`PsychQuant/ai4o`, tuned per Wixted & Ebbesen 1991 on a different corpus) and is therefore unvalidated here; that is a calibration gap, not a licence to omit the mechanism.

#### Scenario: The same event contributes less later

- **GIVEN** one `cited` event on an anchor
- **WHEN** the projection is taken at two evaluation instants a day apart
- **THEN** the anchor's reinforcement at the later instant is strictly smaller

#### Scenario: A recent citation outranks an older one

- **GIVEN** two candidates in one band, each with exactly one `cited` event, one recent and one much older
- **WHEN** `human-like` reorders the band
- **THEN** the recently cited candidate is ordered above the other

---
### Requirement: Orphaned anchors do not influence ranking

A strategy SHALL ignore projection entries whose anchors dereference as orphaned. Such entries SHALL NOT contribute reinforcement or suppression, and SHALL NOT cause the invocation to fail.

#### Scenario: Orphaned history is inert

- **GIVEN** a projection in which the most heavily reinforced anchor is orphaned
- **WHEN** the `human-like` strategy is invoked
- **THEN** that anchor receives no promotion and the invocation completes normally

---
### Requirement: Strategies are distinguished by mechanism, never by magnitude

A strategy SHALL be defined by which event kinds it consumes **and under what condition it acts**, never by the magnitude of the adjustment it applies. Supplying a different displacement bound to an existing strategy SHALL NOT constitute a new strategy.

Three strategies ship:

- `archival` consumes no event kinds and never reorders.
- `conservative` consumes `opened`, `cited`, `pinned`, `dismissed`, and acts **only where base scores are exactly equal within a band**. It never changes the relative order of two candidates the retrieval layer scored differently.
- `human-like` consumes the same four kinds and acts wherever recorded history differs, subject to the promotion bound.

`conservative` and `human-like` therefore share a signal set — and the same bounded reordering core — and differ in **which ranges that core is applied to**. The evidence for calling this a mechanism difference is the non-tied case: where base scores differ, `conservative` does not move at all and no bound makes `human-like` match it. On an all-tied band the two do converge once the bound is large enough; that is stated here rather than omitted, because an earlier draft argued the mechanism claim from the bound-zero case alone, which is guaranteed by an early return and therefore proves nothing about the rest of the range.

Both strategies are subject to the displacement bound. `conservative` is not exempt: an earlier draft passed the guard a threshold that could never fire, which is the same defect as a strategy authorising its own bound. The tie-run constraint is an **additional** condition, not a substitute — it is stricter about which candidates may be reordered and says nothing about how far, so the two constraints are incomparable and both must hold.

**Whether `conservative` is distinguishable from `archival` in practice is now measured only through the tie rate, and only on the corpus subsets one record covers; this specification assumes nothing beyond that record.** Off ties the two produce the same order and the same displacements; their reasons differ, because `conservative` reports the history it consulted and `archival` reports none by contract. An earlier draft said "provably identical", which was false in the reason field — the test that now pins this was green under the previous single-value reason encoding and went red the moment the encoding was corrected. The tier's usefulness therefore reduces entirely to how often exact ties occur. Ties are structurally guaranteed to be possible — reciprocal rank fusion assigns `1/(k + rank)` per contributing list, so two candidates each appearing in exactly one list at the same rank score identically — and the *rate* has now been measured on a **subset** of this corpus — see `docs/measurements/2026-08-22-rrf-tie-rate.md` for what that record does and does not cover. An artifact MAY state the measured rate provided it names that record; it MUST NOT generalise beyond the subset the record covers, and it MUST NOT claim the tier is *better* than any other tier, which remains unmeasured and requires the evaluation set of #16.

Two further constraints on how that record may be cited, both learned the hard way in its own verify round:

- No artifact may derive a ceiling on the tie rate from an observed run-length distribution. This is stated as a property rather than by citing what was observed, because an earlier draft of this very clause cited "the observed tie runs were all of length 2" — an observation the corrected re-run then falsified, leaving a clause that warned against reasoning from observations while itself resting on a wrong one. The reason no such ceiling follows is that ties are not confined to single-channel candidates: for `rrfK = 60` and channel depth 100, `1/(60+36) + 1/(60+100)`, `1/(60+40) + 1/(60+90)` and `1/(60+60) + 1/(60+60)` are the exact same rational number, so several two-channel candidates can share a bit-identical score with no `trigram` contribution at all.
- The measurement reads scores out of `ltm query --json`. `JSONSerialization`'s number *parsing* is not correctly rounded and collapses some distinct engine values, so a probe that parses scores into `Double` over-reports ties in the two-channel score space. The record's probe compares the raw JSON number tokens instead, which is sound because serialisation is injective. Any future probe reading scores through a JSON parser inherits this defect.

#### Scenario: Two bounds do not constitute two strategies

- **WHEN** the `human-like` strategy is constructed with two different displacement bounds
- **THEN** both constructions report the same strategy identity, differing only in configuration

#### Scenario: A bound of zero does not reproduce tie-breaking

- **GIVEN** a band whose candidates all carry equal base scores, and a projection in which they differ in strength
- **WHEN** `human-like` is constructed with a bound of zero and when `conservative` is used
- **THEN** the zero-bound `human-like` returns the input order unchanged, while `conservative` at its default bound moves at least one tied candidate

> Note the asymmetry in what this scenario claims. `human-like` at bound zero does *nothing*, which is total. `conservative` at its default bound does *something*, which is not the same as ordering the run by strength: the shared reordering core performs a bounded number of adjacent-swap passes and lets each candidate move at most once per pass, so on a tied run `[a, b, c]` with strengths `0, 2, 5` the default bound yields `[b, a, c]` — the strongest candidate does not move at all. An earlier wording of this THEN said "reorders the tied candidates by strength", which is false at the shipped default and was not caught because the covering test asserted only that the order changed (#17 verify).

#### Scenario: Conservative leaves differently-scored candidates alone

- **GIVEN** a band whose candidates carry strictly decreasing base scores, and a projection strongly reinforcing the last of them
- **WHEN** `conservative` is used
- **THEN** the returned order equals the input order and every displacement is zero

---
### Requirement: Every recorded presentation identifies the result list it originated from

When `LTMService` records events for a query's results, it SHALL generate one presentation identifier per query call and attach it to every recorded event from that call's result list. A query result exposed to a caller SHALL carry that same identifier so a later interaction with one of its results can be recorded under the same group.

#### Scenario: Two separate queries produce two separate presentation groups

- **GIVEN** two separate calls to record events for two different queries
- **WHEN** the resulting events are inspected
- **THEN** every event from the first call shares one presentation identifier, every event from the second call shares a different presentation identifier, and no event from either call shares its identifier with the other call

#### Scenario: A query result exposes the identifier it was recorded under

- **GIVEN** a query call that records events for its results
- **WHEN** the returned results are inspected
- **THEN** each result's exposed presentation identifier matches the identifier attached to that result's recorded event

---
### Requirement: The human-like tier spreads reinforcement to co-presented anchors, one hop only

`human-like` SHALL treat anchors that were presented together in the same presentation group as connected: when a deliberate reinforcing event (`opened`, `cited`, or `pinned`) occurs on an anchor, every other live anchor presented in the same group SHALL receive a fraction of that event's decayed reinforcement, in addition to any reinforcement that anchor accrues from its own event history. **Every condition, exclusion and guarantee governing when spreading applies and how much it contributes is owned by `memory-events`'s "Only deliberate interactions reinforce" Requirement, and is deliberately NOT enumerated here.** This Requirement's scope is *which strategy* the mechanism applies to; the mechanism's own conditions live in exactly one place. Do not restate them here even partially: fix rounds 2 through 5 of #15 each restated some subset, and each subset was missing at least one condition — the enumeration is the defect, not any particular omission from it. A spread contribution received by an anchor SHALL NOT itself be further spread to other anchors (this one-hop bound is a property of the strategy's wiring, not of the projection conditions, which is why it stays here).

Spreading is a property of the `human-like` tier only. When a strategy is projected through `LTMService`'s single-strategy query path (`LTMService.makeProjection`), no other shipped strategy SHALL receive spreading-derived reinforcement, regardless of which event kinds it otherwise consumes. In particular, `conservative` consumes the same four event kinds as `human-like` (see "Strategies are distinguished by mechanism, never by magnitude") but SHALL NOT receive spreading contributions on that path — sharing a signal set does not imply sharing every mechanism gated on that signal set.

**Known gap (not covered by this guarantee):** the A/B comparison harness (`LTMEval.InterleavingHarness.present`) shares a single `Projection` object between both compared strategies (required by "MemoryStrategy is the sole seam between retrieval and memory"'s sibling requirement that both arms of a comparison receive the same projection). `ProjectionParameters.default` carries a nonzero `spreadingActivationFactor` (0.3), so any caller that builds the shared projection with the default parameters — not merely a caller that deliberately opts into a nonzero factor — has spreading contributions reach whichever strategy is compared against `human-like`, including `conservative`. As of this writing `InterleavingHarness.present` has no production caller (only tests), so this gap is latent rather than live; it is not resolved here because doing so requires redesigning the comparison harness's projection-sharing contract, which is out of scope for this change.

**Reachability of this Requirement as a whole (2026-08-21):** spreading is driven entirely by `opened`/`cited`/`pinned` events, and **no shipped code path writes any of them** — `LTMService`'s only event-writing path records `shown` exclusively, and no other production caller constructs a deliberate event. The spreading pass therefore never executes outside tests and library-level API use. Every positive assertion in this Requirement and in `memory-events`'s spreading clauses is, today, exercised only by the test suite; a production write path for deliberate interactions arrives with the Stage 2 MCP work (#24). This is recorded because a reader would otherwise reasonably infer from the SHALLs that the mechanism is live in the shipped product.

#### Scenario: A co-presented anchor with no direct interaction of its own gains reinforcement

- **GIVEN** a presentation group of three anchors, one of which is deliberately opened (with a positive, i.e. nonzero, `openedWeight`) and the other two of which are never directly interacted with
- **WHEN** the event sequence is projected
- **THEN** the two anchors that were never directly interacted with each show nonzero reinforcement, scaled down from the opened anchor's own reinforcement by the configured spreading factor

#### Scenario: Spreading does not recurse past one hop

- **GIVEN** anchor A is deliberately opened and anchor B receives spread reinforcement from A because they were co-presented
- **WHEN** anchor B's spread reinforcement is examined for its effect on a third anchor C, co-presented with B in a different presentation group but never co-presented with A
- **THEN** anchor C receives no reinforcement from A's original event

#### Scenario: Dismissal does not spread

- **GIVEN** a presentation group where one anchor is deliberately dismissed and another anchor in the same group has no direct interaction
- **WHEN** the event sequence is projected
- **THEN** the anchor with no direct interaction shows no suppression contributed by the dismissed anchor's event

#### Scenario: Conservative does not receive spreading reinforcement despite sharing human-like's signal set

- **GIVEN** a presentation group of two anchors, queried under `conservative` through `LTMService`'s single-strategy query path (not the A/B comparison harness — see the Known-gap note above), where one anchor is deliberately opened and the other has only a `shown` event and no other events
- **WHEN** `conservative`'s projection is used to rank the group
- **THEN** the anchor with only a `shown` event shows zero reinforcement, unlike the same scenario projected for `human-like`

<!-- @trace
source: add-spreading-activation-fixes
updated: 2026-08-20
code:
  - Tests/LTMServiceTests/LTMServiceTests.swift
  - Sources/ltm/Commands.swift
  - Tests/LTMEvalTests/ComparisonReportTests.swift
  - Sources/LTMQuery/Strategies/HumanLikeStrategy.swift
  - Sources/LTMService/LTMService.swift
  - Sources/LTMQuery/MemoryStrategy.swift
  - Sources/LTMEval/ComparisonReport.swift
  - Sources/LTMMemory/Projection.swift
  - CHANGELOG.md
  - Tests/LTMMemoryTests/ProjectionTests.swift
  - Tests/LTMServiceTests/CLICommandTests.swift
-->

---
### Requirement: A strategy's additional acting condition is declared, and the seam enforces it

A strategy SHALL declare, as part of its public interface, a set of placement constraints it holds itself to **in addition to** those its authority imposes. That set SHALL be drawn from a closed enumeration owned by the seam; a strategy SHALL NOT define a constraint of its own. The default SHALL be the empty set, which leaves the strategy subject to its authority's constraints and to those that apply to every strategy.

The seam SHALL enforce every constraint in the composed set — the union of the authority's and the strategy's — after the strategy returns and before the result reaches the caller, on the same path that already enforces band preservation and the displacement bound. A strategy SHALL NOT be the party that checks its own constraints. A violation SHALL fail loudly rather than being clamped, downgraded, or ignored.

The enumeration SHALL contain only cases the seam can evaluate from information it already holds about the candidates. A strategy therefore cannot *define* what a constraint means: the seam owns the derivation, and no value supplied by the strategy enters it.

**A strategy cannot be checked less strictly than the authority for the identifier it reports, and the reason is the composition, not the strategy's good behaviour.** The declaration is still read afresh on every call and is still neither recorded nor validated — a conformer implementing it as a computed property can still return different sets on different reads. What changed is that the read no longer determines what applies: the union with the authority's set does.

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


<!-- @trace
source: authorize-strategy-declarations
updated: 2026-08-24
code:
  - Tests/LTMQueryTests/PlacementConstraintTests.swift
  - Sources/LTMQuery/MemoryStrategy.swift
  - Sources/LTMService/StrategyRegistry.swift
  - Tests/LTMQueryTests/MemoryStrategyTests.swift
  - CLAUDE.md
  - CHANGELOG.md
  - Tests/LTMQueryTests/StrategyTests.swift
  - Tests/LTMEvalTests/InterleavingTerminationTests.swift
  - Sources/LTMQuery/StrategyAuthority.swift
  - Sources/LTMQuery/RankingGuard.swift
  - Sources/LTMQuery/Strategies/ConservativeStrategy.swift
-->

---
### Requirement: An authority table, not the strategy, decides which constraints govern it

The seam SHALL resolve, from a closed table keyed by strategy identifier, the placement constraints that govern a strategy. That table SHALL be the authority. A strategy's own declaration SHALL be treated as an addition to it, never as a substitute for it.

The effective constraint set SHALL be the union of the authority's set and the strategy's, and every check SHALL read that union. A strategy may add constraints on itself; declaring none leaves the authority's intact.

**Union composition is what makes cross-call variance stop mattering, and it is why the seam needs no memory of what a strategy declared.** A declaration read afresh on each call may differ between calls; the union already contains the authority's constraints, so the looser answer never reaches a check. The guarantee therefore holds per invocation, from the composition's shape, without reference to any other invocation. An implementation SHALL NOT record declarations across calls to obtain this property.

An earlier draft of this paragraph also required the seam to remain a pure function of its arguments, and seven artifacts repeated it. The shipped implementation does not satisfy it: the authority lookup consults a process-lifetime registration table, behind a lock, on every call — the two costs this specification's own reasoning cited when rejecting the snapshot alternative. What survives is the narrower property that matters here: **no record is kept of what any strategy declared**, so no invocation's outcome depends on another's. Purity is not required, and claiming it was the same defect this Requirement exists to repair — a sentence asserted in many places and verified in none.

**The identifier the authority is keyed by SHALL be checked against the strategy's actual type, and the reason is that the key was otherwise the same unverified self-report the table was introduced to replace.** The authority is selected by the strategy's `id`, a `{ get }` requirement read afresh on every call, never recorded and never cross-checked — structurally identical to the declaration this Requirement constrains. A conformer whose `id` alternated between two authorised identifiers therefore obtained one authority on one call and another on the next; this was reproduced by execution, yielding the same accept/reject alternation that motivated this Requirement in the first place. The seam SHALL therefore refuse, with a named failure, any strategy reporting an identifier the registry can construct whose constructed type differs from the strategy's own. The fix is not a record of what the strategy said before — this Requirement's next paragraph forbids that — it is a per-call agreement between two things the seam can both read on that call.

**What that establishes, and the precondition it rests on.** For a conformer defined outside the package there is no identifier that is authorised and not shipped: the table's key set and the registry's constructible set are required below to be the same set, and the registration point that could add a third kind of entry is package-internal. Every authorised identifier such a conformer can report is therefore one the registry constructs, the check applies to all of them, and the identifier is pinned to the type — the alternating-identity conformer is refused on **every** call rather than on alternate ones. The claim is conditional on that key-set identity, not on the check alone, which is why the identity is a stated Requirement below with a test rather than an observation about the current table.

**Inside the package the pin does not hold, deliberately.** The package-internal test identifiers name no shipped strategy, so the registry constructs nothing for them and the check has nothing to compare; a conformer alternating between two of those still changes authority between calls. This is the same trust boundary as the registration point itself and is recorded for the same reason: the seam's own violation tests are written with conformers that must not be any shipped strategy, and a boundary that is not written down is indistinguishable from an oversight. It is not a claim that the pin holds everywhere.

**The table governs the constraints and SHALL NOT govern the displacement bound.** The table is keyed by identifier, so it can only carry what the identifier determines. This specification distinguishes strategies by which signals they consume and under what conditions they act, and never by magnitude — and it requires the bound to be configurable at construction, so two instances sharing an identifier may hold different bounds. A per-identifier ceiling would either contradict that requirement or make the construction parameter inert. Who decides the bound therefore remains open, and this Requirement MUST NOT be read as closing it; what is now established is that an identity-keyed authority is the wrong shape to close it with. That open question is tracked as issue #38 — an earlier pointer named an issue that has since been closed, and the substitute was not written until roughly eight hours later, which is the failure mode this repository's own issues describe (#36). (An earlier revision of this sentence said "two days"; the git timestamps say otherwise, and the correction is recorded because a figure asserted without checking is precisely what issue #39 names.)

**The identifier a strategy reports SHALL be read once per invocation and used for both the authority lookup and any failure it produces.** Reading it more than once lets a conformer whose identifier varies between reads be refused under one name and reported under another, so the message names something that was never consulted — and that message is the only evidence the caller receives. This is narrower than pinning a strategy to an identity, which the type check above establishes only for identifiers the registry can construct: this Requirement establishes internal consistency within a single call, and it holds for the package-internal identifiers the type check cannot reach.

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

- **GIVEN** any candidate list and any projection
- **WHEN** any of the three shipped strategies is invoked through the seam
- **THEN** it returns the same result it returned before the authority table existed — the same ordering, the same displacement on every result, and the same reason on every result

**What backs the universal quantifiers is the composition identity, not an exhaustive test, and the difference matters.** Each shipped strategy's declaration is equal to its authority entry, and the seam composes them as a union; `union(X, X)` is `X`, so the set of constraints checked is byte-identical to what the declaration alone produced before, for every input. No behaviour downstream of that set changes, so no field of the result can differ.

An earlier revision of this scenario claimed only that the *ordering* was unchanged, and quantified over strategies but not over inputs. That was weaker than what the composition actually gives, and the weakening was silent — it was caught by the review of the change that introduced it (#34) and restored here (#36). Recording the mechanism rather than only the conclusion is the point: a reader who knows the guarantee rests on `union(X, X) == X` also knows exactly which future change would break it — making a shipped strategy's declaration differ from its table entry.

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

<!-- @trace
source: authorize-strategy-declarations
updated: 2026-08-24
code:
  - Tests/LTMQueryTests/PlacementConstraintTests.swift
  - Sources/LTMQuery/MemoryStrategy.swift
  - Sources/LTMService/StrategyRegistry.swift
  - Tests/LTMQueryTests/MemoryStrategyTests.swift
  - CLAUDE.md
  - CHANGELOG.md
  - Tests/LTMQueryTests/StrategyTests.swift
  - Tests/LTMEvalTests/InterleavingTerminationTests.swift
  - Sources/LTMQuery/StrategyAuthority.swift
  - Sources/LTMQuery/RankingGuard.swift
  - Sources/LTMQuery/Strategies/ConservativeStrategy.swift
-->