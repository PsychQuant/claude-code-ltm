## Context

`Sources/LTMMemory/Projection.swift`'s `project(...)` currently folds an event sequence into per-anchor `reinforcement`/`suppression` using two of the three mechanisms `human-like` was specified to have: power-law decay and per-event-kind weighting. The third — co-occurrence spreading activation (Collins & Loftus 1975; the specific variant here is presentation-level co-occurrence, per the spectra-discuss decision recorded on issue #15) — has no implementation and no supporting data.

Investigating the data dependency surfaced an upstream gap: `LTMService.record(...)`, the only production writer of `.shown` events, always passes `presentation: nil`. Per `memory-events` spec's Requirement ("Event records carry pointers and statistics only"), the presentation identifier "names the presentation the interaction originated in" — every query result list is such a presentation, so the field being permanently unset for real queries under-delivers on the spec's own definition. This change closes that gap as a precondition for spreading activation.

## Goals / Non-Goals

**Goals:**

- Give every `.shown` event written by `LTMService.query(...)` a presentation identifier grouping it with the rest of that query's result list.
- Surface that identifier on `QueryHit` so a future deliberate-event writer (not built in this change) can tag interactions with the correct group.
- Implement one-hop, presentation-co-occurrence spreading activation in `project(...)`: a deliberate reinforcement event on anchor A spreads a fraction of its (decayed) weight to every other live anchor co-presented with A in the same presentation group.

**Non-Goals:**

