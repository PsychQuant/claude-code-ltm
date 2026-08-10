## ADDED Requirements

### Requirement: Anchor addresses corpus text by content, not by index identity

An anchor SHALL identify a region of the read-only corpus by the tuple (source fingerprint, turn identifier, normalized content hash, span offsets). The normalized content hash SHALL cover the normalized text of the addressed span only, and SHALL NOT incorporate the author role or the message timestamp. An anchor SHALL NOT reference any identifier produced by the derived index, including chunk identifiers, row identifiers, and vector offsets.

#### Scenario: Anchor survives a change to the chunking configuration

- **WHEN** the derived index is deleted and rebuilt with a different chunk size and overlap
- **THEN** every previously recorded anchor dereferences to the same text as before the rebuild

##### Example: Rebuild under a changed chunker

- **GIVEN** an anchor recorded while the chunker emitted 400-character chunks with 40-character overlap
- **WHEN** the index is rebuilt with 250-character chunks and no overlap
- **THEN** dereferencing that anchor returns the identical span text and reports a matching content hash

#### Scenario: Altered source text dereferences as orphaned

- **WHEN** an anchor is dereferenced and the normalized text at the addressed location hashes to a value other than the stored hash
- **THEN** the dereference returns an orphaned result naming the mismatch, and does not return the text found at that location

### Requirement: Event records carry pointers and statistics only

An event SHALL consist of an event kind, an anchor, a timestamp, a generation identifier naming the index build that produced the result, a ranking policy identifier naming the strategy in force, and an optional presentation identifier naming the presentation the interaction originated in. A pin event SHALL additionally carry an opaque note reference generated as a random identifier. No event field SHALL contain corpus text, query text, or pin note text. A note reference SHALL NOT be derived from note content by hashing or by any other content-dependent function, and neither SHALL a presentation identifier.

The presentation identifier SHALL be absent for interactions that did not originate in a presented result list. It exists because attribution is otherwise ambiguous: one anchor appears across many presentations, so the anchor and generation together cannot determine which presentation an interaction belongs to, and therefore cannot determine which strategy earns the credit.

#### Scenario: Presentation identifier is content-independent

- **WHEN** two presentations are recorded for the same query and the same candidate list
- **THEN** the two presentations carry different identifiers, and neither identifier is derived from the query or from any candidate text

#### Scenario: Serialized event store contains no verbatim content

- **WHEN** an event store populated from a fixture session is serialized in full
- **THEN** the serialized output contains none of the fixture corpus strings, none of the fixture query strings, and none of the fixture note strings

#### Scenario: Pin note reference is content-independent

- **WHEN** two pin events are recorded for the same anchor with identical note text
- **THEN** the two events carry different note references

### Requirement: The event kind set is closed

The event kind SHALL be one of exactly five values: `shown`, `opened`, `cited`, `pinned`, `dismissed`. Recording an event whose kind is outside this set SHALL fail rather than being stored.

#### Scenario: Unknown event kind is rejected

- **WHEN** a caller attempts to record an event whose kind is not one of the five defined values
- **THEN** the append fails and no record is added to the store

### Requirement: The event store is append-only

The event store SHALL expose append and range-read operations. It SHALL NOT expose an operation that updates or deletes an individual event. An append that cannot be persisted SHALL surface the failure to the caller rather than being dropped.

#### Scenario: Failed append is surfaced

- **WHEN** an append is attempted against a store whose backing location is not writable
- **THEN** the append reports a failure to the caller

#### Scenario: Range read returns events in recorded order

- **WHEN** five events are appended and then read back over a range covering all of them
- **THEN** the returned sequence preserves the order in which the events were appended

### Requirement: Projection derives per-anchor statistics without persisting them

Per-anchor statistics SHALL be computed from the event sequence and an evaluation instant by a projection function. The resulting statistics SHALL NOT be written back into the event store as canonical records. Changing the projection formula SHALL change subsequent results without requiring modification of any stored event.

#### Scenario: Projection is a pure function of events and instant

- **WHEN** the same event sequence is projected twice at the same evaluation instant
- **THEN** the two results are equal

#### Scenario: Events for anchors absent from the current index are inert

- **WHEN** the event sequence contains events whose anchors dereference as orphaned
- **THEN** projection completes without error and those anchors contribute nothing to the resulting statistics

### Requirement: Only deliberate interactions reinforce

Projection SHALL treat `opened`, `cited`, and `pinned` as reinforcing signals and `dismissed` as a suppressing signal. Projection SHALL NOT treat `shown` as a reinforcing signal. The `shown` kind SHALL remain recordable so that comparison can compute per-presentation rates.

#### Scenario: Impressions alone produce no reinforcement

- **GIVEN** an anchor with twenty `shown` events and no other events
- **WHEN** the sequence is projected
- **THEN** the anchor's reinforcing statistics are equal to those of an anchor with no events at all
