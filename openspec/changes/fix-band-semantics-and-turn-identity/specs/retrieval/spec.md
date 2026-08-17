## MODIFIED Requirements

### Requirement: A query fuses lexical and semantic channels by reciprocal rank

Query execution SHALL rank candidates by reciprocal-rank fusion over three channels: the trigram FTS5 table, the segment FTS5 table (tokenizer configuration per docs/measurements/2026-08-10-fts5-tokenizer.md), and brute-force cosine over the embedding vectors. The fused score SHALL be each candidate's `baseScore`. The fused list SHALL contain only chunks that appear in at least one channel's ranking.

The fused rank SHALL NOT be used as the candidate's relevance band. A band is a stratum shared by several candidates; a rank is unique per candidate, so assigning it as the band leaves every candidate alone in its own band and makes every reordering a band crossing. The effect is silent — no guard fires, and a reordering strategy returns exactly what a non-reordering strategy returns.

#### Scenario: Fusion merges channel rankings

- **WHEN** a query's trigram channel ranks chunks (A, B), the segment channel ranks (B, C), and the cosine channel ranks (C, A)
- **THEN** the fused ranking contains exactly {A, B, C}, ordered by summed reciprocal ranks, and no chunk outside the three channel rankings

##### Example: Reciprocal rank sums with k=60

| Chunk | Trigram rank | Segment rank | Cosine rank | RRF sum |
| ----- | ------------ | ------------ | ----------- | ------- |
| A | 1 | — | 2 | 1/61 + 1/62 |
| B | 2 | 1 | — | 1/62 + 1/61 |
| C | — | 2 | 1 | 1/62 + 1/61 |

#### Scenario: The fused rank is not the band

- **WHEN** a query returns more than one candidate
- **THEN** at least two candidates share a relevance band whenever they matched the same number of channels, and no candidate's band is derived from its position in the fused ordering

## ADDED Requirements

### Requirement: A candidate's relevance band is the number of retrieval channels it matched

The relevance band assigned to a candidate SHALL be determined by how many of the three retrieval channels ranked it: matching three channels SHALL place a candidate in a higher band than matching two, which SHALL be higher than matching one. The rule SHALL take no configured parameter.

The rationale is that a candidate reachable through several independent cues is more relevant than one reachable through a single cue, and that this project has no evaluation set with which to calibrate any bucket count or score boundary. A parameter that cannot be calibrated MUST NOT be introduced into a shipped specification.

The within-band population of this rule SHALL be measured against a real corpus and the measurement recorded under `docs/measurements/` before the rule is relied upon. If the measurement shows the population degenerating — nearly every candidate matching exactly one channel, or nearly every candidate matching all three — the rule SHALL be reconsidered rather than shipped, because either extreme reproduces the defect it replaces.

#### Scenario: Candidates matching the same number of channels share a band

- **WHEN** two candidates each matched exactly two of the three channels
- **THEN** they occupy the same relevance band, and a strategy may reorder one relative to the other

#### Scenario: A candidate matching more channels outranks one matching fewer

- **WHEN** candidate A matched three channels and candidate B matched one
- **THEN** A's band is higher than B's, and no strategy may place B above A regardless of B's usage history

##### Example: Bands from channel membership

| Candidate | Trigram | Segment | Vector | Channels matched | Band |
| --------- | ------- | ------- | ------ | ---------------- | ---- |
| A | ✓ | ✓ | ✓ | 3 | 0 (highest) |
| B | ✓ | ✓ | — | 2 | 1 |
| C | — | ✓ | — | 1 | 2 |
| D | ✓ | — | — | 1 | 2 |

C and D share band 2, so a strategy may reorder them relative to each other; neither may be placed above B.

### Requirement: A reordering strategy produces a different order from a non-reordering one when history exists

Given a candidate list with more than one candidate in some band, and a projection containing recorded events for at least one of those candidates, invoking a reordering strategy SHALL produce an ordering that differs from the archival strategy's ordering, and SHALL report a non-zero displacement for at least one result.

This requirement exists because the previous implementation satisfied every strategy-seam requirement individually while making the seam incapable of any effect. It SHALL be verified end to end through the query facade, not against the strategy type in isolation: the defect it guards against lived in how candidates were constructed, which a test of the strategy alone cannot see.

#### Scenario: A used candidate is promoted within its band

- **GIVEN** two candidates in the same band, one with recorded `cited` events and one with none
- **WHEN** the query runs with a reordering strategy and again with the archival strategy
- **THEN** the two orderings differ, and the candidate with citations reports non-zero displacement in the reordering run
