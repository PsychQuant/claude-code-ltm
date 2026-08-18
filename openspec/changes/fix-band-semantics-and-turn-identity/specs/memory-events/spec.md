## MODIFIED Requirements

### Requirement: Anchor addresses corpus text by content, not by index identity

An anchor SHALL identify a region of the read-only corpus by the tuple (source fingerprint, turn identifier, normalized content hash, span offsets). The normalized content hash SHALL cover the normalized text of the addressed span only, and SHALL NOT incorporate the author role or the message timestamp. An anchor SHALL NOT reference any identifier produced by the derived index, including chunk identifiers, row identifiers, and vector offsets.

The source fingerprint SHALL be derived from a property of the corpus that does not change when the same turn is observed again through a different session file. It SHALL NOT be the session identifier: a resumed or forked session copies a turn into a new file under a new session identifier, and an anchor built on that identifier stops resolving the moment a user resumes. The session identifier remains available as navigation metadata on the retrieval result; it is not part of what makes a turn that turn.

The criterion for every component of the tuple is the same and is stated as a property rather than as a list of forbidden identifiers: **a component MUST NOT be a value that changes while the addressed text stays the same**. An earlier form of this requirement named index-produced identifiers specifically; that phrasing admitted the session identifier, which is not index-produced and changes anyway.

#### Scenario: Anchor survives a change to the chunking configuration

- **WHEN** the derived index is deleted and rebuilt with a different chunk size and overlap
- **THEN** every previously recorded anchor dereferences to the same text as before the rebuild

##### Example: Rebuild under a changed chunker

- **GIVEN** an anchor recorded while the chunker emitted 400-character chunks with 40-character overlap
- **WHEN** the index is rebuilt with 250-character chunks and no overlap
- **THEN** dereferencing that anchor returns the identical span text and reports a matching content hash

#### Scenario: Anchor survives a session resume

- **GIVEN** a turn recorded in one session file, with usage events anchored to it
- **WHEN** the session is resumed and the same turn appears in a second session file under a different session identifier
- **THEN** the previously recorded anchor still dereferences to that turn, and the projection counts its events

##### Example: One turn observed through two session files

- **GIVEN** a turn whose identifier is `t-1` with text `"the tokenizer decision"`, first observed in session `s-A` and later copied into session `s-B` by a resume
- **WHEN** an event recorded while only `s-A` existed is projected after `s-B` has been indexed
- **THEN** the anchor resolves and the event contributes to that turn's statistics, rather than being reported as an orphan whose turn is missing

#### Scenario: Altered source text dereferences as orphaned

- **WHEN** an anchor is dereferenced and the normalized text at the addressed location hashes to a value other than the stored hash
- **THEN** the dereference returns an orphaned result naming the mismatch, and does not return the text found at that location

## ADDED Requirements

### Requirement: Anchors recorded under a superseded source-fingerprint form are refused, not reinterpreted

When the canonical store contains anchors whose source fingerprint was produced by a superseded rule, reading SHALL refuse them rather than attempt to reinterpret them against the current rule. Refusal SHALL name the affected records.

Reinterpretation is forbidden because a fingerprint carries no marker of which rule produced it: silently matching an old value against a new rule either resolves to the wrong turn or reports an orphan, and neither outcome is distinguishable from correct behavior by the reader.

#### Scenario: A store written under the previous rule is refused

- **WHEN** the event store contains records whose source fingerprint is a session identifier rather than a project fingerprint
- **THEN** reading refuses those records and names them, and does not resolve them against the current rule

## MODIFIED Requirements

### Requirement: The event store is append-only

The event store SHALL expose append and range-read operations. It SHALL NOT expose an operation that updates or deletes an individual event. An append that cannot be persisted SHALL surface the failure to the caller rather than being dropped.

The store MAY expose exactly one removal operation, and only this one: dropping the records that cannot be read back — those that fail canonical decoding, and those whose anchor was written under a superseded source-fingerprint rule. That operation SHALL NOT accept a caller-supplied list of records to remove; the selection rule lives in the store, so no caller can use it to delete a chosen event. It SHALL perform its own read, its selection, and its write within a single exclusive lock on the same file descriptor, and SHALL NOT replace the file's inode, because the lock other writers take is bound to that inode and replacing it makes their in-flight appends vanish without error.

This exception exists because the refusal it repairs is otherwise terminal. The event log is the only data in this project that cannot be rebuilt from the corpus, and a single unreadable record makes every read of it fail. Without a way out, "refuse rather than reinterpret" would mean "history is locked shut", which is a worse outcome than dropping the records that could not be read in the first place.

#### Scenario: Failed append is surfaced

- **WHEN** an append cannot be persisted
- **THEN** the caller receives an error rather than a silent success

#### Scenario: Unreadable records can be dropped, chosen records cannot

- **WHEN** the store contains one record that fails canonical decoding and one whose anchor uses a superseded rule, alongside readable records
- **THEN** the removal operation drops exactly those two, reports their file line numbers, keeps every readable record, and offers no way to name a different record for removal

#### Scenario: Removal does not replace the file

- **GIVEN** another writer holds the store's exclusive lock
- **WHEN** the removal operation runs
- **THEN** it waits for that lock rather than proceeding, and the file it writes back has the same inode it read
