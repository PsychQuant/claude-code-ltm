## MODIFIED Requirements

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
