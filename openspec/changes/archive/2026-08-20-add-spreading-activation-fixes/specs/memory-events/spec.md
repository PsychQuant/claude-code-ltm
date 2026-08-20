## MODIFIED Requirements

### Requirement: Only deliberate interactions reinforce

Projection SHALL treat `opened`, `cited`, and `pinned` as reinforcing signals and `dismissed` as a suppressing signal. Projection SHALL NOT treat `shown` as a reinforcing signal. The `shown` kind SHALL remain recordable so that comparison can compute per-presentation rates.

This requirement describes an anchor considered in isolation from its presentation group. Spreading activation (see the `human-like` tier's spec in `memory-strategy`, including that spec's Known-gap note on the comparison harness) is an explicit, documented exception at the group level, not a violation of this requirement, and applies only when projection runs with `spreadingActivationFactor > 0`. When it applies: an anchor's own `shown` events never produce reinforcement, but that anchor SHALL receive nonzero reinforcement derived from a *different* anchor's `opened`/`cited`/`pinned` event — provided that source event's own (decay-adjusted) contribution is positive — when both were shown together in the same presentation group, subject to the two exclusions below. Each individual spreading contribution, when its source contribution is positive, SHALL be strictly less than that specific direct-interaction contribution — `spreadingActivationFactor` SHALL be constrained to a value in `[0, 1)`, which guarantees this per-contribution. Neither guarantee holds when the source event's own weight (`openedWeight`/`citedWeight`/`pinnedWeight`) is configured to `0`: the direct contribution itself is then `0`, and there is no positive amount to derive a nonzero, strictly-smaller contribution from — this is an expected consequence of a `0` weight, not a violation. **The per-contribution guarantee, where it applies, is not a bound on an anchor's total accumulated reinforcement**: an anchor co-presented in multiple presentation groups may receive multiple spreading contributions from different source events, and their sum is not bounded by any single direct-interaction contribution. An anchor that was itself the subject of a `dismissed` event SHALL NOT receive spreading reinforcement from a co-presented anchor's deliberate event. Spreading SHALL NOT apply within a presentation group whose live member count exceeds an implementation-defined cap; such groups are treated as anomalous rather than a source of unbounded amplification.

#### Scenario: Impressions alone produce no reinforcement, for an anchor untouched by spreading

- **GIVEN** an anchor with twenty `shown` events, no other events, and no anchor in any presentation group it belongs to has a deliberate (`opened`/`cited`/`pinned`) event
- **WHEN** the sequence is projected
- **THEN** the anchor's reinforcing statistics are equal to those of an anchor with no events at all

#### Scenario: A co-presented anchor with only `shown` events of its own gains reinforcement from the group

- **GIVEN** two anchors A and B shown together in the same presentation group, where A has an `opened` event whose (decay-adjusted) contribution is positive (i.e. `openedWeight > 0`), and B has only a `shown` event and no other events
- **WHEN** the sequence is projected
- **THEN** B's reinforcement is nonzero, and B's reinforcement is strictly less than A's reinforcement

##### Example: spreading factor scales the derived contribution

- **GIVEN** A's `opened` event contributes reinforcement of 1.0 (decay-adjusted) and the configured `spreadingActivationFactor` is 0.3
- **WHEN** B (co-presented with A, no direct interaction of its own) is projected
- **THEN** B's reinforcement is 0.3

#### Scenario: A dismissed anchor does not receive spreading reinforcement from a co-presented opened anchor

- **GIVEN** a presentation group of two anchors, where anchor A is deliberately opened and anchor B has a `dismissed` event of its own
- **WHEN** the sequence is projected
- **THEN** B's reinforcement remains zero despite being co-presented with A

#### Scenario: An oversized presentation group does not spread

- **GIVEN** a presentation group whose live member count exceeds the implementation-defined cap, where one member has an `opened` event and another member has only a `shown` event
- **WHEN** the sequence is projected
- **THEN** the member with only a `shown` event shows zero reinforcement
