## ADDED Requirements

### Requirement: MemoryStrategy is the sole seam between retrieval and memory

The system SHALL expose exactly one abstraction through which usage history influences result ordering. That abstraction SHALL take an ordered candidate list carrying base scores and relevance bands, together with a projection of per-anchor statistics, and SHALL return a reordered result list. Retrieval SHALL NOT read the event store directly, and no strategy SHALL read the corpus directly.

#### Scenario: Retrieval is unchanged when the strategy is swapped

- **WHEN** the same candidate list is passed to two different strategies
- **THEN** both invocations produce results over exactly the same set of candidates, differing only in order and in reported displacement

#### Scenario: A strategy cannot introduce candidates

- **WHEN** a strategy returns its result list
- **THEN** the returned list is a permutation of the input candidates, with no candidate added and none removed

### Requirement: Every result carries displacement and reason

Each returned result SHALL carry its position displacement relative to the input candidate order and a reason describing why it moved. A result whose displacement is zero SHALL carry a reason indicating that no adjustment was applied.

#### Scenario: Reason names the contributing events

- **GIVEN** an anchor whose projection includes three `cited` events
- **WHEN** a strategy moves that anchor upward
- **THEN** the result's reason names the citation signal as the contributing cause

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

### Requirement: Promotion is bounded; demotion is a reported consequence

A strategy that reorders SHALL promote a candidate by at most a configured number of positions. The bound SHALL be supplied as configuration rather than compiled in. The default SHALL be one position, and SHALL be documented as provisional: its correct value is not derivable before an evaluation set exists. Attempting to promote a candidate beyond the bound SHALL fail loudly rather than being clamped.

Demotion SHALL NOT be separately bounded. A candidate sinks by exactly as many positions as the number of peers promoted past it, and that displacement SHALL be reported on the result like any other.

The bound is deliberately one-directional, and this replaces an earlier symmetric formulation. The symmetric version was measured to cap a whole band's promotions at the bound regardless of band size — a band of 32 with 31 reinforced candidates produced exactly one promotion at the default — because a candidate that may sink at most `bound` positions can be overtaken by at most `bound` peers. That made the memory-bearing strategy indistinguishable from the memory-free one, defeating the comparison the change exists to enable. What limits the damage of reordering is the **relevance band**, whose members are equally relevant by construction; the promotion bound exists to stop a single candidate leaping, not to stop many candidates each advancing one place.

#### Scenario: Promotion beyond the bound is rejected

- **WHEN** a strategy attempts to promote a candidate more positions than the configured bound allows
- **THEN** the invocation fails and reports the attempted bound violation

#### Scenario: A candidate overtaken by several peers sinks by more than the bound

- **GIVEN** a band of four candidates in which the first has no recorded history and the other three do, and a bound of one
- **WHEN** `human-like` reorders the band
- **THEN** each of the three is promoted by at most one position, the first is reported with a displacement of minus three, and the invocation succeeds

#### Scenario: Every reinforced candidate advances, not only the first

- **GIVEN** a band of twelve whose first candidate has no history and whose other eleven do
- **WHEN** `human-like` reorders the band with a bound of one
- **THEN** at least ten of the eleven carry a positive displacement

#### Scenario: The bound is configurable at construction

- **GIVEN** a strategy constructed with a bound of three positions
- **WHEN** a heavily reinforced candidate is reordered within its band
- **THEN** the candidate moves by at most three positions

##### Example: Bound applied within a band

A candidate is promoted past peers whose strength is strictly lower, up to the bound.

| Configured bound | Input position | Reinforcing events | Resulting position |
| ---------------- | -------------- | ------------------ | ------------------ |
| 1                | 5              | 10 citations       | 4                  |
| 3                | 5              | 10 citations       | 2                  |
| 3                | 5              | 0                  | 5                  |

Unlike the earlier symmetric formulation, these rows do not depend on how many other candidates in the band carry history: each reinforced candidate spends its own promotion budget independently. The candidates they overtake sink correspondingly, which is reported and not bounded.

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

`conservative` and `human-like` therefore share a signal set and differ in condition. That is a mechanism difference, not a magnitude one: constructing `human-like` with a bound of zero yields no reordering at all, not tie-breaking.

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
