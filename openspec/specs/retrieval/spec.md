# retrieval Specification

## Purpose

TBD - created by archiving change 'retrieval-engine-and-cli'. Update Purpose after archive.

## Requirements

### Requirement: A query fuses lexical and semantic channels by reciprocal rank

Query execution SHALL rank candidates by reciprocal-rank fusion over three channels: the trigram FTS5 table, the segment FTS5 table (tokenizer configuration per docs/measurements/2026-08-10-fts5-tokenizer.md), and brute-force cosine over the embedding vectors. The fused rank SHALL define each candidate's `RelevanceBand`; the fused score SHALL be its `baseScore`. The fused list SHALL contain only chunks that appear in at least one channel's ranking.

#### Scenario: Fusion merges channel rankings

- **WHEN** a query's trigram channel ranks chunks (A, B), the segment channel ranks (B, C), and the cosine channel ranks (C, A)
- **THEN** the fused ranking contains exactly {A, B, C}, ordered by summed reciprocal ranks, and no chunk outside the three channel rankings

##### Example: Reciprocal rank sums with k=60

| Chunk | Trigram rank | Segment rank | Cosine rank | RRF sum |
| ----- | ------------ | ------------ | ----------- | ------- |
| A | 1 | — | 2 | 1/61 + 1/62 |
| B | 2 | 1 | — | 1/62 + 1/61 |
| C | — | 2 | 1 | 1/62 + 1/61 |

---
### Requirement: Every result carries the four-field pointer

Every retrieval result surfaced to any consumer SHALL carry `(project, sessions, uuid, timestamp)`, where `sessions` is the **set** of session identifiers of every source holding the result's chunk, as defined by the `corpus-indexing` capability. A result that cannot be attributed to a pointer tuple SHALL be dropped, not emitted partially.

The session component is a set rather than a single value because one turn is routinely held by several session files (resume copies), and no principled rule picks one of them — see `corpus-indexing` for why the previous single-value rule was both position-derived and unstable. No consumer SHALL treat any element of the set as a representative.

The `sessions` set is defined by the `corpus-indexing` capability's "Chunk granularity is one conversation turn with full pointer metadata" Requirement. What populates it, and why no element of it is privileged, lives there and is deliberately not restated here.

The set SHALL be present on every result, including results whose chunk has exactly one holding source (where it has exactly one entry). It SHALL NOT be omitted, left empty, or made conditional on the set having more than one member: a consumer that must branch on the field's presence would exercise that branch only in the single-source case, which is the path least likely to be tested.

#### Scenario: Pointer fields are present on all hits

- **WHEN** any query returns k results through the facade
- **THEN** each of the k results exposes a non-empty `project`, `uuid` and `timestamp`, and a `sessions` set with at least one non-empty entry

#### Scenario: The source set accompanies every hit

- **WHEN** any query returns k results through the facade
- **THEN** each of the k results exposes a source-identifier set with at least one entry

#### Scenario: A hit for a resume-duplicated turn reports every holding source

- **GIVEN** a corpus where one turn is held by two session files with identical content and identical message timestamps
- **WHEN** a query retrieves that turn
- **THEN** the returned result's source set contains both session identifiers


<!-- @trace
source: return-all-navigation-sources
updated: 2026-08-21
code:
  - CHANGELOG.md
  - Sources/LTMIndex/IndexDatabase.swift
  - Sources/LTMIndex/RetrievalEngine.swift
  - Tests/LTMServiceTests/LTMServiceTests.swift
  - Tests/LTMServiceTests/CLICommandTests.swift
  - Tests/LTMIndexTests/IndexDatabaseTests.swift
  - Sources/ltm/Commands.swift
  - Sources/LTMService/LTMService.swift
-->

---
### Requirement: Strategy application goes through the MemoryStrategy seam with archival as default

Retrieval SHALL hand its fused candidates to a `MemoryStrategy` for final ordering and SHALL NOT reorder outside that seam. When no strategy is named, the archival strategy (no reordering) SHALL be applied. Strategy outputs SHALL preserve the seam's contract: results carry displacement and reason as defined by the memory-strategy capability.

#### Scenario: Default query order is pure retrieval order

- **WHEN** a query runs without a named strategy
- **THEN** the emitted order equals the fused retrieval order and every result reports zero displacement

---
### Requirement: An embedding revision mismatch refuses the query

When the running system's `NLContextualEmbedding` revision differs from the revision recorded in the index, query execution SHALL fail with an error naming `ltm build` as the remediation, and SHALL NOT return results computed across revisions.

#### Scenario: Cross-revision cosine is never served

- **WHEN** the index records revision R1 and the runtime provides revision R2, and a query arrives
- **THEN** the query fails with a revision-mismatch error that names `ltm build`, and no result list is produced

---
### Requirement: Query scope defaults to one project and widens only explicitly

A query SHALL be scoped to a single project by default. Searching across all projects SHALL require an explicit opt-in from the caller. When no default project can be determined, the query SHALL fail asking for an explicit scope rather than silently widening.

#### Scenario: Ambiguous scope refuses instead of widening

- **WHEN** a query arrives with no project argument and no unambiguous default project
- **THEN** the query fails instructing the caller to name a project or explicitly request all projects, and no cross-project results are returned