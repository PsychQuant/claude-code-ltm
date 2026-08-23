## ADDED Requirements

### Requirement: Interleaved presentations are produced on the live query path

The capability's purpose is evaluation over live usage, and until now nothing produced that usage. A query SHALL be able to run in a comparison mode that ranks one candidate list with two strategies, interleaves the two orderings, and persists a presentation record describing which strategy contributed each position, together with the shown events for that presentation.

The candidate list SHALL be retrieved once and ranked twice. Retrieving separately for each strategy would let the two sides differ for reasons that have nothing to do with the strategies, and the resulting report would measure retrieval variance while claiming to measure strategy preference.

Comparison mode SHALL be opt-in and SHALL NOT alter the default query path. Requesting it SHALL enable event persistence for that invocation: a comparison that is not recorded produces nothing and changes what the user sees for no benefit, so the incoherent combination is not offered.

When no event store is available, a request for comparison mode SHALL fail rather than proceed without persisting. Proceeding would present interleaved results whose record is lost, which is indistinguishable to the user from a comparison that was recorded.

**Bootstrap behaviour is expected, not a defect.** With no recorded history every anchor's net strength is zero, no strategy reorders, and both sides produce the same ordering — a null comparison, which this capability already excludes from scoring. Comparison mode therefore yields nothing to score until interaction events accumulate. Implementations SHALL NOT treat that as an error, and artifacts SHALL NOT predict when the first scorable comparison will occur, because it depends on usage.

#### Scenario: A recorded comparison reaches the scorer

- **GIVEN** a query run in comparison mode with an event store available
- **WHEN** the resulting presentation record and events are supplied to the comparison scorer
- **THEN** the events are attributed through that record rather than being skipped as belonging to an untracked presentation

#### Scenario: The default path is unchanged

- **WHEN** a query is run without requesting comparison mode
- **THEN** no presentation record is written and the output is what the same query produced before comparison mode existed

#### Scenario: Comparison without a place to record it fails

- **GIVEN** no event store is available
- **WHEN** a query requests comparison mode
- **THEN** the query fails naming that condition, and no results are presented

#### Scenario: Identical orderings during bootstrap are recorded, not rejected

- **GIVEN** a projection in which no anchor carries any history
- **WHEN** a query is run in comparison mode
- **THEN** a null-comparison record is written and the invocation succeeds

### Requirement: Retrieval quality is evaluated against extracted known items

Scoring retrieval quality requires pairs of a query and the turn that query should retrieve. This capability SHALL obtain such pairs by extraction: sample a chunk from the corpus, derive a query from its text, and treat that chunk as the gold answer for the derived query.

Neither the derived queries nor the gold pointers SHALL be written to any durable surface. They SHALL exist only for the duration of the evaluation. What is committed is the generator and the aggregate results, never the pairs — this is what allows the evaluation to be re-runnable without a stored dataset, and it is required by the policy that query text is never retained.

Each pair SHALL be scored against the lexical-only, vector-only, and fused retrieved lists using the same two-stage function, producing the per-channel breakdown this capability already requires. A sample from which no usable query can be derived SHALL be skipped and counted, and the count SHALL appear in the output; a silent skip would let the effective sample size differ from the requested one without the reader knowing.

**This evaluation measures retrieval, not strategies.** A record produced by it SHALL state that, because the surrounding context is strategy comparison and a reader may otherwise take retrieval numbers as evidence about strategies. It SHALL also state that the queries are extracted from the chunks they retrieve and therefore do not represent real queries, and that the population inherits this capability's exclusion of retrieval failures invisible to the event log.

#### Scenario: All three channels are scored for every pair

- **GIVEN** a corpus and a requested sample size
- **WHEN** the known-item evaluation runs
- **THEN** every sampled pair yields a two-stage outcome for each of the lexical-only, vector-only, and fused channels

##### Example: A per-channel breakdown for one query

A two-character query whose gold chunk is retrieved at different depths by different channels:

| Channel | Outcome |
|---|---|
| lexical-only | not recalled — the gold chunk is absent from the first twenty results |
| vector-only | recalled, with a ranking score reflecting third place |
| fused | recalled, with the maximum ranking score, the gold chunk having been placed first |

A row like this turns a claim about one channel going dark for short queries into something a reader can read off the report rather than infer.

#### Scenario: The same seed reproduces the same aggregates

- **GIVEN** a fixed corpus, sample size, and seed
- **WHEN** the evaluation is run twice
- **THEN** both runs report the same aggregates

#### Scenario: Undeliverable samples are counted, not hidden

- **GIVEN** a corpus containing chunks from which no usable query can be derived
- **WHEN** the evaluation runs
- **THEN** those samples are skipped and the number skipped appears in the output

#### Scenario: No query text or gold pointer is persisted

- **WHEN** the evaluation completes
- **THEN** neither the printed output nor any file it wrote contains a derived query, a gold pointer, or chunk text
