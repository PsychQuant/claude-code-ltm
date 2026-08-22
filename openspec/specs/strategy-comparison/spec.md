# strategy-comparison Specification

## Purpose

Interleaved evaluation of a pair of strategies over live usage, reported per query-class rather than in aggregate.

## Requirements

### Requirement: Comparison is performed by interleaving, not by replaying stored queries

Two strategies SHALL be compared by having each produce a ranking for the same candidate list, presenting a single interleaved list to the user, and observing which side a subsequent interaction credits. The comparison mechanism SHALL NOT depend on retaining query text, and SHALL NOT require re-executing a historical query.

#### Scenario: Comparison runs without any stored query text

- **WHEN** a comparison is scored over a session's recorded interactions
- **THEN** the scoring reads only events, presentation records, and projections, and reads no query text

#### Scenario: Interleaved list is a permutation of the union

- **GIVEN** two strategy rankings over the same candidate list
- **WHEN** the harness interleaves them
- **THEN** the presented list contains each candidate exactly once

---
### Requirement: Each presented position is attributed to exactly one strategy

The harness SHALL produce a presentation record whose attribution takes exactly one of two shapes. There are only these two, and no third shape SHALL be inferred by analogy:

1. **Attributed** — every presented anchor is credited to exactly one of the two strategies under comparison. This is the shape whenever the two rankings differ.
2. **Unattributed** — no presented anchor is credited to any strategy. This is the shape when, and only when, the two rankings are identical (a null comparison).

A record mixing the two SHALL be rejected at construction and at decoding. An earlier draft of this requirement stated the attributed shape as a universal, while the null-comparison scenario below required the unattributed shape; the two were contradictory as written. Mixing them also leaves the per-presentation rate without a defined denominator.

When both strategies would place the same anchor at the same rank within an attributed record, attribution SHALL be assigned deterministically from the presentation record's own ordering rather than left ambiguous.

#### Scenario: An interaction credits one side

- **GIVEN** an interleaved presentation of two differing rankings
- **WHEN** the user opens one of the presented results
- **THEN** the resulting credit is assigned to exactly one of the two strategies

#### Scenario: Identical rankings yield a null comparison

- **GIVEN** two strategies that produce identical rankings for a candidate list
- **WHEN** the harness interleaves them and an interaction is recorded
- **THEN** the comparison reports no preference between the two strategies rather than crediting one arbitrarily

---
### Requirement: Presentation records carry a query class label and no query text

A presentation record SHALL carry an opaque random presentation identifier, a query class label drawn from a closed set, the pair of strategy identifiers being compared, the generation identifier of the index build, the per-anchor attribution, and the interleaving's starting side. Interactions SHALL reference that presentation identifier so that scoring resolves credit exactly rather than by inference. The query class label SHALL be computed from the query at presentation time and the query text SHALL NOT be persisted. The closed set SHALL be: `cjk-2char`, `cjk-3char`, `cjk-4plus`, `latin-alnum`, `mixed`.

#### Scenario: Serialized presentation records contain no query text

- **WHEN** a store of presentation records is serialized in full
- **THEN** the serialized output contains none of the fixture query strings

#### Scenario: The starting side is recorded

- **WHEN** a presentation is produced with a given starting side
- **THEN** the record reports that same side

#### Scenario: Class label is assigned from a closed set

- **WHEN** a query is presented for comparison
- **THEN** the recorded class label is one of the five defined values

##### Example: Class assignment

| Query form                          | Class label   |
| ----------------------------------- | ------------- |
| Two-character CJK term              | `cjk-2char`   |
| Three-character CJK term            | `cjk-3char`   |
| Four-or-more-character CJK term     | `cjk-4plus`   |
| ASCII word or identifier            | `latin-alnum` |
| CJK and Latin runs in one query     | `mixed`       |

---
### Requirement: The interleaving's starting side is chosen by a reproducible balancing rule

The first presented position receives disproportionate attention, so the team-draft starting side is a known confound. The harness SHALL require the starting side as an explicit argument with no default, and SHALL offer a balancing rule that derives the side deterministically from a caller-supplied seed. That rule SHALL NOT depend on any per-process randomised hash, because a comparison report must be reproducible from its records.

Requiring the argument without offering the rule is insufficient: an earlier draft removed the default in order to eliminate a systematic bias toward the first strategy, but supplied no mechanism, so the most likely caller behaviour remained a hard-coded first side — with the bias intact and, because the side was not recorded, no longer visible.

#### Scenario: The balancing rule is stable across runs

