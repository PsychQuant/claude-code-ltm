## ADDED Requirements

### Requirement: MemoryStrategy is the sole seam between retrieval and memory

The system SHALL expose exactly one abstraction through which usage history influences result ordering. That abstraction SHALL take an ordered candidate list carrying base scores and relevance bands, together with a projection of per-anchor statistics, and SHALL return a reordered result list. Retrieval SHALL NOT read the event store directly, and no strategy SHALL read the corpus directly.

#### Scenario: Retrieval is unchanged when the strategy is swapped

- **WHEN** the same candidate list is passed to two different strategies
- **THEN** both invocations produce results over exactly the same set of candidates, differing only in order and in reported displacement

#### Scenario: A strategy cannot introduce candidates

- **WHEN** a strategy returns its result list
- **THEN** the returned list is a permutation of the input candidates, with no candidate added and none removed

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

### Requirement: The archival strategy performs no reordering

The `archival` strategy SHALL return the candidate list in its input order. Every result it returns SHALL carry a displacement of zero. It SHALL produce identical output regardless of the projection it is given.

#### Scenario: Archival ignores usage history entirely

- **GIVEN** a candidate list and two projections, one empty and one containing many reinforcing events
- **WHEN** the `archival` strategy is invoked with each projection in turn
- **THEN** both invocations return the same order, and every displacement is zero

### Requirement: Reordering is confined to a relevance band

A strategy that reorders SHALL move a candidate only among candidates sharing its relevance band. Attempting to move a candidate across a band boundary SHALL fail loudly rather than being silently clamped or ignored.

#### Scenario: Cross-band movement is rejected

- **WHEN** a strategy attempts to place a candidate from a lower relevance band above a candidate from a higher band
- **THEN** the invocation fails and reports the attempted band violation

#### Scenario: Within-band promotion is permitted

- **GIVEN** two candidates in the same relevance band, one with recorded `cited` events and one with none
- **WHEN** the `human-like` strategy is invoked
- **THEN** the candidate with citations is ordered above the other and its reason names the citation signal

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

### Requirement: Orphaned anchors do not influence ranking

A strategy SHALL ignore projection entries whose anchors dereference as orphaned. Such entries SHALL NOT contribute reinforcement or suppression, and SHALL NOT cause the invocation to fail.

#### Scenario: Orphaned history is inert

- **GIVEN** a projection in which the most heavily reinforced anchor is orphaned
- **WHEN** the `human-like` strategy is invoked
- **THEN** that anchor receives no promotion and the invocation completes normally

### Requirement: Strategies are distinguished by mechanism, never by magnitude

A strategy SHALL be defined by which event kinds it consumes **and under what condition it acts**, never by the magnitude of the adjustment it applies. Supplying a different displacement bound to an existing strategy SHALL NOT constitute a new strategy.

Three strategies ship:

- `archival` consumes no event kinds and never reorders.
- `conservative` consumes `opened`, `cited`, `pinned`, `dismissed`, and acts **only where base scores are exactly equal within a band**. It never changes the relative order of two candidates the retrieval layer scored differently.
- `human-like` consumes the same four kinds and acts wherever recorded history differs, subject to the promotion bound.

`conservative` and `human-like` therefore share a signal set — and the same bounded reordering core — and differ in **which ranges that core is applied to**. The evidence for calling this a mechanism difference is the non-tied case: where base scores differ, `conservative` does not move at all and no bound makes `human-like` match it. On an all-tied band the two do converge once the bound is large enough; that is stated here rather than omitted, because an earlier draft argued the mechanism claim from the bound-zero case alone, which is guaranteed by an early return and therefore proves nothing about the rest of the range.

Both strategies are subject to the displacement bound. `conservative` is not exempt: an earlier draft passed the guard a threshold that could never fire, which is the same defect as a strategy authorising its own bound. The tie-run constraint is an **additional** condition, not a substitute — it is stricter about which candidates may be reordered and says nothing about how far, so the two constraints are incomparable and both must hold.

**Whether `conservative` is distinguishable from `archival` in practice is unmeasured, and this specification does not assume it is.** Off ties the two produce the same order and the same displacements; their reasons differ, because `conservative` reports the history it consulted and `archival` reports none by contract. An earlier draft said "provably identical", which was false in the reason field — the test that now pins this was green under the previous single-value reason encoding and went red the moment the encoding was corrected. The tier's usefulness therefore reduces entirely to how often exact ties occur. Ties are structurally guaranteed to be possible — reciprocal rank fusion assigns `1/(k + rank)` per contributing list, so two candidates each appearing in exactly one list at the same rank score identically — but the *rate* has not been measured on this corpus. Until it is, no artifact may claim the tier "hits in practice".

#### Scenario: Two bounds do not constitute two strategies

- **WHEN** the `human-like` strategy is constructed with two different displacement bounds
- **THEN** both constructions report the same strategy identity, differing only in configuration

#### Scenario: A bound of zero does not reproduce tie-breaking

- **GIVEN** a band whose candidates all carry equal base scores, and a projection in which they differ in strength
- **WHEN** `human-like` is constructed with a bound of zero and when `conservative` is used
- **THEN** the zero-bound `human-like` returns the input order unchanged while `conservative` reorders the tied candidates by strength

#### Scenario: Conservative leaves differently-scored candidates alone

- **GIVEN** a band whose candidates carry strictly decreasing base scores, and a projection strongly reinforcing the last of them
- **WHEN** `conservative` is used
- **THEN** the returned order equals the input order and every displacement is zero
