## Why

Issue #1's original `Expected` for `human-like` called for three mechanisms: power-law decay, retrieval reinforcement, and co-occurrence spreading activation. Only the first two are implemented (`Sources/LTMMemory/Projection.swift`). The third is entirely absent — `HumanLikeStrategy` has no edge structure, no adjacency, no diffusion. `docs/memory-systems/README.md` and `proposal.md` from the original change once claimed the mechanism had shipped; that over-claim was already corrected by a prior verify round, but the underlying gap remains open.

Closing this gap also requires fixing an upstream gap discovered during design: `LTMService.record(...)` — the only production path that writes `.shown` events — always sets `Event.presentation` to `nil`. Per the `memory-events` spec's own definition ("an optional presentation identifier naming the presentation the interaction originated in"), every query result list IS a presentation; the field being unset for real queries is an incompleteness relative to the spec's stated intent, not a deliberate restriction to the A/B comparison path. Spreading activation needs to know which anchors were shown together, and that grouping does not currently exist anywhere in the event log for real usage.

## What Changes

- `LTMService.query(...)` generates one `PresentationID` per query call (when event recording is active) and attaches it to every recorded `.shown` event for that query's hit list, closing the presentation-identifier gap described above.
- `QueryHit` exposes this presentation identifier so a future caller (e.g. the Stage 2 MCP server, tracked in #24) can tag a later deliberate interaction (`opened`/`cited`/`pinned`/`dismissed`) with the same identifier via the existing `EventStore.append` API — no new recording API is introduced by this change; the low-level append path already supports it.
- `ProjectionParameters` gains a `spreadingActivationFactor` — an unvalidated, explicitly-marked parameter controlling how much of a deliberate event's reinforcement diffuses to anchors that were co-presented with it.
- `project(...)` (`Sources/LTMMemory/Projection.swift`) computes one-hop spreading: for every `opened`/`cited`/`pinned` event on anchor A within presentation group G, every other live anchor also `.shown` within G receives `spreadingActivationFactor` of A's decayed reinforcement contribution, in addition to (not replacing) its own direct reinforcement. Spreading does not apply to `dismissed`/suppression, and does not recurse past one hop.

## Non-Goals

- **Building the Stage 2 MCP server** (or any other production caller that records deliberate `opened`/`cited`/`pinned`/`dismissed` events) is out of scope — tracked separately in #24. This change makes the plumbing ready (presentation identifiers flow from query to `QueryHit`; `EventStore.append` already accepts a `presentation` argument for any event kind) but does not build a new caller.
- **Calibrating `spreadingActivationFactor`** against real usage is out of scope — no evaluation dataset exists yet (see #16's `strategy-comparison` capability, which now has the scoring infrastructure but not the ground-truth data). The default value is carried over from `PsychQuant/ai4o` and explicitly marked unvalidated, same discipline as the existing `ProjectionParameters` defaults.
- **Multi-hop diffusion** (recursing spreading activation past the anchors directly co-presented with a deliberately-interacted anchor) is out of scope — the effect of a co-presented anchor's own diffusion is not itself further diffused.
- **Reviving AI4o's "archive out of candidate set" mechanism** for low-strength memories remains out of scope — this is a prior, unrelated decision, not reopened here.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `memory-strategy`: `human-like` gains the third mechanism (spreading activation) alongside its existing decay and reinforcement Requirements; a new Requirement documents the presentation-identifier plumbing this depends on.

## Impact

- Affected specs: `openspec/specs/memory-strategy/spec.md`
- Affected code:
  - Modified: `Sources/LTMService/LTMService.swift` (presentation identifier generation + `QueryHit` field), `Sources/LTMMemory/Projection.swift` (`ProjectionParameters` + `project(...)`)
  - Tests: `Tests/LTMServiceTests/LTMServiceTests.swift`, `Tests/LTMMemoryTests/ProjectionTests.swift`
