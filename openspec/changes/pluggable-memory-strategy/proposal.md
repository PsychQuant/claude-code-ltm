## Why

claude-LTM's retrieval layer currently has no way to express "should past usage influence ranking, and how much?" as a *choice*. The initial design hard-coded one answer (suppress usage effects to protect reproducibility), and that answer was smuggled in as a default rather than argued for. The properties it suppressed — rich-get-richer, availability bias, reconstructive drift — are exactly the properties of human memory, so suppressing them is not a bug fix but a selection of a different memory model. Making the strategy a parameter is what lets the two models be compared instead of assumed.

A second forcing function: the canonical store must hold usage history, which is the one thing the source jsonl cannot record. Its schema therefore has to be settled before any strategy can be written, and settling it is a privacy decision as much as a data-modelling one.

## What Changes

- Introduce an append-only **event store** as the canonical record of usage history, holding only pointers and statistics — never chunk text, never query strings.
- Introduce a stable **anchor** type addressing source turns by content, not by derived chunk identity, so the disposable index can be rebuilt without orphaning canonical records.
- Introduce a **`MemoryStrategy` seam**: one protocol that takes retrieval candidates plus an event projection and returns a re-ranked list with per-item displacement provenance.
- Ship three strategies: `archival` (identity — the null object and correctness oracle), `conservative` (acts only where base scores tie), and `human-like` (power-law decay and retrieval reinforcement).
- **Not shipped, and named as such:** the third `human-like` mechanism the issue asks for — spreading activation (Collins & Loftus, 1975; the issue calls it 共現擴散激發, and the Clarity Surface resolved that co-occurrence edges are one implementation variant of it) — is **absent from this change**. It needs a co-occurrence edge structure that the event schema does not yet carry, and building it would widen this change past the seam it is meant to define. Tracked as a follow-up. Earlier drafts of this proposal listed "co-retrieval association" among the shipped mechanisms; that was an overclaim, caught by the #1 verify on 2026-08-11 and corrected here.
- Ship an **interleaving comparison harness** that compares a pair of strategies on live usage rather than by replaying stored queries, since queries are deliberately not retained. It records a per-presentation **query class label** drawn from a closed five-value set — a statistic, not content — so results can be reported per class without storing a single query.
- **Corrected from an earlier draft of this proposal.** That draft removed `conservative` outright, arguing its defining rule ("strength acts only as a tie-breaker, capped at ±5%") was not expressible. Half of that argument holds: reciprocal-rank-fusion scores carry no cross-query semantics, so a percentage cap has no stable referent. The other half does not — "acts only as a tie-breaker" is perfectly expressible in this change's own vocabulary, and `human-like` does not contain it (a bound of zero yields no reordering, not tie-breaking). A half-true argument was used to support a universal conclusion; the tier is restored.

## Capabilities

### New Capabilities

- `memory-events`: append-only canonical record of retrieval interactions, addressed by stable anchors, storing pointers and statistics only.
- `memory-strategy`: the pluggable re-ranking seam plus its three shipped implementations, including displacement provenance on every returned item.
- `strategy-comparison`: interleaved evaluation of a pair of strategies over live usage, reported per query-class rather than in aggregate.

### Modified Capabilities

(none)

## Impact

- Affected specs: memory-events, memory-strategy, strategy-comparison
- Affected code:
  - New: Package.swift
  - New: Sources/LTMCore/Module.swift
  - New: Sources/LTMCore/Anchor.swift
  - New: Sources/LTMCore/CanonicalCoding.swift
  - New: Sources/LTMCore/Event.swift
  - New: Sources/LTMCore/OpaqueIdentifier.swift
  - New: Sources/LTMCore/Projection.swift
  - New: Sources/LTMMemory/Module.swift
  - New: Sources/LTMMemory/EventStore.swift
  - New: Sources/LTMMemory/Projection.swift
  - New: Sources/LTMQuery/Module.swift
  - New: Sources/LTMQuery/MemoryStrategy.swift
  - New: Sources/LTMQuery/RankingGuard.swift
  - New: Sources/LTMQuery/Strategies/ArchivalStrategy.swift
  - New: Sources/LTMQuery/Strategies/ConservativeStrategy.swift
  - New: Sources/LTMQuery/Strategies/HumanLikeStrategy.swift
  - New: Sources/LTMEval/Module.swift
  - New: Sources/LTMEval/QueryClass.swift
  - New: Sources/LTMEval/PresentationRecord.swift
  - New: Sources/LTMEval/Interleaving.swift
  - New: Sources/LTMEval/ComparisonReport.swift
  - New: Tests/LTMMemoryTests/AnchorTests.swift
  - New: Tests/LTMMemoryTests/AnchorRebuildTests.swift
  - New: Tests/LTMMemoryTests/CorpusContainmentTests.swift
  - New: Tests/LTMMemoryTests/EventStoreTests.swift
  - New: Tests/LTMMemoryTests/EventTests.swift
  - New: Tests/LTMMemoryTests/GuardPinningTests.swift
  - New: Tests/LTMMemoryTests/ModuleGraphTests.swift
  - New: Tests/LTMMemoryTests/PrivacyAdversarialTests.swift
  - New: Tests/LTMMemoryTests/ProjectionTests.swift
  - New: Tests/LTMQueryTests/ConservativeStrategyTests.swift
  - New: Tests/LTMQueryTests/DisplacementBoundTests.swift
  - New: Tests/LTMQueryTests/MemoryStrategyTests.swift
  - New: Tests/LTMQueryTests/ModuleGraphTests.swift
  - New: Tests/LTMQueryTests/OrphanReasonTests.swift
  - New: Tests/LTMQueryTests/RankingGuardTests.swift
  - New: Tests/LTMQueryTests/StrategyTests.swift
  - New: Tests/LTMEvalTests/ComparisonReportTests.swift
  - New: Tests/LTMEvalTests/InterleavingTests.swift
  - New: Tests/LTMEvalTests/InterleavingTerminationTests.swift
  - New: Tests/LTMEvalTests/ModuleGraphTests.swift
  - New: Tests/LTMEvalTests/QueryClassTests.swift
  - Modified: docs/memory-systems/README.md
  - Modified: CLAUDE.md
  - Removed: (none)

**Out-of-scope files this change also lands, declared rather than hidden.**
Running the Spectra workflow for the first time in this repository writes its own
scaffolding, and that scaffolding is now tracked. It has nothing to do with memory
strategy and it is about 2,500 lines:

- New: .spectra.yaml
- New: openspec/config.yaml
- New: .claude/settings.json
- New: .claude/skills/ (thirteen Spectra skill definition files)
- New: openspec/changes/pluggable-memory-strategy/ (this change's own artifacts)

An earlier draft of this section named a file that was never created
(Sources/LTMQuery/Candidate.swift — the type lives in Sources/LTMQuery/MemoryStrategy.swift),
listed nine of the twenty-one shipped source files, three of the twenty test files, and
omitted the scaffolding entirely (#1 verify R5). The list is now generated from what the
change actually contains. Impact lists are read by people deciding whether a change is
in scope; an incomplete one understates scope in exactly the direction that matters.
