## Context

claude-LTM indexes an existing, immutable corpus (Claude Code conversation transcripts) and must never write to it. The index is a pure derivative that can be deleted and rebuilt. Usage history is the sole exception: it records something the transcripts cannot, so it is canonical and must be backed up.

That exception is where this change lives. Because usage history is canonical, its schema is expensive to migrate once data accumulates, and because the corpus contains third-party verbatim content, its schema is also a privacy boundary. Both pressures push the same way: store as little as possible, and make what is stored survive index rebuilds.

An adversarial review of the original design produced two findings that shape this document. First, anchors pointing at chunk identifiers would tie the canonical store to the disposable index — changing the chunker would orphan canonical records. Second, storing aggregated strength values would bind the canonical store to one particular decay formula, so fixing a bug in that formula would corrupt history rather than merely recompute it.

A prerequisite measurement (issue #2) established the retrieval baseline this change sits on top of: lexical retrieval uses a trigram plus word-segmented dual index fused by reciprocal rank fusion, and adding a vector path raises overall known-item recall by roughly one percentage point, with the entire gain concentrated in one query class. That magnitude matters here: if strategy differences are of the same order, aggregate comparison will not detect them.

## Goals / Non-Goals

**Goals:**

- Make the memory strategy a runtime parameter with exactly one architectural seam, so strategies can be added without touching retrieval.
- Define a canonical event schema that survives index rebuilds, formula changes, and chunker changes.
- Ship strategies that differ in kind (memory absent / memory only at ties / memory active), never in degree.
- Provide a comparison method that works without retaining query text.

**Non-Goals:**

- **Not building the ingest pipeline or the retrieval index.** This change defines the seam and its inputs; candidates arrive as a value type and tests construct them synthetically. Wiring to a real index is separate work informed by issue #2.
- **Not shipping a fourth strategy.** Three ship: `archival`, `conservative`, `human-like`. An earlier draft of this document removed `conservative` and stated it would not be replaced; that removal rested on an argument that was only half true, and the tier was restored. Any further strategy must be defined by which signals it consumes and under what condition it acts, never by how large an adjustment it makes.
- **Not choosing the displacement bound.** The bound is a tunable parameter with a recorded default; its correct value cannot be derived before an evaluation set exists.
- **Not encrypting pin notes.** This change defines the pointer that references a note; the note store itself is separate work tracked by issue #3.
- **Not retaining query text under any option.** Rejected explicitly: retaining queries would permit retrospective strategy replay, but query text routinely contains third-party names and unpublished material, which the project's privacy rule places outside the canonical store.

## Decisions

### Store events, not aggregates

The canonical store holds an append-only sequence of interaction events. Strength, decay, and association edges are computed from that sequence on demand and are never persisted as canonical values.

*Alternative rejected:* persisting a strength scalar per anchor. That is smaller and faster to read, but it binds canonical data to one decay formula. Changing the formula, fixing an arithmetic bug, or running a counterfactual would each require rewriting history. Events cost tens to hundreds of bytes per interaction, which is negligible against a multi-gigabyte corpus, and they make formula changes a recomputation rather than a migration.

### Anchor by content, not by chunk identity

An anchor is the tuple (source file fingerprint, turn identifier, normalized content hash, span offsets). Dereferencing verifies the content hash; a mismatch marks the record orphaned and the strategy ignores it.

*Alternative rejected:* anchoring by chunk identifier. Chunks are produced by a splitting algorithm that this project expects to tune. Any change to chunk size, overlap, or the parser would silently repoint canonical records at different text. Content hashing makes that failure loud instead of silent.

The hash covers normalized text only, excluding role and timestamp. Including them would orphan records whenever a message is edited upstream; excluding them means two identical short texts in different turns hash alike, which the turn identifier and span offsets already disambiguate.

### One seam, and projection is a function

`MemoryStrategy` is the only new abstraction. Event projection — turning an event sequence into per-anchor statistics — is a free function, not a module or protocol.

**How strongly the seam is enforced, stated honestly.** The strategy signature takes candidates and a projection and nothing else, so a strategy cannot reach the corpus *through its arguments*; but `CorpusReader` and `Anchor.dereference` are public in `LTMCore`, so a strategy that wants corpus text can construct its own reader. Likewise `LTMQuery` does not depend on `LTMMemory` and therefore cannot name `FileEventStore`, but `Event` is `Codable` in `LTMCore` and the store format is JSON Lines, so the event file can be read with Foundation alone. Both were demonstrated by the #1 verify on 2026-08-11. The two "SHALL NOT" requirements are therefore **conventions carried by the dependency graph, not compile-time facts**. Making them facts requires moving the event encoding out of `LTMCore`; that is a separate refactor, tracked as a follow-up.

*Alternative rejected:* a `ProjectionProvider` protocol alongside the strategy protocol. Applying the deletion test: removing the projection abstraction breaks nothing, because there is exactly one way to fold events into statistics and no caller needs to vary it. A second seam there would be a pass-through wrapper. If projection later needs its own caching or incremental update lifecycle, it earns promotion then.

### Reorder within relevance bands, bound the displacement

Strategies may only reorder candidates that share a relevance band, and may move any candidate by at most a bounded number of positions. The bound is configuration with a documented default.

*Alternative rejected:* scaling the fused score by a bounded percentage. Reciprocal rank fusion scores are rank-derived and query-relative: the same numeric delta means different things for different queries, and the score distribution shifts when input list depth changes. A percentage cap therefore has no stable referent. Position displacement is directly interpretable and directly auditable.

### Only deliberate interactions count

`opened`, `cited`, `pinned`, and `dismissed` influence ranking. `shown` is recorded for evaluation but never reinforces.

*Alternative rejected:* counting impressions. Counting `shown` creates a loop in which appearing in results is itself sufficient to keep appearing, independent of whether the result was useful. Deliberate interactions are the only signal that carries a judgement.

### Compare by interleaving, not by replay

Two strategies each produce a ranking for the same query; the presented list interleaves them; which side the user opens is the observation. Results are reported per query class.

*Alternative rejected:* replaying a stored query set against each strategy. This is the standard approach and is strictly more convenient, but it requires retaining query text, which the privacy decision above forecloses. Interleaving needs only the events already being recorded. Per-class reporting is required because the prerequisite measurement showed a real effect of about one percentage point in aggregate that was entirely concentrated in a single class — an aggregate-only comparison would have reported no difference.

## Implementation Contract

**Behavior.** A caller asks the query layer for results and receives an ordered list in which every item carries its displacement relative to pure retrieval order and the reason for that displacement. Under `archival` every displacement is zero. Under `conservative` an item moves only among candidates its base score ties with, and under `human-like` wherever recorded history differs; both move by no more than the configured bound, and the reason names the events responsible.

**Interface and data shape.**

- An `Anchor` value carries a source fingerprint, a turn identifier, a normalized content hash, and a span range. It exposes a dereference operation that returns either the addressed text or an orphaned result when the stored hash does not match the text found at that location.
- An `Event` value carries an event kind drawn from a closed set (`shown`, `opened`, `cited`, `pinned`, `dismissed`), an anchor, a timestamp, a generation identifier naming the index build that produced the result, a ranking policy identifier naming the strategy in force, and an optional presentation identifier naming the presentation the interaction came from. A pin event additionally carries an opaque note reference. Both identifiers are random and opaque. No field holds chunk text, query text, or note text.
- The presentation identifier exists because attribution is otherwise ambiguous: the same anchor appears across many presentations, so `(anchor, generation)` cannot say which presentation a click belongs to, and therefore cannot say which strategy earns the credit. It is absent for interactions that did not originate in a presented result list.
- An event store exposes append and range-read operations only. It has no update or delete operation for individual events.
- A projection function maps a sequence of events, an evaluation instant, and a corpus reader to per-anchor statistics. The corpus reader is required because the spec places orphan filtering inside projection: an anchor whose text no longer hashes as recorded contributes nothing, and deciding that requires dereferencing. The function stays pure — deterministic given those three inputs — and it never writes.
- `MemoryStrategy` exposes one operation taking an ordered candidate list and a projection and returning a reordered list of results, each carrying displacement and reason.
- The interleaving harness takes two strategies, a candidate list, and the query, and returns an interleaved presentation plus a presentation record. That record carries a query class label drawn from a closed five-value set, the pair of strategy identifiers, the generation identifier, and the per-anchor attribution needed to score which side a later interaction credits. The label is computed from the query at presentation time and the query itself is then discarded — the query reaches the harness, never the store. A label from a five-value set is a statistic, not content, which is why it is admissible under the same rule that excludes query text.

**Failure modes.**

- A dereference whose content hash does not match returns an orphaned result. Every strategy ignores orphaned anchors; the strategies that consume history additionally surface the fact in the returned reason, never silently treating it as a normal miss. `archival` does not surface it, and must not: its contract is to produce identical output regardless of the projection it is given, so a reason that varied with the projection would break the very property that makes it the comparison baseline. An earlier draft of this paragraph stated the surfacing as universal, which contradicted that contract. Making that true requires the projection to carry the orphaned anchors forward — orphan filtering happens inside projection, so without that the information is gone before a reason can be composed, and the reason case for it is unreachable. That was the state the #1 verify found on 2026-08-11; the projection now carries them.
- An event referring to an anchor absent from the current index contributes nothing to projection and is not an error; the canonical store outliving a given index build is expected.
- A strategy attempting to move a candidate outside its relevance band, or further than the configured bound, is a programming error and fails loudly rather than being clamped, so that a misbehaving strategy cannot silently masquerade as a conforming one.
- An unwritable event store fails the append and surfaces the failure. Losing usage history silently is not acceptable, because unlike the index it cannot be rebuilt.

**Acceptance criteria.**

- Deleting and rebuilding the derived index leaves every event still dereferenceable, demonstrated by a test that rebuilds anchors from a changed chunking configuration and asserts the events still resolve.
- Under `archival`, results are byte-identical in order to the input candidates and every displacement is zero, asserted directly in tests.
- Under `human-like`, an anchor with recorded `cited` events outranks a band peer without them, moves by no more than the bound, and reports a reason naming those events.
- An anchor whose underlying text has been altered dereferences as orphaned and contributes nothing to ranking.
- No event record contains chunk text, query text, or note text, asserted by a test that serializes a populated store and searches the output for known fixture strings.
- The interleaving harness attributes an interaction to exactly one contributing strategy, asserted over a synthetic pair whose rankings differ.
- A comparison report carries one row per query class with that class's observation count, and never an aggregate row on its own, asserted over synthetic events spanning several classes.
- A serialized presentation record contains none of the query's bytes, and every byte is ASCII, asserted by running a query through the harness and encoding the record it produces. Searching the output for a string that was never supplied to the store would be a vacuous assertion — that was the earlier formulation, and it was removed for that reason (#1 verify R4/R5). What is asserted instead is a property of an output produced from a real input.

**In scope:** the anchor and event value types, the event store, the projection function, the strategy protocol, all three strategies, the interleaving harness with its presentation record and per-class report, and their tests. Documentation updates recording the history of the third tier (removed on a half-true argument, then restored as tie-breaker-only) and the interleaving decision.

**Out of scope:** ingest, chunking, lexical and vector indexes, the encrypted note store, query expansion, and any user-facing command surface. Candidates are constructed synthetically in tests; no test reads the real corpus.

**Declared gaps found by the second verify round (2026-08-14).** Each was undeclared until that round; naming them here is the correction.

- **Presentation records are never persisted.** `ComparisonScorer.report` takes an in-memory array, and nothing writes a `PresentationRecord` to disk. Events therefore carry presentation identifiers that nothing can resolve across process boundaries, so comparison works only within a single call — the capability is not deliverable end-to-end. The spec's scenario about serializing "a store of presentation records" describes a store that does not exist. Persisting them is required before any real comparison can run.
- **The presentation record is pairwise by construction.** It carries `strategyA` and `strategyB`, and the spec freezes that shape. If a third strategy ever ships — whether `conservative` returns or spreading activation lands as a distinct signal set — a three-way comparison cannot be expressed without migrating a canonical, non-rebuildable schema. That is precisely the migration cost this document's Context names as the governing pressure, applied to events but not to this record.
- **Two Clarity Surface resolutions were departed from without a marker.** The resolution said the displacement bound is one position; the spec makes it configuration with one as a default. The resolution set the calibration protocol (Recall@20 then nDCG@10, split lexical-only / vector-only / fused, plus deliberately collected negative cases); this change ships a different metric family (per-class credit rate) and no split by retrieval track. Both departures may be right, but they were stated as settled law rather than flagged as deviations, so a reader reconstructing the decision history from the repository would not know a prior ruling existed.
