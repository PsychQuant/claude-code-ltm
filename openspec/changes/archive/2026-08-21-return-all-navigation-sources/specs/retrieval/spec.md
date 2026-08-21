## MODIFIED Requirements

### Requirement: Every result carries the four-field pointer

Every retrieval result surfaced to any consumer SHALL carry `(project, sessionId, uuid, timestamp)`. A result that cannot be attributed to a pointer tuple SHALL be dropped, not emitted partially.

Every result SHALL additionally carry the full set of session identifiers of the sources holding its chunk, as defined by the `corpus-indexing` capability's "Chunk granularity is one conversation turn with full pointer metadata" Requirement. The definition of that set — what populates it, and why `sessionId` is a representative rather than a most-recent value — lives there and is deliberately not restated here.

The set SHALL be present on every result, including results whose chunk has exactly one holding source (where it has exactly one entry). It SHALL NOT be omitted, left empty, or made conditional on the set having more than one member: a consumer that must branch on the field's presence would exercise that branch only in the single-source case, which is the path least likely to be tested.

#### Scenario: Pointer fields are present on all hits

- **WHEN** any query returns k results through the facade
- **THEN** each of the k results exposes non-empty values for all four pointer fields

#### Scenario: The source set accompanies every hit

- **WHEN** any query returns k results through the facade
- **THEN** each of the k results exposes a source-identifier set with at least one entry, and the result's `sessionId` is a member of that set

#### Scenario: A hit for a resume-duplicated turn reports every holding source

- **GIVEN** a corpus where one turn is held by two session files with identical content and identical message timestamps
- **WHEN** a query retrieves that turn
- **THEN** the returned result's source set contains both session identifiers, rather than only the one selected as the pointer's `sessionId`
