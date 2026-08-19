## ADDED Requirements

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

### Requirement: Retrieval quality is reported per channel as well as fused

Given a query with an expected anchor, the two-stage recall-then-ranking outcome SHALL be computed separately for the lexical-only retrieved list, the vector-only retrieved list, and the fused retrieved list, using the same scoring function for all three. A report presenting a fused-channel outcome SHALL also present the lexical-only and vector-only outcomes for the same query.

#### Scenario: Single-channel degradation is visible in the per-channel breakdown

- **GIVEN** a query where the lexical channel fails to recall the expected anchor but the vector channel and the fused channel both recall it
- **WHEN** the three-channel breakdown is reported
- **THEN** the report shows lexical as not recalled while vector and fused are both recalled, rather than only a fused-channel figure

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

### Requirement: The query-class label set is validated only for Chinese and English input

The five-value closed query-class set (`cjk-2char`, `cjk-3char`, `cjk-4plus`, `latin-alnum`, `mixed`) SHALL remain unchanged by this capability. A query composed of characters outside the Han script and the ASCII alphanumeric range — Japanese kana, Hangul, Cyrillic, and similarly — SHALL classify as `latin-alnum` under the existing classification rule, and this classification SHALL NOT be treated as validated: no measurement establishes that `latin-alnum` reporting is meaningful for such queries.

#### Scenario: A non-CJK, non-Latin query still classifies but is not claimed to be measured

- **GIVEN** a query composed entirely of Hangul characters
- **WHEN** the query is classified
- **THEN** it classifies as `latin-alnum` under the existing rule, and no report or documentation SHALL describe `latin-alnum` results as validated for that query's script

### Requirement: Negative cases are not collected

This capability SHALL NOT attempt to construct or score negative cases — queries for which the user expects a specific anchor to be retrieved but the system fails to retrieve it. The no-query-text policy governing presentation records makes constructing such a case impossible without retaining either the query text or a substitute carrying comparable information, and no such substitute is defined by this capability. The evaluation population is therefore known to exclude event-log-invisible retrieval failures, and this exclusion SHALL be treated as a stated, accepted limitation rather than a defect to be silently worked around.

#### Scenario: A comparison report does not claim to cover negative cases

- **WHEN** a comparison report or its accompanying documentation describes what the report measures
- **THEN** the description does not claim coverage of queries that returned no result, and states that such cases are excluded by design

##### Example: What the limitation statement looks like

- **GIVEN** a comparison report's accompanying documentation section describing capability coverage
- **WHEN** a reader looks for the phrase "negative case" or "zero-recall" in that section
- **THEN** the reader finds a sentence stating negative cases are excluded by design and why (the no-query-text policy), not silence or a claim of full coverage
