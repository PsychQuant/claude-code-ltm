## Context

Stage 1 of #24 shipped a retrieval engine, an `LTMService` facade and an `ltm` CLI. A six-reviewer verify returned FAIL. Two findings are design errors; the rest are implementation defects and test-strength gaps that this change also clears.

Both design errors were reproduced in isolation before any fix was proposed (`superpowers:systematic-debugging`, Phase 1–3):

- **Band**: with `band = fusedRank`, one probe over the same projection and strategy produced displacements `[0,0,0]`; with a shared band it produced `[1,-1,0]`. The retrieval spec mandates the broken form in prose — "The fused rank SHALL define each candidate's `RelevanceBand`" — so the spec is part of the defect.
- **Turn identity**: the whole corpus of 8,324 files contains 12,488 uuids appearing in more than one file, 100% with identical content, 98.9% under a different `sessionId` (`docs/measurements/2026-08-18-resume-duplication.md`).

Two constraints shape what is possible here:

- `OpaqueIdentifier` caps identifier fields at 64 ASCII alphanumeric characters (plus `._-`). Measured: 173 of 311 project directory names exceed 64 characters (median 71, max 152), so a project name cannot be stored in an anchor field directly.
- `~/.claude-ltm/` does not exist on the maintainer's machine — **there is currently no recorded usage history anywhere**. An anchor-format change costs nothing today and cannot be repeated cheaply later.

The project's `.claude/rules/ltm-analogy.md` supplies the design criteria used below.

## Goals / Non-Goals

**Goals:**

- Make the strategy seam able to do anything at all, and make `strategy-comparison` capable of a non-null result
- Give an anchor a source component that survives session resume, so usage history stops evaporating
- Define turn de-duplication by content rather than by file
- Close the implementation defects and the test-strength gaps the verify surfaced, in the same change

**Non-Goals:**