- **WHEN** the balancing rule is applied to the same seed in two separate processes
- **THEN** both yield the same side

#### Scenario: The balancing rule splits evenly across structurally different seed families

- **WHEN** the balancing rule is applied to each of several structurally different seed families — sequential identifiers, even-numbered identifiers, seeds composed only of even-valued bytes, and CJK seeds
- **THEN** neither side takes more than three quarters of any family

  (An earlier wording required exactly half of two hundred sequential seeds. An avalanched hash meets that only by coincidence — about a one-in-eighteen chance — whereas the defective parity implementation met it necessarily. The exact figure was evidence of the bug, so the specification must not require it.)

#### Scenario: Reordering a seed can change the side it is assigned

- **WHEN** the balancing rule is applied to every permutation of a five-character seed
- **THEN** both sides occur

  (The defective implementation reduced to the parity of the seed's odd-valued bytes, which is invariant under reordering; every permutation landed on one side.)

---
### Requirement: An event is either scored, legitimately skipped, or rejected

When scoring, each interaction event SHALL fall into exactly one of **three** dispositions:

1. **Scored** — the event names a presentation present in the supplied records, that presentation is attributed, and the event's anchor is among its attributed anchors.
2. **Legitimately skipped** — exactly three cases, and no fourth: the event names no presentation at all (an interaction can originate outside a presented list); the event's presentation is a null comparison (required by the attribution rules above); or the event names a presentation that is absent from the supplied records.
3. **Rejected** — a data inconsistency; scoring SHALL fail loudly rather than skip. The causes are open to extension, and are currently: the named anchor was never attributed by an attributed presentation that IS present in the supplied records; the event's own generation disagrees with its presentation record's.

The set of *dispositions* is closed at three; the set of *rejection causes* is not, and adding one does not change the contract. An earlier draft of this requirement declared a closed four-way enumeration that folded the rejection causes into the top level, and the implementation written against it rejected on a third cause twelve lines below its own closed-enumeration comment. Enumerate the axis that is genuinely closed, not the one that will grow.

**"Presentation absent from supplied records" moved from Rejected to Legitimately skipped.** `PresentationID` is a randomly generated identifier that every recording query now attaches to its events (not only events originating from a formal comparison run), because a separate mechanism — spreading activation — depends on the same identifier to group co-presented anchors. As a structural consequence, most events naming a presentation absent from the supplied records are now ordinary production interactions that were never part of any comparison, not evidence of a broken harness. Because `PresentationID` is UUID-backed, collision between an unrelated production presentation and a genuinely-missing comparison record is not distinguishable by this check, and the two cases are no longer told apart: a comparison harness that generates a presentation, writes events against it, but fails to persist the matching record would previously have been caught here and is no longer caught by this requirement. This is an accepted, documented reduction in detection power, not an oversight — recovering it would require giving presentation identifiers used for comparison a distinguishable identity from those used only for spreading, which is out of scope for the change that introduced this trade-off.

Record-level validation runs before any event is scored and SHALL reject: a duplicated presentation identifier, an attribution naming a strategy outside the compared pair, the same anchor appearing twice in one presentation, and records that do not all compare the same pair of strategies.

The report SHALL carry the count of each legitimate skip so that the size of the scored population is readable from the report itself. An earlier implementation collapsed everything into a single silent skip, so a missing presentation record deflated the denominator with no trace in the output.

#### Scenario: An event naming a presentation absent from the supplied records is legitimately skipped

- **GIVEN** an event whose presentation identifier appears in no supplied record
- **WHEN** the report is computed
- **THEN** scoring succeeds and the event is counted among the legitimate skips, not rejected

#### Scenario: An event naming an anchor the presentation never showed is rejected

- **GIVEN** an attributed presentation that IS present in the supplied records, and an event referencing it with an anchor absent from its attribution
- **WHEN** the report is computed
- **THEN** scoring fails and names the presentation and the anchor

#### Scenario: Records comparing different strategy pairs are rejected

- **GIVEN** one presentation record comparing A with B and another comparing B with C
- **WHEN** a single report is computed over both
- **THEN** scoring fails rather than presenting the three strategies in one table

#### Scenario: Two strategies with the same identifier cannot be interleaved

- **GIVEN** two strategy instances that report the same policy identifier
- **WHEN** the harness is asked to interleave them
- **THEN** the invocation fails, because attribution is recorded per identifier and would credit neither side distinguishably

#### Scenario: Legitimate skips are counted

- **GIVEN** one event with no presentation, one event belonging to a null comparison, and one event naming a presentation absent from the supplied records
- **WHEN** the report is computed
- **THEN** the report reports one skip of each of the three kinds


<!-- @trace
source: add-spreading-activation-fixes
updated: 2026-08-20
code:
  - Tests/LTMServiceTests/LTMServiceTests.swift
  - Sources/ltm/Commands.swift
  - Tests/LTMEvalTests/ComparisonReportTests.swift
  - Sources/LTMQuery/Strategies/HumanLikeStrategy.swift
  - Sources/LTMService/LTMService.swift
  - Sources/LTMQuery/MemoryStrategy.swift
  - Sources/LTMEval/ComparisonReport.swift
  - Sources/LTMMemory/Projection.swift
  - CHANGELOG.md
  - Tests/LTMMemoryTests/ProjectionTests.swift
  - Tests/LTMServiceTests/CLICommandTests.swift
-->

---
### Requirement: Comparison results are reported per query class

A comparison report SHALL present per-class results alongside any aggregate figure. A report SHALL NOT present an aggregate figure alone. Each class SHALL carry its observation count so that classes with too few observations are visible as such.

#### Scenario: Aggregate alone is refused

- **WHEN** a comparison report is produced
- **THEN** the report contains one row per query class present in the data, each with its observation count

#### Scenario: A class-local effect is not washed out

- **GIVEN** a comparison in which one strategy wins decisively within a single class and ties in every other class
- **WHEN** the report is produced
- **THEN** the winning class shows the decisive result, and the aggregate row does not replace it

---
### Requirement: Comparison credits only deliberate interactions

Scoring SHALL credit a strategy on `opened`, `cited`, and `pinned` events, and SHALL count `dismissed` events against the crediting strategy. Scoring SHALL NOT credit a strategy on `shown` events. The `shown` count SHALL be used as the denominator when reporting per-presentation rates.

#### Scenario: Impressions form the denominator, not the numerator

- **GIVEN** a class in which one strategy contributed twice as many presented positions as the other
- **WHEN** per-presentation rates are reported
- **THEN** each strategy's rate is computed against its own presented count rather than against the total interaction count

---
### Requirement: Comparison spanning index generations is reported as such

When the events scored for a comparison span more than one generation identifier, the report SHALL state that the comparison spans generations and SHALL break results down by generation. Results from different generations SHALL NOT be silently pooled into a single figure.

#### Scenario: Mixed-generation data is flagged

- **GIVEN** recorded events carrying two distinct generation identifiers
- **WHEN** a comparison report is produced over those events
- **THEN** the report states that the data spans generations and reports each generation separately

---
### Requirement: Retrieval quality is scored as a two-stage recall-then-ranking metric

A retrieval result against a known expected anchor SHALL be scored in two stages: first, whether the expected anchor appears among the top-20 retrieved results (recall); second, only when recall succeeds, the normalized discounted cumulative gain of the expected anchor's position among the top-10 results (nDCG@10). A result that fails the recall stage SHALL be reported as a distinct outcome from a result that recalls but ranks the expected anchor poorly, and SHALL NOT be assigned a numeric ranking-quality score.

#### Scenario: A missing anchor is distinguished from a poorly-ranked one

- **GIVEN** two retrieval results for two different queries, one where the expected anchor is absent from the top 20 and one where it is present at rank 15
- **WHEN** both are scored
- **THEN** the first is reported as not recalled, and the second is reported as recalled with a numeric nDCG@10 value strictly less than a result that ranks the expected anchor first

##### Example: Two-stage scoring outcomes

| Retrieved top-20 contains expected anchor at rank | Outcome |
| --- | --- |
| absent | not recalled (no nDCG@10 value) |
| 1 (best possible) | recalled, nDCG@10 = 1.0 |
| 10 | recalled, nDCG@10 between 0 and 1, strictly less than the rank-1 case |

#### Scenario: An empty result list is scored as not recalled

- **GIVEN** an empty retrieved list and any expected anchor
- **WHEN** the result is scored
- **THEN** the outcome is not recalled

---
### Requirement: Retrieval quality is reported per channel as well as fused

Given a query with an expected anchor, the two-stage recall-then-ranking outcome SHALL be computed separately for the lexical-only retrieved list, the vector-only retrieved list, and the fused retrieved list, using the same scoring function for all three. A report presenting a fused-channel outcome SHALL also present the lexical-only and vector-only outcomes for the same query.

This second sentence is **conditional, and no shipped report type presents a fused-channel outcome yet** — `ComparisonReport` carries interleaving preference scores, not recall/ranking outcomes, because those need the `(query, expected turn)` ground-truth set that this capability explicitly does not build (see "Negative cases are not collected" and the honesty boundary in `CLAUDE.md`). So the requirement is satisfied vacuously today. It is stated here rather than deferred because the shape it constrains — three tracks scored by one function, never three pipelines — is a decision already made, and a reader who finds no per-channel field in `ComparisonReport` should be able to tell that from this specification rather than infer it (#16 verify).

#### Scenario: Single-channel degradation is visible in the per-channel breakdown

- **GIVEN** a query where the lexical channel fails to recall the expected anchor but the vector channel and the fused channel both recall it
- **WHEN** the three-channel breakdown is reported
- **THEN** the report shows lexical as not recalled while vector and fused are both recalled, rather than only a fused-channel figure

---
### Requirement: Reported comparisons correct for starting-side imbalance

When a comparison report is produced, the report SHALL include a starting-side-corrected preference estimate derived from a model fit across all scored observations for that report, in addition to the raw starting-side counts already required. The corrected estimate SHALL NOT be computed by splitting observations into per-side subsets and reporting each subset's rate independently.

#### Scenario: A corrected estimate accompanies an imbalanced starting-side count

- **GIVEN** 100 scored presentations for a comparison, 60 of which started with strategy A and 40 with strategy B
- **WHEN** the comparison report is produced
- **THEN** the report includes both the raw 60/40 starting-side counts and one starting-side-corrected preference estimate derived from all 100 observations

#### Scenario: A degenerate starting-side distribution yields no corrected estimate

- **GIVEN** every scored presentation for a comparison started with the same side
- **WHEN** the comparison report is produced
- **THEN** the report states that no starting-side correction is computable rather than presenting a number derived from a one-sided fit

---
### Requirement: The query-class label set is validated only for Chinese and English input

The five-value closed query-class set (`cjk-2char`, `cjk-3char`, `cjk-4plus`, `latin-alnum`, `mixed`) SHALL remain unchanged by this capability. A query composed of characters outside the Han script and the ASCII alphanumeric range — Japanese kana, Hangul, Cyrillic, and similarly — SHALL classify as `latin-alnum` under the existing classification rule, and this classification SHALL NOT be treated as validated: no measurement establishes that `latin-alnum` reporting is meaningful for such queries.

#### Scenario: A non-CJK, non-Latin query still classifies but is not claimed to be measured

- **GIVEN** a query composed entirely of Hangul characters
- **WHEN** the query is classified
- **THEN** it classifies as `latin-alnum` under the existing rule, and no report or documentation SHALL describe `latin-alnum` results as validated for that query's script

---
### Requirement: Negative cases are not collected

This capability SHALL NOT **collect** negative cases from real usage — that is, it SHALL NOT retain, from a live session, the information needed to reconstruct a query for which the user expected a specific anchor and the system failed to retrieve it. The no-query-text policy governing presentation records makes such collection impossible without retaining either the query text or a substitute carrying comparable information, and no such substitute is defined by this capability. The evaluation population is therefore known to exclude event-log-invisible retrieval failures, and this exclusion SHALL be treated as a stated, accepted limitation rather than a defect to be silently worked around.

**The prohibition is on collection, not on the concept.** Scoring a retrieval outcome as *not recalled* is required elsewhere in this specification (see "Retrieval quality is scored in two stages, recall first") and is exercised by synthetic fixtures that construct an expected anchor together with a retrieved list that omits it. Those fixtures are in scope and always were.

An earlier wording of this requirement said the capability "SHALL NOT attempt to **construct or score** negative cases", which the same commit's own scenario — "An empty result list is scored as not recalled" — violates verbatim, as does every `.notRecalled` fixture in the test suite. The defect was the one `common-spec-prose-enumeration` describes: a specific set of cases (real failure queries, invisible to the event log) written up as a general criterion whose literal reach is wider than the set the author had in mind, so it grew an answer at a boundary nobody checked — here, inside its own change (#16 verify).

#### Scenario: A comparison report does not claim to cover negative cases

- **WHEN** a comparison report or its accompanying documentation describes what the report measures
- **THEN** the description does not claim coverage of queries that returned no result, and states that such cases are excluded by design

##### Example: What the limitation statement looks like

- **GIVEN** a comparison report's accompanying documentation section describing capability coverage
- **WHEN** a reader looks for the phrase "negative case" or "zero-recall" in that section
- **THEN** the reader finds a sentence stating negative cases are excluded by design and why (the no-query-text policy), not silence or a claim of full coverage