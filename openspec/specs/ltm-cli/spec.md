# ltm-cli Specification

## Purpose

TBD - created by archiving change 'retrieval-engine-and-cli'. Update Purpose after archive.

## Requirements

### Requirement: ltm build constructs the derivative and writes nowhere else

`ltm build` SHALL run the indexing pipeline incrementally by default and from nothing when `--full` is given. All writes SHALL land under `~/.claude-ltm/`. On success it SHALL exit 0; on failure it SHALL exit non-zero with a message naming the reason (corpus root unreadable, embedding model unavailable, lock held).

#### Scenario: Incremental is the default

- **WHEN** `ltm build` runs twice over an unchanged corpus
- **THEN** the second run exits 0 without re-parsing any file's already-processed bytes, and query results after the second run equal those after the first

#### Scenario: Concurrent builds are refused

- **WHEN** a second `ltm build` starts while another holds the single-writer lock under `~/.claude-ltm/derived`
- **THEN** the second exits non-zero naming the lock as the reason, leaving the running build undisturbed

---
### Requirement: ltm query prints pointered hits in human and JSON forms

`ltm query <text>` SHALL print up to k (default 20) hits. Human-readable output SHALL show rank, project, timestamp, snippet, and the pointer. With `--json`, output SHALL be a JSON array whose objects each carry `project`, `sessions`, `uuid`, `timestamp`, `snippet`, `score`, and `band`; when a reordering strategy is active each object SHALL additionally carry the seam's displacement and reason fields; when event recording produced a presentation identifier for that hit, the object SHALL additionally carry a `presentation` field containing that identifier.

Both forms SHALL surface the hit's full source set, as defined by the `corpus-indexing` capability's "Chunk granularity is one conversation turn with full pointer metadata" Requirement and required on every result by the `retrieval` capability. This capability specifies only the two output shapes:

- **Human-readable**: when the hit has exactly one holding source, the pointer line SHALL be unchanged from its single-source form. When the hit has more than one, the line SHALL name every holding session identifier, using a plural label so that a turn existing in several files is visible without counting.
- **`--json`**: every object SHALL carry a `sessions` array of the holding session identifiers, with at least one element. This field SHALL be present unconditionally, including for single-source hits — unlike `displacement` and `presentation`, which are absent when the query has no such concept, every hit always has at least one source.

#### Scenario: JSON output is machine-complete

- **WHEN** `ltm query "fixture phrase" --json` returns 3 hits
- **THEN** the output parses as a JSON array of 3 objects and every object contains non-empty `project`, `uuid`, `timestamp` fields, a non-empty `sessions` array, and `snippet`, `score`, `band` — and no object carries a singular `sessionId` field

#### Scenario: JSON output exposes the presentation identifier when events were recorded

- **WHEN** `ltm query "fixture phrase" --json --record` returns hits and successfully writes events
- **THEN** every object in the output array carries a `presentation` field, and running the same query without `--record` produces objects with no `presentation` field

#### Scenario: JSON carries the sessions array for both single-source and multi-source hits

- **GIVEN** a corpus where one turn is held by two session files and another turn is held by exactly one
- **WHEN** `ltm query --json` retrieves both
- **THEN** the multi-source hit's `sessions` array has two elements and the single-source hit's has one

#### Scenario: Human-readable output names every source only when there is more than one

- **GIVEN** the same corpus as the preceding scenario
- **WHEN** `ltm query` prints both hits in human-readable form
- **THEN** the single-source hit's pointer line is unchanged from its single-source form, and the multi-source hit's pointer line names both session identifiers under a plural label


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
### Requirement: Scope resolution mirrors the retrieval default

When the working directory maps to exactly one project under the corpus root, that project SHALL be the query scope. Otherwise `ltm query` SHALL exit non-zero instructing the caller to pass `--project <name>` or `--all-projects`. `--all-projects` SHALL be the only way to search across projects.

#### Scenario: Unmappable working directory asks for explicit scope

- **WHEN** `ltm query` runs from a directory that maps to no project and neither scope flag is given
- **THEN** it exits non-zero, names both scope flags in the message, and produces no results

---
### Requirement: Failure messages name their remediation

Every non-zero exit of `ltm query` caused by index state SHALL name the command that fixes it: a missing index and an embedding-revision mismatch SHALL both name `ltm build` in the error message.

#### Scenario: Missing index points to build

- **WHEN** `ltm query` runs and `~/.claude-ltm/derived` does not exist
- **THEN** it exits non-zero and the error message contains `ltm build`

---
### Requirement: Event recording is opt-in and off by default

`ltm query` SHALL NOT append any event to the memory event store unless `--record` is given. With `--record`, it SHALL append one `shown` event per emitted hit through the facade's event sink.

#### Scenario: Default query leaves the event log untouched

- **WHEN** `ltm query` runs without `--record` and returns hits
- **THEN** the event store under `~/.claude-ltm/memory/` has the same content after the query as before

#### Scenario: Recording emits one shown event per hit

- **WHEN** `ltm query --record` returns 5 hits
- **THEN** exactly 5 `shown` events are appended, each anchored to the corresponding hit's chunk