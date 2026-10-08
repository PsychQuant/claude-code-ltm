## ADDED Requirements

### Requirement: Chunk-source counts are engine-maintained derived data

The derived index SHALL record, for every chunk, how many `chunk_sources` rows reference it (`chunks.source_count`), and, for every source key that holds at least one `chunk_sources` row, how many rows it holds (`source_chunk_counts`). A source key holding no rows SHALL have no `source_chunk_counts` row. Both SHALL be written only by SQLite triggers on `chunk_sources`, inside the transaction of the statement that changes `chunk_sources`; application SQL SHALL NOT assign `source_count` nor write `source_chunk_counts`. The key columns of a `chunk_sources` row (`chunk_id`, `source_key`) SHALL be immutable: an update to either SHALL abort. No SQL statement in the indexing code SHALL write `chunk_sources` with REPLACE conflict resolution, because a REPLACE deletion does not fire DELETE triggers under SQLite's default `recursive_triggers = OFF`. Both counts are part of the pure derivative: after any sequence of incremental builds they SHALL equal a recomputation from `chunk_sources`, and an incremental build SHALL leave them equal to what a full rebuild over the same corpus produces.

#### Scenario: Counts follow inserts, re-observation and deletion

- **WHEN** a build inserts turns, re-observes an existing turn in the same source, observes the same turn in a second source, and later deletes one of the two sources
- **THEN** every chunk's `source_count` and every source's count equal a recomputation from `chunk_sources`, and the deleted source has no `source_chunk_counts` row

##### Example: one turn held by two sources, then one source deleted

| Step | `chunk_sources` rows | `source_count` of T | `source_chunk_counts` |
| ---- | -------------------- | ------------------- | --------------------- |
| insert T from s1 | (T,s1) | 1 | s1→1 |
| re-observe T in s1 (upsert updates) | (T,s1) | 1 | s1→1 |
| observe T in s2 | (T,s1),(T,s2) | 2 | s1→1, s2→1 |
| delete source s1 | (T,s2) | 1 | s2→1 |

#### Scenario: Changing a link's key is refused by the engine

- **WHEN** any statement updates `chunk_id` or `source_key` of an existing `chunk_sources` row
- **THEN** the statement aborts and neither count changes

#### Scenario: Removing a trigger is detected

- **WHEN** the INSERT or the DELETE trigger on `chunk_sources` is dropped and the write paths are exercised
- **THEN** the equivalence assertion between the stored counts and the recomputation fails

---
### Requirement: The cursor-coverage gate reads structural counts

Before an incremental build scans the corpus, unless it runs the whole-index audit in this check's place (`ltm build --audit`, or `ltm build` on an index that owes an audit), it SHALL refuse to proceed when the derived counts show a chunk whose `source_count` is 0, or a source key present in `source_chunk_counts` that has no `scan_state` row. The check SHALL read the chunks whose `source_count` is 0 through a partial index restricted to that condition, and SHALL compare the source keys of `source_chunk_counts` against those of `scan_state`; it SHALL NOT walk `chunk_sources`. The refusal SHALL state, when there are any, the number of chunks whose `source_count` is 0, and, when there are any, the number of source keys in `source_chunk_counts` without a `scan_state` row, naming at most the first three of those keys in sorted order; it SHALL say that these are readings of the maintained counts, because when a count has drifted a chunk that has links can read as having none (#61 R10); it SHALL NOT count the orphan-chunk entry (which travels in the same list as the keys) as a source or name it among them (#61 R9), and SHALL direct the user to `ltm build --full`, or, when the index owes an audit, to `ltm build`. **The check is sound only while the derived counts agree with `chunk_sources`**: for every such index that owes no audit, its decisions SHALL equal those of the whole-index formulation, and its refusal SHALL list the same findings (orphan chunks by `NOT IN` over `chunk_sources`; source keys of `chunk_sources` `EXCEPT` those of `scan_state`). When the counts have drifted — `chunk_sources` or the counts changed other than through the triggers, for example by a write with the triggers disabled or dropped, a direct write to a count, or dropping and recreating `chunk_sources` — the two formulations can disagree in either direction, and only the whole-index audit (`ltm build --audit`, the audit an owed index runs, and the audit at the end of a from-scratch build) detects it. Deleting a chunk row from outside ltm is a different inconsistency: it leaves the chunk's `chunk_sources` rows dangling while the counts still agree, neither formulation sees it, and only the audit's dangling-link check finds it. Within the threat model of #44 — a rolled-back transaction, an index from an older binary, a deleted cursor row — the counts change in the same transactions as `chunk_sources`, so they agree and the refusal semantics are kept; the per-build check trusts the trigger bodies. The equivalence tests check the shipped definitions; the audit checks the counts the triggers have written so far, not the definitions stored in a given index file, so a trigger replaced under the same name passes the audit until a write goes through it (#61 R9). A from-scratch build SHALL NOT run this check.

#### Scenario: A chunk that lost its last source is refused

- **WHEN** the last `chunk_sources` row of a chunk is deleted and an incremental build runs
- **THEN** the build refuses, naming one chunk without a source mapping, and merges nothing

#### Scenario: A source without a cursor is refused

- **WHEN** a source key holds chunks and its `scan_state` row is deleted, and an incremental build runs
- **THEN** the build refuses, naming that source key, and merges nothing

#### Scenario: The orphan check uses the partial index

- **WHEN** the query plan of the orphan-count statement is inspected on a layout-6 index
- **THEN** every step of the plan that reads `chunks` goes through the partial index over `source_count = 0`
