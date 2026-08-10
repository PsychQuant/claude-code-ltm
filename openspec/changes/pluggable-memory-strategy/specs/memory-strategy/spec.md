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

### Requirement: Displacement is bounded by a configured parameter

A strategy that reorders SHALL move a candidate by at most a configured number of positions. The bound SHALL be supplied as configuration rather than compiled in. The default SHALL be one position, and SHALL be documented as provisional: its correct value is not derivable before an evaluation set exists, and it is expected to be revised once one does. Attempting to move a candidate beyond the bound SHALL fail loudly rather than being clamped.

#### Scenario: Movement beyond the bound is rejected

- **WHEN** a strategy attempts to move a candidate more positions than the configured bound allows
- **THEN** the invocation fails and reports the attempted bound violation

#### Scenario: The bound is configurable at construction

- **GIVEN** a strategy constructed with a bound of three positions
- **WHEN** a heavily reinforced candidate is reordered within its band
- **THEN** the candidate moves by at most three positions

##### Example: Bound applied within a band

| Configured bound | Input position | Reinforcing events | Resulting position |
| ---------------- | -------------- | ------------------ | ------------------ |
| 1                | 5              | 10 citations       | 4                  |
| 3                | 5              | 10 citations       | 2                  |
| 3                | 5              | 0                  | 5                  |

### Requirement: Orphaned anchors do not influence ranking

A strategy SHALL ignore projection entries whose anchors dereference as orphaned. Such entries SHALL NOT contribute reinforcement or suppression, and SHALL NOT cause the invocation to fail.

#### Scenario: Orphaned history is inert

- **GIVEN** a projection in which the most heavily reinforced anchor is orphaned
- **WHEN** the `human-like` strategy is invoked
- **THEN** that anchor receives no promotion and the invocation completes normally

### Requirement: Strategies are distinguished by the signals they consume

A strategy SHALL be defined by which event kinds it consumes, not by the magnitude of the adjustment it applies. The `archival` strategy consumes no event kinds. The `human-like` strategy consumes `opened`, `cited`, `pinned`, and `dismissed`. Introducing a further strategy SHALL require naming a distinct signal set, and SHALL NOT be achieved by supplying a different displacement bound to an existing strategy.

#### Scenario: Two bounds do not constitute two strategies

- **WHEN** the `human-like` strategy is constructed with two different displacement bounds
- **THEN** both constructions report the same strategy identity, differing only in configuration