- Deciding which strategy is better (needs #16's evaluation set)
- Indexing tool payloads (#6), spreading activation (#15), query expansion (#7)
- Stage 2 of #24 (MCP, packaging)
- Any ranking-quality claim. No measurement record covers the changes here, so none is made.

## Decisions

### Relevance band is the count of matched retrieval channels

`band = fusedRank` gave every candidate a private band. The replacement is the number of channels the candidate matched — three (trigram, segment, vector) ranks above two, which ranks above one. `ScoredChunk.channels` already carries the data.

Rationale, from the LTM criteria: relevance dominates retrieval and usage strength only adjusts within it (criterion 2 — so a band must be a real stratum, not a per-candidate rank), and multiple encoding raises retrievability (criterion 3 — a candidate reachable through several independent cues genuinely is more relevant).

Alternatives rejected:

- **One band for everything, letting `displacementBound` carry the constraint.** This was the first proposal in discussion and it is wrong: the bound limits how far a candidate moves, not whether it crosses a relevance stratum, so a low-relevance but heavily-used candidate can climb above a high-relevance one. Band and bound are independent constraints.
- **Score-interval or fixed-bucket banding.** Both introduce a parameter (boundary or bucket count) that this project has nothing to calibrate against until #16 exists. Writing an uncalibrated parameter into a shipped spec is the failure this project's honesty boundary exists to prevent.

**Open risk, stated rather than hidden**: the within-band population of this rule is **unmeasured**. If real queries mostly match a single channel, it degenerates toward one band; if mostly three, toward the rejected per-candidate extreme. Task 1.1 measures it before the rule is adopted, and the measurement can veto it.

### An anchor's source is a project fingerprint, not a session identifier

`Anchor.source` becomes the SHA-256 of the project directory name, truncated to 32 lowercase hex characters. `sessionId` leaves the anchor entirely.

Rationale (criterion 1 — address by something that does not change): `sessionId` changes on resume, which is exactly what made history evaporate. A project fingerprint survives resume. It also fits `OpaqueIdentifier` where a project name does not (173 of 311 names exceed the 64-character cap), and it keeps the local filesystem path — project directory names are path transliterations containing the user's home directory — out of the canonical event store, which the memory layer's "pointers and statistics only" constraint requires.

Alternatives rejected:

- **Keep `sessionId`, change only the index's uniqueness key.** Fixes retrieval, leaves the anchor unstable; history still breaks on resume. This is the fix that treats the symptom.
- **Drop `source` from the anchor.** Changes the tuple's arity and removes the only defense against a `turnID` colliding across projects.

Accepted cost: moving a project to a different path changes its fingerprint and orphans that project's history. That is rarer than session resume by orders of magnitude, and unlike resume it is a deliberate user action. Recovering the project name from a fingerprint requires a lookup table, which lives in the derived index — acceptable, because the index is disposable and the fingerprint is not the thing being read by humans.

### `sessionId` is demoted from identity to navigation

The pointer tuple returned with every hit still contains `sessionId` — a reader needs it to open the conversation. But it is now metadata carried by the chunk, not part of what makes a turn *that* turn. When one turn appears in several session files, **every** observing file's session identifier is retained in `chunk_sources` and all of them are returned; none is designated as the chunk's session.

(Superseded 2026-08-22 by #25. This sentence previously said the chunk stores "the most recent `sessionId` observed, because that is the session most likely still open". That rule was never operative — resume copies preserve the original message timestamp, so the recency comparison always tied and the outcome fell to file-path ordering, which is position rather than content, and which shifted whenever another copy appeared. `chunks.session_id` was removed in index layout 5.)

This is the distinction the original design missed: **identity and navigation are different jobs**, and `sessionId` is only fit for the second.

### Turn de-duplication is by content, and the uniqueness key follows

A turn copied into a new session file by resume is **one** memory, not two (criterion 4). The index's uniqueness key becomes `(project fingerprint, uuid)`, which makes chunk identity and anchor identity the same thing — one anchor, one chunk, no rewriting of an identity field on upsert.

Measured support: cross-project duplication of a `uuid` is zero over the sampled 300 files, so this key does not merge turns that should stay separate. The project component is kept anyway, because relying on a `uuid` never colliding across projects is an assumption about foreign data rather than something the schema can enforce.

Rejected: `UNIQUE(sessionId, uuid)`, which yields "one memory per file" — retrieval would return the same text several times, and the LTM criterion says re-telling does not create a second memory.

### Existing anchors are discarded, and this is the only moment that is free

The anchor format change invalidates any event recorded under the old form. `~/.claude-ltm/` does not exist, so today that set is empty and the migration is a no-op.

The spec records this explicitly, because the same change made after real history accumulates would require either a migration path or accepting data loss, and the memory layer is append-only canonical data — not a derivative that can be rebuilt. The index, by contrast, is rebuilt by `ltm build --full` under invariant 2 and needs no migration at all.

### Reading usage history is decoupled from writing it

`--record` currently gates construction of the `FileEventStore`, so `--strategy human-like` without `--record` silently receives an empty projection. Reading history and recording a presentation are separate concerns: the store is opened for reading whenever a strategy consumes events, and `--record` governs only whether a `shown` event is appended.

### The shipped path and the test path stop diverging

`LTMService.standard` — the only constructor that uses the real corpus guard — is dead code, because the CLI builds its own service to honor the env-var overrides. Every guard test therefore injects a stub policy, and the shipped guard has zero coverage. This is the common upstream of both containment defects the verify found (memory root unchecked; corpus-root override not tracked by the policy). One construction path is used by both CLI and tests, parameterised by roots, with the containment policy bound to the roots actually in use.

## Implementation Contract

**Behavior**

- `ltm query --strategy human-like` over a corpus with recorded history returns an order that differs from `archival`, and reports non-zero displacement for at least one hit. Today both return identical output; that difference is the acceptance signal for the band fix.
- A turn present in several session files is retrieved once. Its pointer carries the full set of holding sessions, with no element designated as representative (amended 2026-08-22 by #25 — see the Decision above).
- Usage history recorded before a session is resumed still resolves after the resume: the same anchor dereferences to the same text, and the projection counts it.
- `ltm query --strategy <name>` without `--record` applies the named strategy and writes no event.
- Every query path that mutates the derived index holds the same single-writer lock as `ltm build`.

**Interface / data shape**

- `Anchor.source` is 32 lowercase hex characters (project fingerprint). `Anchor` keeps its four-component shape.
- `chunks` is unique on `(project_fingerprint, uuid)`; `session_id` remains a column and is no longer part of any key.
- `ScoredChunk.band` is derived from `channels.count`; the JSON output's `band` field reports the stratum, not the rank.

**Failure modes**

- An index built under the previous anchor format is refused with a message naming `ltm build --full`, the same way an embedding-revision mismatch is refused. It is not silently rebuilt underneath a running query.
- `--k` outside `1...1000` exits non-zero naming the accepted range, rather than trapping inside `prefix(_:)`.
- A sidecar whose length disagrees with `vector_count` refuses the query naming `ltm build --full`, rather than being opened with `try?` and degrading to lexical-only.
- A memory root or derived root that resolves inside any corpus root in use fails before any directory is created.

**Acceptance criteria**

- Strategy effectiveness: an end-to-end test through `LTMService.query` (not through the strategy type in isolation) asserts `human-like` and `archival` produce different orders given non-empty history
- Resume survival: a fixture where the same turn appears in two session files under different `sessionId`s — history recorded against the first still resolves after the second is indexed
- De-duplication: that fixture yields one chunk, not two
- Band population: the measurement from task 1.1 is recorded under `docs/measurements/` and the spec cites it
- Guard coverage: at least one test exercises the shipped containment policy rather than a stub
- Every test that the verify identified as vacuous fails when the behavior it names is broken — checked by breaking it deliberately

**Scope boundaries**

In scope: the four modified specs, the source files named in the proposal's Impact, and their tests. Out of scope: new capabilities, MCP/packaging, tool-payload indexing, evaluation-set construction, and any change to `memory-strategy` or `strategy-comparison` wording.

## Risks / Trade-offs

- [Channel-count banding may degenerate once measured] → task 1.1 measures before adoption; if the distribution is degenerate the rule is rejected and the change stops to re-decide rather than shipping a band that is a rank in disguise
- [Project fingerprint breaks if a project moves] → accepted; rarer than resume and deliberate. Recorded in the spec so it is not discovered later
- [Discarding old anchors is free only now] → the spec states the window explicitly; after real history accumulates the same change needs migration
- [Fixing the band makes comparison produce real output for the first time] → may expose defects in the comparison layer itself (#21 already tracks that); out of scope here but expected
- [The 261 shipped tests passed with all these defects present] → the test-strength work is in this change rather than deferred, because otherwise the next verify is checked by the same blind spots

## Migration Plan

`ltm build --full` after upgrading. Rollback is `git revert` plus another `--full` rebuild; the index carries a layout version and refuses a mismatched binary either way. No event migration, per the decision above.

## Open Questions

(none — the two decisions this change exists to make are made above; the one genuine unknown, band population, is a measurement task with a defined veto, not an open question)
