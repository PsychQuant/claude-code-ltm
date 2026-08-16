# memory-events Specification

## Purpose

Append-only canonical record of retrieval interactions, addressed by stable anchors, storing pointers and statistics only.

## Requirements

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

### Requirement: A canonical line is exactly the canonical encoding of its value

Reading a line from the canonical store SHALL decode it, re-encode the decoded value with the same encoder the writer uses, and reject the line unless the result is byte-for-byte identical to the bytes read. Rejection SHALL name the line number so the record can be located and repaired.

This is the operative form of "the store contains nothing the schema does not define". Field-level shape constraints are a second layer, not the criterion: they cannot see what the decoder discards. Four successive attempts to state the constraint as a list of field shapes each missed a case found later — nested unknown keys, extra array elements, duplicated keys — and two of those are unreachable by any field-level check, one because the decoder involved belongs to the standard library and one because the offending key is in the declared set.

A line consisting of zero bytes SHALL be skipped without being treated as a record or as corruption; it carries nothing.

#### Scenario: A line carrying anything the encoder would not produce is rejected

- **WHEN** a stored line differs from the canonical encoding of the value it decodes to — by an unknown key at any object node, an extra element at any array node, a duplicated key, an escape form, key ordering, or whitespace
- **THEN** reading rejects that line and names its line number

#### Scenario: The salvage path survives one rejected line

- **GIVEN** a store whose second line is not canonical
- **WHEN** the store is read in salvage mode
- **THEN** the first line is returned and the second is listed as corrupt

### Requirement: Identifiers, hashes and spans have type-level shape constraints

Every value that reaches a canonical record SHALL be constrained in its own type, at construction and at decoding: opaque identifiers to a fixed ASCII character set with a length ceiling; note and presentation references to a random-identifier storage type that admits no free text; content hashes to lowercase hexadecimal of fixed length, excluding the digest of the empty string; spans to a non-empty, non-negative, non-inverted pair of integers validated before the range is constructed.

This layer cannot be the criterion — it sees only what the decoder kept — but without it the byte-level check is the sole line of defence and every malformed value reaches business logic before being noticed.

#### Scenario: A free-text value is rejected at every string-valued field

- **WHEN** each string leaf of an encoded event is replaced in turn with free text
- **THEN** decoding fails for every one of them

#### Scenario: An anchor cannot bind to nothing

- **WHEN** a content hash equal to the digest of the empty string would be stored
- **THEN** it is rejected, because such an anchor resolves against any text

#### Scenario: Dereferencing text that normalizes to nothing reports an orphan

- **GIVEN** a stored anchor whose corpus text has since been edited to whitespace only
- **WHEN** the anchor is dereferenced
- **THEN** the result is an orphan, not a crash

### Requirement: The event store refuses to write inside the read-only corpus

Constructing a store SHALL fail when its path resolves inside the read-only corpus, where "inside" is decided by filesystem identity of the containing directories rather than by path spelling, so that an alternate absolute path to the same directory is recognised. Construction SHALL also fail when the containing directory is group- or world-writable without the sticky bit. Appending SHALL create the file owner-readable only, SHALL refuse a target that is not a regular file, and no read or write operation SHALL block indefinitely.

#### Scenario: An alternate path to the corpus is refused

- **GIVEN** a second absolute path that resolves to the same directory as the corpus root
- **WHEN** a store is constructed under it
- **THEN** construction fails

#### Scenario: A non-regular file is refused without hanging

- **GIVEN** a path naming a FIFO
- **WHEN** an append is attempted, and separately when a read is attempted
- **THEN** each fails promptly rather than blocking

### Requirement: Event records carry pointers and statistics only

An event SHALL consist of an event kind, an anchor, a timestamp, a generation identifier naming the index build that produced the result, a ranking policy identifier naming the strategy in force, and an optional presentation identifier naming the presentation the interaction originated in. A pin event SHALL additionally carry an opaque note reference generated as a random identifier. No event field SHALL contain corpus text, query text, or pin note text. A note reference SHALL NOT be derived from note content by hashing or by any other content-dependent function, and neither SHALL a presentation identifier.

The presentation identifier SHALL be absent for interactions that did not originate in a presented result list. It exists because attribution is otherwise ambiguous: one anchor appears across many presentations, so the anchor and generation together cannot determine which presentation an interaction belongs to, and therefore cannot determine which strategy earns the credit.

#### Scenario: Presentation identifier is content-independent

- **WHEN** two presentations are recorded for the same query and the same candidate list
- **THEN** the two presentations carry different identifiers, and neither identifier is derived from the query or from any candidate text

#### Scenario: Serialized event store contains no verbatim content

- **WHEN** an event store populated from a fixture session is serialized in full
- **THEN** the serialized output contains none of the fixture corpus strings, and every byte is ASCII

  (The fixture query string and note string are deliberately not asserted against. No parameter of the store accepts them, so searching the output for a string that was never supplied is a vacuous assertion. Their absence is established by the type-level constraints and the canonical-bytes requirement above.)

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

Per-anchor statistics SHALL be computed by a projection function from **three** inputs: the event sequence, an evaluation instant, and a corpus reader. The resulting statistics SHALL NOT be written back into the event store as canonical records. Changing the projection formula SHALL change subsequent results without requiring modification of any stored event.

The corpus reader is not optional. Orphan filtering happens inside projection, and deciding whether an anchor still resolves requires dereferencing it. An earlier wording named only the first two inputs, which made the purity scenario below false of the shipped function: the same events at the same instant yield different statistics against two corpus snapshots that differ in one edited message. Reproducing a projection therefore requires pinning the corpus, not only the events.

#### Scenario: Projection is a pure function of its three inputs

- **WHEN** the same event sequence is projected twice at the same evaluation instant against the same corpus
- **THEN** the two results are equal

#### Scenario: A changed corpus changes the projection

- **GIVEN** an event sequence and an evaluation instant
- **WHEN** the same projection is run against a corpus in which the addressed message has been edited
- **THEN** the affected anchor is reported as orphaned and contributes no strength

#### Scenario: Events for anchors absent from the current index are inert

- **WHEN** the event sequence contains events whose anchors dereference as orphaned
- **THEN** projection completes without error and those anchors contribute nothing to the resulting statistics

### Requirement: Only deliberate interactions reinforce

Projection SHALL treat `opened`, `cited`, and `pinned` as reinforcing signals and `dismissed` as a suppressing signal. Projection SHALL NOT treat `shown` as a reinforcing signal. The `shown` kind SHALL remain recordable so that comparison can compute per-presentation rates.

#### Scenario: Impressions alone produce no reinforcement

- **GIVEN** an anchor with twenty `shown` events and no other events
- **WHEN** the sequence is projected
- **THEN** the anchor's reinforcing statistics are equal to those of an anchor with no events at all