- No new API for recording deliberate events — `EventStore.append(_:)` already accepts a fully-constructed `Event` including its `presentation` field; any future caller (Stage 2 MCP, #24) uses that existing path.
- No calibration of the spreading factor against real data — no evaluation dataset exists (see #16's Non-Goals for the same constraint on the `strategy-comparison` capability).
- No multi-hop diffusion — spreading is exactly one hop; a co-presented anchor's received spread is not itself further spread.
- No spreading on `dismissed`/suppression — only reinforcement (`opened`/`cited`/`pinned`) spreads. Suppression spreading would claim "anchors co-presented with something the user dismissed are also worse," a materially stronger and separately-debatable claim not evaluated here.

## Decisions

### The presentation identifier is generated once per `query()` call, in `record(...)`

`LTMService.record(kind:anchors:policy:store:now:)` (`LTMService.swift:418`) currently loops over `anchors` and writes one `Event` per anchor, all sharing the same `generation`. It gains a `presentation: PresentationID?` parameter — `nil` when the caller has no group to record under, otherwise applied to every `Event` in the batch. `query(...)`'s only call site (`LTMService.swift:346`, recording `.shown` for every hit) generates `PresentationID.random()` once, before the loop, whenever `recordEvents && eventStore != nil`.

**Why generate in `query()`, not in `record(...)` itself**: `record(...)` is a generic batch-writer (kind is a parameter); it has no way to know whether a batch represents "one presentation" without being told. `query(...)` is the only call site that knows a batch of hits came from one coherent result list.

**Alternative considered and rejected**: reusing `GenerationID` for this purpose (it's already threaded through every event). Rejected because `GenerationID` names the index build, not one query call — many queries share one generation, so grouping by it would merge unrelated presentations into one enormous, meaningless co-occurrence set.

### `QueryHit` carries the presentation identifier as `presentation: PresentationID?`

Optional because it mirrors `recordEvents`: when the caller didn't ask to record, there is no group to reference. A future consumer (e.g. Stage 2 MCP) reads `hit.presentation`, and when the user later interacts with `hit.anchor`, constructs `Event(kind: .opened, anchor: hit.anchor, ..., presentation: hit.presentation)` and calls `eventStore.append(_:)` directly — no new service-layer API.

**Alternative considered and rejected**: adding a dedicated `LTMService.recordInteraction(...)` convenience method now, ahead of having any caller. Rejected as speculative surface — `EventStore.append` already does the job; building a wrapper with no consumer risks guessing the wrong shape for what #24's MCP tool will actually need.

### Spreading activation is a second pass over `project(...)`'s existing per-event loop, not a rewrite of it

`project(...)` keeps its existing single pass computing direct `reinforcement`/`suppression`/`impressions`/`counts` unchanged. A second, new pass:

1. Builds `presentationGroups: [PresentationID: Set<Anchor>]` from every event carrying a non-nil `presentation` (any kind — `.shown` populates most of it in practice, since that is the only kind with a production writer today, but the pass does not special-case kind).
2. For every event of kind `.opened`, `.cited`, or `.pinned` on anchor A with `presentation == G` and `isLive(A)`: for every other anchor B in `presentationGroups[G]` where `B != A` and `isLive(B)`, add `parameters.spreadingActivationFactor * (event's own decayed weight contribution)` to `reinforcement[B]`.

Spreading contributions use the *same* decay value already computed for the source event (age relative to `instant`, same `decayExponent`) — a spread contribution is not independently aged.

**Why a second pass over a rewrite**: the existing single-pass loop is small, already carries the future-dated / orphan-filtering discipline this repo has hardened repeatedly (`futureDated` counting, `isLive` caching), and re-deriving that discipline inside a fused single pass risks silently dropping one of those checks for the new code path. A second pass that reuses the same `isLive` cache and the same per-event decay calculation keeps the existing pass's correctness intact and makes the addition auditable as its own unit.

**Alternative considered and rejected**: computing spreading from `PresentationRecord` (LTMEval's richer per-presentation structure, which already models attribution). Rejected because `LTMMemory` does not and should not depend on `LTMEval` (`LTMEval` depends on `LTMMemory`, not the reverse — see `Package.swift`'s dependency comments); building spreading activation on `PresentationRecord` would only work for the A/B comparison path, not real single-strategy usage, which is exactly the audience `human-like` serves in production.

### `spreadingActivationFactor` is a new, explicitly-unvalidated `ProjectionParameters` field

Default value carried over from `PsychQuant/ai4o`'s spreading-activation configuration (exact figure decided during implementation by reading that source, since it is not yet known at design time), documented with the same "unvalidated, calibrated on a different corpus" disclaimer as the four existing weight parameters. Validated the same way as the others: `precondition(value.isFinite && value >= 0)` at construction — a negative or non-finite factor is a programmer error, not a data problem.

## Implementation Contract

**Behavior**:
- `LTMService.query(text:limit:scope:recordEvents:)`, when `recordEvents` is true and an `eventStore` is configured, generates one `PresentationID` and attaches it to every `.shown` event written for that call's hits. `QueryHit.presentation` carries that same identifier (nil when recording was off).
- `project(...)`'s output `Projection` reflects spreading: an anchor that received no direct deliberate interaction of its own, but was co-presented with an anchor that did, has non-zero `reinforcement` in the resulting `AnchorStatistics` (previously, such an anchor's statistics would either be absent from `Projection.statistics` or show zero reinforcement).

**Interface / data shape**:
- `LTMService.record(kind:anchors:policy:store:now:presentation:)` — new `presentation: PresentationID?` parameter, default `nil` for source compatibility with any other future caller that doesn't have a group.
- `QueryHit.presentation: PresentationID?` — new field, inserted alongside the existing pointer fields.
- `ProjectionParameters.spreadingActivationFactor: Double` — new field with a documented default; existing `ProjectionParameters.default` and all explicit-argument call sites continue to compile (Swift memberwise-style `init` keeps existing parameter names, adds the new one with a default value so no call site is forced to change).

**Failure modes**:
- `spreadingActivationFactor` non-finite or negative: `precondition` failure at `ProjectionParameters` construction (programmer error, same discipline as the four existing parameters).
- A presentation group with only one live anchor (the deliberately-interacted one, no co-presented anchors, or all co-presented anchors orphaned): spreading pass contributes nothing — this is a normal, silent no-op, not an error.
- An event carrying a `presentation` identifier that appears nowhere else in the event sequence (e.g. only one event was ever recorded for that presentation): the group has one member; spreading contributes nothing to it, same as above.

**Acceptance criteria**:
- `Tests/LTMServiceTests/LTMServiceTests.swift`: a test recording two queries confirms each call's `.shown` events share one `presentation` identifier among themselves and a *different* identifier from the other call's events; confirms `QueryHit.presentation` matches what was written to the event store.
- `Tests/LTMMemoryTests/ProjectionTests.swift`: a synthetic-fixture test constructs events for a presentation group of 3+ anchors, deliberately interacts with one, and asserts the co-presented anchors show nonzero `reinforcement` scaled by `spreadingActivationFactor`, while an anchor from a *different* presentation group with no direct interaction shows zero. A second test confirms one-hop-only: a co-presented anchor's received spread does not itself propagate to a third anchor. A third test confirms `dismissed` events do not spread.

**Scope boundaries**: In scope — presentation identifier generation and threading (`LTMService`), the new `ProjectionParameters` field, the spreading pass in `project(...)`. Out of scope — any new public API for recording deliberate interactions, calibrating the default factor, multi-hop diffusion, suppression spreading.

## Risks / Trade-offs

- [Every `.shown` event now carries a presentation identifier where it previously carried `nil` — any existing test or downstream consumer that pattern-matches on `presentation == nil` to distinguish "real query" from "comparison" traffic will see a behavior change] → Mitigation: grep-confirmed the only other producer of non-nil `presentation` values is `LTMEval`'s `InterleavingHarness`, a structurally separate code path (different `PresentationID` values, never mixed with `LTMService.query()` output in the same event store in practice); no consumer in this repo currently branches on `presentation == nil` as a load-bearing check (confirmed by grep before writing this design).
- [The spreading pass adds a second O(events × presentation-group-size) traversal to `project(...)`, which currently runs once per query when `human-like` is selected] → Mitigation: presentation groups are bounded by query result size (currently `limit`, typically ≤ 20), so the added cost per query is small; if this becomes a real bottleneck once #24's MCP path generates production volume, that is a measurable, addressable follow-up, not a blocking concern now (no evaluation data exists yet to know if it matters).
- [`spreadingActivationFactor`'s default is unvalidated, same as the four existing parameters — adding a fifth unvalidated number compounds the "no evidence for any of these values" honesty-boundary debt] → Mitigation: this is the same debt the existing parameters already carry and CLAUDE.md already requires disclosing; not a new category of risk, just one more instance of a documented, accepted one.

## Open Questions

- Exact default value for `spreadingActivationFactor` — decided during implementation by reading `PsychQuant/ai4o`'s spreading-activation configuration (the design defers to whatever that source's convention is, consistent with how the four existing `ProjectionParameters` defaults were sourced).

## Errata (added by add-spreading-activation-fixes, 2026-08-19)

Two claims above did not hold once implemented, surfaced by `/idd-verify #15`:

- **The Open Questions entry's provenance claim is false.** No spreading-activation-specific configuration was found in `PsychQuant/ai4o`'s `docs/memory/implementation/` (that repo's recall-boost mechanism is not the same thing as the co-presentation spreading built here). The shipped default (`spreadingActivationFactor: 0.3`) is a self-chosen estimate, unvalidated on this corpus, not sourced from AI4o like the other four `ProjectionParameters` defaults. See the code comment on `ProjectionParameters.spreadingActivationFactor` in `Sources/LTMMemory/Projection.swift` for the honest record.
- **The Risks section's "grep-confirmed" mitigation for line 79 is false.** `Sources/LTMEval/ComparisonReport.swift`'s `ComparisonScorer` does branch on `presentation == nil` as a load-bearing check — it is exactly the consumer this mitigation claimed did not exist. Every recording query now carries a non-nil `presentation` (this design's own change), and `ComparisonScorer` originally treated any non-nil `presentation` it could not resolve to a `PresentationRecord` as a data-inconsistency error, which production queries triggered systematically.

Both defects, and three others found by the same verify pass (spreading leaking into `conservative` via the shared `project()`; the existing `memory-events` "Only deliberate interactions reinforce" Requirement needing an explicit spreading exception; a pre-existing regression test unable to exercise the new code path), are fixed in `add-spreading-activation-fixes`. This note is appended, not a rewrite — the content above is left as originally written.
