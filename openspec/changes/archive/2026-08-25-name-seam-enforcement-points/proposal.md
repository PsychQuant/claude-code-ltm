## Summary

Rewrite the `memory-strategy` requirement that says retrieval SHALL NOT read the event store and no strategy SHALL read the corpus, so that it names the enforcement points that actually exist instead of implying a compile-time guarantee that the type system cannot provide.

## Motivation

`openspec/specs/memory-strategy/spec.md` states, inside "MemoryStrategy is the sole seam between retrieval and memory":

> Retrieval SHALL NOT read the event store directly, and no strategy SHALL read the corpus directly.

Issue #14 recorded that a cross-model reviewer refuted the claim by execution: a test in `Tests/LTMQueryTests` that does not import `LTMMemory` wrote an event file and read it back using Foundation alone, and a second one reconstructed corpus text through the public `CorpusReader` and `Anchor.dereference(in:)`. Both passed.

The issue then proposed three directions and said any of them was acceptable but the status quo was not. Two of those three cannot deliver what they promise:

- Moving `Event`'s coded representation out of `LTMCore` removes a convenience type. Reading the event file needs `Data(contentsOf:)` and `JSONSerialization`, both in Foundation, against a JSON Lines format whose field names this specification itself publishes.
- Making `CorpusReader` and `Anchor.dereference(in:)` internal removes another convenience type, and the same substitution applies.

Neither refuting test used the types being proposed for removal, so neither would start failing. **A dependency graph controls API reachability, not capability.** In a language where a module can open a file, "do not read this file" has no expression at the type level.

What the requirement is actually protecting turns out to be two separate things, and each already has an enforcement point elsewhere:

- **Ordering correctness** is enforced by the seam, which performs seven checks on every invocation.
- **The privacy boundary** is enforced at the bytes that land, by the canonical store's round-trip comparison — a strategy reading corpus text is not the hazard; corpus text being written into the memory layer is.

So the correct change is not to chase a guarantee that cannot exist. It is to state what is enforced, where, and to record why the type-level version is unavailable — so the next reader does not propose the same two directions again.

## Proposed Solution

Rewrite the requirement so it separates the two purposes and names their enforcement points explicitly, enumerating rather than generalising:

1. Keep SHALL NOT, with the subject stated: it binds implementations, not the compiler. This matches how `memory-events` already uses the same form for its note-reference clause, which is likewise unenforceable at the type level.
2. Enumerate the seam's seven checks by name and by the violation each raises. Do not write a summarising criterion such as "the seam rejects non-conforming output" — a summarising criterion grows a case the enumeration never agreed to.
3. Name the privacy enforcement point as the canonical store's byte-level round-trip, and state that it is indifferent to what a strategy reads.
4. State that the type-level version is unavailable, and why, in enough detail that the removed-type proposals are visibly answered.
5. Record `ValidatedCandidates`'s internal initialiser as a deliberate trust boundary rather than an omission, in the same requirement, because it is what makes the seam's entry point unbypassable from outside the package.

Then align the source comments that currently assert the opposite so that they point at the rewritten requirement rather than each restating a rationale. Those comments live in four files, verified by search: the package manifest's target declarations, the query module's module note, the seam file's note on the validated-candidates type, and the strategy test file's module note. The fourth was found by the sweep task rather than by the initial survey, which is why the sweep task exists. A fourth site exists in an archived design document; archived artifacts record what was true when they were written and are not edited by this change.

## Non-Goals

- **Moving `Event`'s coded representation out of `LTMCore`.** Rejected: it removes a convenience type without removing the capability, so the claim it is meant to make true stays false while the dependency graph's lowest layer is disturbed.
- **Making `CorpusReader` or `Anchor.dereference(in:)` internal.** Rejected for the same reason.
- **Changing `ValidatedCandidates`'s initialiser visibility.** It is deliberate and stays; this change documents it rather than altering it.
- **Any runtime behaviour change.** No type visibility, no dependency edge, and no check in the seam is added, removed, or reordered by this change.
- **Resolving the wider self-report family.** Whether a strategy's reported identifier and displacement bound need an authority of their own is tracked in issues 37 and 38 and is not decided here.

## Alternatives Considered

- **Downgrade SHALL NOT to a stated convention with no enforcement point named.** Rejected: it would leave the reader believing nothing guards these boundaries, when the seam and the byte-level check both do. The defect is that the requirement names the wrong enforcement location, not that it names one at all.
- **Delete the sentence.** Rejected: the design intent is real and worth stating. Deleting it loses the reason the seam exists.
- **Leave the specification and only fix the source comments.** Rejected: the source comments currently defer to this requirement, so the specification is where the drift lives.

## Impact

- Affected specs: memory-strategy
- Affected code:
  - Modified:
    - openspec/specs/memory-strategy/spec.md
    - Package.swift
    - Sources/LTMQuery/Module.swift
    - Sources/LTMQuery/MemoryStrategy.swift
    - Tests/LTMQueryTests/MemoryStrategyTests.swift
  - New: (none)
  - Removed: (none)
