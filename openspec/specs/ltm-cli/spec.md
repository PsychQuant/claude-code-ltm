# ltm-cli Specification

## Purpose

TBD - created by archiving change 'retrieval-engine-and-cli'. Update Purpose after archive.

## Requirements

### Requirement: ltm build constructs the derivative and writes nowhere else

`ltm build` SHALL run the indexing pipeline incrementally by default and from nothing when `--full` is given. All writes SHALL land under `~/.claude-ltm/`. On success it SHALL exit 0; on failure it SHALL exit non-zero with a message naming the reason. **This sentence deliberately does not enumerate the reasons.** The original wording listed five by name and fell two behind the code within one round (`stateUnreadable`, `lockUnsafe`); the replacement claimed the reasons were "exactly" three named enums and offered a thirty-second check — and both halves were false, because the build path also throws `CocoaError` (from the derived-file open) and `IndexDatabase.DatabaseError`, and `switch` exhaustiveness constrains only the one enum being switched over, not everything a function may `throw`. That is the same defect twice: a claim of completeness with no mechanism behind it. What is actually required is behavioural and checkable without enumerating anything: **every failure SHALL exit non-zero and SHALL print a message that names the specific condition — never a bare type name, a raw `errno`, or an empty stream.**

`ltm build` SHALL write progress to **stderr** and reserve stdout for the final report, so that a caller may consume stdout without filtering. It SHALL emit the scan denominator (source files, new chunks, vectors needed) **before any embedding begins**, including when the scan finds nothing new; SHALL emit an opening line with the file denominator **before any file is scanned** and a heartbeat during scanning at whichever comes first of a fixed file count or a fixed interval, the interval side checked at file boundaries (#48); and SHALL emit a heartbeat during embedding at whichever comes first of a fixed chunk count or a fixed interval. `--quiet` SHALL suppress every progress line and SHALL NOT suppress the final report. A failure to write progress SHALL NOT fail the build.

`ltm build` SHALL accept `--batch-chunks N` (equivalently `LTM_BUILD_BATCH_CHUNKS`) and `--memory-budget-mb N` (equivalently `LTM_BUILD_MEMORY_BUDGET_MB`). `--batch-chunks N` SHALL be a true upper bound on batch size: batches are assembled at chunk granularity and a source MAY be split across batches at any chunk boundary, each committed slice carrying a cursor verifiable against the source file (#47). The enforcement point is `productionBatchingHonoursTheDeclaredBound`, which runs a real build and asserts the largest batch does not exceed `N`. **History**: before #47 batches were assembled whole-source and the bound was `max(N−1,0) + largestSource` — a formula that had itself replaced an earlier wording wrong by 46% and copied to six places at once; the formula and its pinning test were deleted with the whole-source assembly rather than restated here. When a memory budget is given and the estimated vector accumulation of the largest batch exceeds it, `ltm build` SHALL refuse **before embedding anything** with a message naming remedies, and SHALL state that the budget bounds vector accumulation rather than total peak memory. There SHALL be no default budget: this repository has no measurement that supports a threshold, and inventing one substitutes a fabricated number for the operating system as the thing that decides the outcome.

#### Scenario: Incremental is the default

- **WHEN** `ltm build` runs twice over an unchanged corpus
- **THEN** the second run exits 0 without re-parsing any file's already-processed bytes, and query results after the second run equal those after the first

#### Scenario: Concurrent builds are refused

- **WHEN** a second `ltm build` starts while another holds the single-writer lock under `~/.claude-ltm/derived`
- **THEN** the second exits non-zero naming the lock as the reason, leaving the running build undisturbed

The single-writer lock SHALL be held for the whole build — there is no mid-build release at batch boundaries. This retracts #44 Expected ② (decision recorded in #53): the loop state assembled between lock acquisition and the batch loop is classified by the mechanical procedure in `IndexBuilder.build()`'s opening comment, and two bindings are destructive under mid-build release (`scan.invalidatedSources` deletes another writer's freshly committed chunks; `grouped` re-inserts from a stale snapshot), with the deferred-commit path for invalidated sources (#47) additionally requiring that a source's delete+insert complete within one build.

What batching **does** deliver to a concurrent reader is weaker and is the property this spec records instead: the query path never takes the writer lock (`FileLock.acquire` has exactly one call site, inside `build()` — check: `grep -rn "FileLock.acquire" Sources/ | grep -v "//"`), and on encountering a held lock it reports deferral and answers on the existing index (check: the `lockHeld` catch in `LTMService.refreshIncrementally`). Because each batch commits in its own transaction with the vector sidecar landed first, a reader sees committed batches progressively while the build runs. **Honest boundary**: progressive visibility is an inference from construction — no dedicated test pins it. The accepted residual gap is that content newer than the running build's scan snapshot waits for the next merge. For an unbounded merge that staleness is bounded by the build's duration. For a merge bounded by `--max-refresh-seconds` it is **not**: the merge stops at a batch boundary with sources unmerged, and those sources wait until a later merge (bounded or not) reaches them — the bound on staleness is then the sum of budgets across calls, and a caller that always passes a budget smaller than one batch never catches up (the hook exports `LTM_BUILD_BATCH_CHUNKS=200` for this reason). **Lock frequency**: the proactive-recall hook runs a bounded merge on every gated prompt, so the writer lock is now taken as often as the gate admits, not only on explicit `ltm build`; a concurrent MCP `ltm_query` that meets the held lock defers and answers on the existing index as before. The contention itself is tracked in #65.

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

`ltm query` SHALL NOT append any event to the memory event store unless `--record` or `--compare` is given. With either, it SHALL append one `shown` event per emitted hit through the facade's event sink.

`--compare` is named here rather than only in the comparison requirement below because this sentence is where a reader checks the "events are off by default" property. Stated as a bare `--record` universal, it was false against shipped behaviour the moment comparison mode landed, and a reader auditing the privacy-relevant default would have gotten two answers from the same document.

#### Scenario: Default query leaves the event log untouched

- **WHEN** `ltm query` runs without `--record` and returns hits
- **THEN** the event store under `~/.claude-ltm/memory/` has the same content after the query as before

#### Scenario: Recording emits one shown event per hit

- **WHEN** `ltm query --record` returns 5 hits
- **THEN** exactly 5 `shown` events are appended, each anchored to the corresponding hit's chunk

---
### Requirement: ltm query offers an opt-in comparison mode

`ltm query` SHALL accept a `--compare` flag. With it, the command SHALL rank one retrieved candidate list with two strategies, present the interleaved ordering, and persist the presentation record and shown events for that presentation. Without it, the command's behaviour SHALL be unchanged.

`--compare` SHALL imply `--record`. Requiring both would offer a combination — comparing without recording — that produces nothing and only changes what the user sees, so the flag enables persistence for that invocation on its own. Passing both SHALL be accepted and behave the same as passing `--compare` alone.

`--compare` and `--strategy` SHALL be mutually exclusive, and giving both SHALL fail with a usage error naming the conflict. `--strategy` selects the single strategy that ranks the results; `--compare` ranks with two. Silently letting one win would make the printed ordering unattributable to either flag.

When no event store is available, `--compare` SHALL fail with the existing message for that condition and SHALL NOT print results. Printing an interleaved ordering whose record was lost is indistinguishable, to the reader of the output, from one that was recorded.

**This condition is not reachable through the CLI as shipped, and saying so is part of the requirement.** The `--compare` branch provisions both an event store and a presentation-record store unconditionally, so the refusal is enforced at the service boundary and exercised there, not from a command line. A reader who takes the paragraph above as describing a CLI-level test would be looking for something that cannot exist: there is no argument combination that reaches `--compare` without both stores. The requirement is retained here because it constrains what the CLI must do **if** that provisioning ever becomes conditional — and the day it does, this paragraph is what says the refusal must survive the change (#36).

The human-readable output in comparison mode SHALL have the same shape as an ordinary query — one line per hit with its pointer — and SHALL NOT label which strategy contributed each position. Which side supplied a position is attribution data for the scorer; showing it to the user during the comparison is what interleaved evaluation exists to avoid.

#### Scenario: Comparison mode records a presentation

- **WHEN** `ltm query --compare` runs with an event store available and returns hits
- **THEN** one presentation record is written describing which strategy contributed each position, and one `shown` event per emitted hit refers to that presentation

#### Scenario: The flag implies recording

- **WHEN** `ltm query --compare` runs without `--record`
- **THEN** events are appended exactly as if `--record` had been given

#### Scenario: Comparison and single-strategy selection conflict

- **WHEN** `ltm query --compare --strategy human-like` runs
- **THEN** the command fails with a usage error naming the conflict, and no query is executed

#### Scenario: Output does not reveal attribution

- **WHEN** `ltm query --compare` prints hits in human-readable form
- **THEN** no line indicates which of the two strategies contributed that position

<!-- @trace
source: wire-evaluation-machinery
updated: 2026-08-23
code:
  - docs/measurements/2026-08-23-known-item-retrieval.md
  - Sources/LTMIndex/RetrievalEngine.swift
  - Tests/LTMServiceTests/CLICommandTests.swift
  - scripts/measure-retrieval/main.swift
  - Sources/LTMEval/PresentationRecordStore.swift
  - CLAUDE.md
  - Sources/LTMEval/KnownItemHarness.swift
  - CHANGELOG.md
  - Package.swift
  - Sources/LTMMemory/CanonicalStore.swift
  - Sources/LTMMemory/EventStore.swift
  - Sources/ltm/Commands.swift
  - Sources/LTMService/StrategyRegistry.swift
  - Tests/LTMServiceTests/ComparisonModeTests.swift
  - Tests/LTMEvalTests/KnownItemHarnessTests.swift
  - Sources/LTMService/LTMService.swift
-->

---
### Requirement: ltm query can bound the pre-query merge and reports the shortfall

`ltm query` SHALL accept `--max-refresh-seconds <N>` where N is an integer ≥ 1. When given, the incremental merge that runs before retrieval SHALL process only append (new) sources and SHALL skip rewritten sources (an `invalidatedSources` entry that also has new chunks) entirely — a rewrite is a delete + full re-insert that cannot be safely stopped between batches, so a bounded merge leaves it unmerged with its cursor untouched rather than start it. The deadline is the launch time plus N and **covers the scan phase**: the scan is not interruptible, so if the scan alone exceeds N the first batch boundary is already past the deadline and zero append batches merge; otherwise append sources merge until the deadline, stopping at the first batch boundary reached after it, leaving every already-committed batch in place and committing nothing partial. Retrieval then runs on the index as it stands. So the pre-query merge is bounded by roughly N (scan included), plus retrieval — not N on top of an unbounded scan. The refresh report SHALL carry the number of source files not yet merged and a flag that the budget was exhausted. In both human-readable and `--json` modes the shortfall SHALL be printed on **stderr** as `索引落後 <count> 個來源（有界併入未涵蓋，跑一次 ltm build 補齊）` **whenever `unmergedSources > 0`** (which includes rewritten sources skipped even when the deadline was not reached — the count, not the budget-exhausted flag, is the trigger), leaving `--json` stdout a bare JSON array of hits as the existing output requirement demands. Without the flag the merge SHALL run to completion as before, the report SHALL show zero unmerged sources and `budgetExhausted` false, and no shortfall line SHALL be printed.

#### Scenario: Large backlog is truncated at a batch boundary

- **WHEN** the corpus has grown by more sources than can be merged in N seconds and `ltm query <text> --max-refresh-seconds N` runs
- **THEN** the command returns after roughly N seconds (scan included) plus retrieval time, the index contains only whole committed batches, and the report names the unmerged source count greater than zero

#### Scenario: Small backlog merges fully within the budget

- **WHEN** the backlog merges in less than N seconds
- **THEN** the report shows zero unmerged sources and `budgetExhausted` false, stderr carries no shortfall line, and stdout is identical to a run without the flag

#### Scenario: The next merge completes the truncated one

- **WHEN** a bounded query left sources unmerged and a later `ltm build` runs
- **THEN** the resulting index is byte-equivalent to one produced by a single uninterrupted build over the same corpus (invariant 2)

---
### Requirement: ltm query can exclude the caller's own session

`ltm query` SHALL accept `--exclude-session <id>`. A hit SHALL be omitted from the results when its `sessions` set is a subset of the excluded set. A hit whose `sessions` set contains any identifier outside the excluded set SHALL be kept unchanged, including its full `sessions` set. Exclusion SHALL apply after ranking and SHALL NOT alter the relative order of the remaining hits. The `--k` limit SHALL apply after exclusion: an excluded hit does not consume a result slot, so a query whose top-k candidates all belong to the excluded session returns up to k hits from the remaining candidates **as long as those candidates lie within the examined pool**. Because exclusion is post-ranking, the pool is bounded: the implementation examines at most 1,000 fused candidates (fetching 4·k and quadrupling until k survive or the cap is hit). If more than 1,000 top-ranked candidates all belong to the excluded set, the command returns fewer than k even though survivors exist beyond the cap — guaranteeing k would require a whole-corpus scan per query.

#### Scenario: A turn held only by the excluded session is dropped

- **WHEN** a hit's `sessions` set is `{S}` and `--exclude-session S` is given
- **THEN** the hit does not appear in the output

#### Scenario: Excluded hits do not consume result slots

- **WHEN** the top two ranked candidates both have `sessions` `{S}`, three further candidates exist, and `ltm query --k 2 --exclude-session S` runs
- **THEN** the output contains two hits, both from the further candidates, in their ranked order

#### Scenario: A resume copy in another session keeps the turn

- **WHEN** a hit's `sessions` set is `{S, T}` and `--exclude-session S` is given
- **THEN** the hit appears with `sessions` `{S, T}` unchanged

##### Example: Exclusion on a ranked list

| Rank before | sessions | `--exclude-session S` result |
| ----------- | -------- | ---------------------------- |
| 1 | `{S}` | dropped |
| 2 | `{S, T}` | rank 1, sessions `{S, T}` |
| 3 | `{U}` | rank 2 |

---
### Requirement: ltm query offers a marker-wrapped recall format sized for hook injection

`ltm query` SHALL accept `--format recall`. Output SHALL be: first line exactly `<!-- ltm:recall v1 -->`; second line the same data-not-instructions banner the MCP tool emits; then the hits, each as `<rank>. [<project>] <timestamp>` followed by an indented snippet of at most 200 characters and an indented pointer line naming every holding session and the turn uuid; then, only when `unmergedSources > 0`, one line `索引落後 <count> 個來源（有界併入未涵蓋，跑一次 ltm build 補齊）`; last line exactly `<!-- /ltm:recall -->`. Total output SHALL NOT exceed 4,000 characters; when it would, snippets SHALL be truncated first and hits dropped from the tail second, and the closing marker SHALL always be present. `--format recall` and `--json` SHALL be mutually exclusive: given together the command SHALL exit non-zero with a message naming both flags.

#### Scenario: Recall format is marker-delimited

- **WHEN** `ltm query <text> --format recall --k 3` runs with an index that yields three hits
- **THEN** stdout starts with `<!-- ltm:recall v1 -->`, ends with `<!-- /ltm:recall -->`, contains exactly three ranked entries, and is at most 4,000 characters

#### Scenario: Conflicting output formats are refused

- **WHEN** `ltm query <text> --format recall --json` runs
- **THEN** the command exits non-zero, prints no hits, and the message names `--format recall` and `--json`

#### Scenario: Oversized output is truncated from snippets first

- **WHEN** the untruncated recall block would exceed 4,000 characters
- **THEN** snippets are shortened until the block fits or all snippets are at their minimum, hits are then dropped from the last rank upward until it fits, and the closing marker is the last line
