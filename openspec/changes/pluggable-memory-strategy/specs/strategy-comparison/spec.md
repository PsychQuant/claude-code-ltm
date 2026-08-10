## ADDED Requirements

### Requirement: Comparison is performed by interleaving, not by replaying stored queries

Two strategies SHALL be compared by having each produce a ranking for the same candidate list, presenting a single interleaved list to the user, and observing which side a subsequent interaction credits. The comparison mechanism SHALL NOT depend on retaining query text, and SHALL NOT require re-executing a historical query.

#### Scenario: Comparison runs without any stored query text

- **WHEN** a comparison is scored over a session's recorded interactions
- **THEN** the scoring reads only events, presentation records, and projections, and reads no query text

#### Scenario: Interleaved list is a permutation of the union

- **GIVEN** two strategy rankings over the same candidate list
- **WHEN** the harness interleaves them
- **THEN** the presented list contains each candidate exactly once

### Requirement: Each presented position is attributed to exactly one strategy

The harness SHALL produce a presentation record mapping each presented anchor to exactly one contributing strategy. When both strategies would place the same anchor at the same rank, attribution SHALL be assigned deterministically from the presentation record's own ordering rather than left ambiguous.

#### Scenario: An interaction credits one side

- **GIVEN** an interleaved presentation of two differing rankings
- **WHEN** the user opens one of the presented results
- **THEN** the resulting credit is assigned to exactly one of the two strategies

#### Scenario: Identical rankings yield a null comparison

- **GIVEN** two strategies that produce identical rankings for a candidate list
- **WHEN** the harness interleaves them and an interaction is recorded
- **THEN** the comparison reports no preference between the two strategies rather than crediting one arbitrarily

### Requirement: Presentation records carry a query class label and no query text

A presentation record SHALL carry an opaque random presentation identifier, a query class label drawn from a closed set, the pair of strategy identifiers being compared, the generation identifier of the index build, and the per-anchor attribution. Interactions SHALL reference that presentation identifier so that scoring resolves credit exactly rather than by inference. The query class label SHALL be computed from the query at presentation time and the query text SHALL NOT be persisted. The closed set SHALL be: `cjk-2char`, `cjk-3char`, `cjk-4plus`, `latin-alnum`, `mixed`.

#### Scenario: Serialized presentation records contain no query text

- **WHEN** a store of presentation records is serialized in full
- **THEN** the serialized output contains none of the fixture query strings

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

### Requirement: Comparison results are reported per query class

A comparison report SHALL present per-class results alongside any aggregate figure. A report SHALL NOT present an aggregate figure alone. Each class SHALL carry its observation count so that classes with too few observations are visible as such.

#### Scenario: Aggregate alone is refused

- **WHEN** a comparison report is produced
- **THEN** the report contains one row per query class present in the data, each with its observation count

#### Scenario: A class-local effect is not washed out

- **GIVEN** a comparison in which one strategy wins decisively within a single class and ties in every other class
- **WHEN** the report is produced
- **THEN** the winning class shows the decisive result, and the aggregate row does not replace it

### Requirement: Comparison credits only deliberate interactions

Scoring SHALL credit a strategy on `opened`, `cited`, and `pinned` events, and SHALL count `dismissed` events against the crediting strategy. Scoring SHALL NOT credit a strategy on `shown` events. The `shown` count SHALL be used as the denominator when reporting per-presentation rates.

#### Scenario: Impressions form the denominator, not the numerator

- **GIVEN** a class in which one strategy contributed twice as many presented positions as the other
- **WHEN** per-presentation rates are reported
- **THEN** each strategy's rate is computed against its own presented count rather than against the total interaction count

### Requirement: Comparison spanning index generations is reported as such

When the events scored for a comparison span more than one generation identifier, the report SHALL state that the comparison spans generations and SHALL break results down by generation. Results from different generations SHALL NOT be silently pooled into a single figure.

#### Scenario: Mixed-generation data is flagged

- **GIVEN** recorded events carrying two distinct generation identifiers
- **WHEN** a comparison report is produced over those events
- **THEN** the report states that the data spans generations and reports each generation separately
