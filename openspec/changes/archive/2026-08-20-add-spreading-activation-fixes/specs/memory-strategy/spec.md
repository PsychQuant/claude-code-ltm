## MODIFIED Requirements

### Requirement: The human-like tier spreads reinforcement to co-presented anchors, one hop only

`human-like` SHALL treat anchors that were presented together in the same presentation group as connected: when a deliberate reinforcing event (`opened`, `cited`, or `pinned`) occurs on an anchor, every other live anchor presented in the same group SHALL receive a fraction of that event's decayed reinforcement, in addition to any reinforcement that anchor accrues from its own event history. This spreading SHALL NOT apply to `dismissed` events, and a spread contribution received by an anchor SHALL NOT itself be further spread to other anchors.

Spreading is a property of the `human-like` tier only. No other shipped strategy SHALL receive spreading-derived reinforcement, regardless of which event kinds it otherwise consumes. In particular, `conservative` consumes the same four event kinds as `human-like` (see "Strategies are distinguished by mechanism, never by magnitude") but SHALL NOT receive spreading contributions — sharing a signal set does not imply sharing every mechanism gated on that signal set.

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

#### Scenario: Conservative does not receive spreading reinforcement despite sharing human-like's signal set

- **GIVEN** a presentation group of two anchors projected under `conservative`, where one anchor is deliberately opened and the other has only a `shown` event and no other events
- **WHEN** `conservative`'s projection is used to rank the group
- **THEN** the anchor with only a `shown` event shows zero reinforcement, unlike the same scenario projected for `human-like`
