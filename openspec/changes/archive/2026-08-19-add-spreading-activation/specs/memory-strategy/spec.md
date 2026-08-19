## ADDED Requirements

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

### Requirement: The human-like tier spreads reinforcement to co-presented anchors, one hop only

`human-like` SHALL treat anchors that were presented together in the same presentation group as connected: when a deliberate reinforcing event (`opened`, `cited`, or `pinned`) occurs on an anchor, every other live anchor presented in the same group SHALL receive a fraction of that event's decayed reinforcement, in addition to any reinforcement that anchor accrues from its own event history. This spreading SHALL NOT apply to `dismissed` events, and a spread contribution received by an anchor SHALL NOT itself be further spread to other anchors.

#### Scenario: A co-presented anchor with no direct interaction of its own gains reinforcement

- **GIVEN** a presentation group of three anchors, one of which is deliberately opened and the other two of which are never directly interacted with
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
