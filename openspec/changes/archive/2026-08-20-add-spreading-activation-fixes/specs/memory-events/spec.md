## MODIFIED Requirements

### Requirement: Only deliberate interactions reinforce

Projection SHALL treat `opened`, `cited`, and `pinned` as reinforcing signals and `dismissed` as a suppressing signal. Projection SHALL NOT treat `shown` as a reinforcing signal. The `shown` kind SHALL remain recordable so that comparison can compute per-presentation rates.

This requirement describes an anchor considered in isolation from its presentation group. Spreading activation (see the `human-like` tier's spec in `memory-strategy`) is an explicit, documented exception at the group level, not a violation of this requirement: an anchor's own `shown` events never produce reinforcement, but when projection runs with `spreadingActivationFactor > 0` (which `memory-strategy` scopes to the `human-like` tier only — other strategies project with `spreadingActivationFactor` set to `0`, under which none of this section's scenarios apply), that anchor SHALL receive nonzero reinforcement derived from a *different* anchor's `opened`/`cited`/`pinned` event when both were shown together in the same presentation group, subject to the two exclusions below. Each individual spreading contribution SHALL be strictly less than the specific direct-interaction contribution it is derived from — `spreadingActivationFactor` SHALL be constrained to a value in `[0, 1)`, which guarantees this per-contribution. **This is a per-contribution guarantee only, not a bound on an anchor's total accumulated reinforcement**: an anchor co-presented in multiple presentation groups may receive multiple spreading contributions from different source events, and their sum is not bounded by any single direct-interaction contribution. An anchor that was itself the subject of a `dismissed` event SHALL NOT receive spreading reinforcement from a co-presented anchor's deliberate event. Spreading SHALL NOT apply within a presentation group whose live member count exceeds an implementation-defined cap; such groups are treated as anomalous rather than a source of unbounded amplification.

#### Scenario: Impressions alone produce no reinforcement, for an anchor untouched by spreading

- **GIVEN** an anchor with twenty `shown` events, no other events, and no anchor in any presentation group it belongs to has a deliberate (`opened`/`cited`/`pinned`) event
- **WHEN** the sequence is projected
- **THEN** the anchor's reinforcing statistics are equal to those of an anchor with no events at all

#### Scenario: A co-presented anchor with only `shown` events of its own gains reinforcement from the group

- **GIVEN** two anchors A and B shown together in the same presentation group, where A has an `opened` event and B has only a `shown` event and no other events
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
