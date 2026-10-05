## ADDED Requirements

### Requirement: ltm build can audit the index against its derived counts

`ltm build --audit` SHALL, on an incremental build, before scanning the corpus and in place of the structural cursor-coverage gate, run a whole-index audit consisting of: the orphan-chunk count by `NOT IN` over `chunk_sources`; the source keys of `chunk_sources` lacking a `scan_state` row; the number of `chunk_sources` rows whose chunk does not exist; a recomputation of every chunk's `source_count`; and a recomputation of every source's row count compared with `source_chunk_counts`. On an index that owes no audit, when a stored count differs from its recomputation or a `chunk_sources` row points to a missing chunk, this pre-scan audit SHALL record that an audit is owed and fail as described below; when the counts agree and no link dangles but it finds orphan chunks or sources without a cursor, it SHALL refuse with the same message as the structural gate. On a from-scratch build (`--full`, or a layout or embedding-revision mismatch) the index is discarded before the scan, so only the end-of-build audit runs.

A from-scratch build SHALL record, in the same transaction that writes the new layout stamps, that an audit is owed. The build that completes the from-scratch work — the from-scratch build itself, or, when it was interrupted, a later `ltm build` that finishes it incrementally — SHALL run the same audit after its last batch commits, and SHALL clear the record only when the audit passes. A build that leaves any source unmerged (a bounded merge whose budget ran out) has not completed the from-scratch work: it SHALL NOT run that audit and SHALL leave the record in place. While an audit is owed, every `ltm build` SHALL also run the audit before the scan, in place of the structural gate, and SHALL merge nothing when that audit fails.

When an audit fails — `--audit` before the scan, on an index that owes one, or at the end of a from-scratch build — `ltm build` SHALL exit non-zero with a message that:

- states whether this build merged anything;
- names the divergent chunk and source counts when any diverge, the number of dangling links when any exist (saying that the structural gate does not see them and that a new turn reusing such an id may be linked to a wrong source), and the number of coverage findings when any exist;
- says that ltm cannot tell whether the cause is a defect in ltm or a change made to the file outside ltm, and SHALL NOT attribute the failure to either;
- says that the index owes an audit, so later incremental `ltm build`s audit before the scan and merge nothing until the audit passes, and that a from-scratch rebuild (`--full`, or one triggered by an embedding-revision or layout change) discards that record and audits only at its own end — or, when writing that record failed, says the record was not written and the next build will not remember it;
- says what queries do meanwhile: they never audit; while the structural gate admits they keep answering and merging new content and carry the owed line, and when the gate sees the problem they are refused and told to run `ltm build` — for a failure with only coverage findings and agreeing counts, the message SHALL say plainly that queries will be refused, because the gate then sees exactly the audit's coverage findings;
- describes `ltm build --full` as regrowing the index from nothing and auditing it at its end, checking only the from-scratch paths: a failure at its end is worth reporting, and a pass does not rule out a problem on the incremental invalidation and deletion paths, which a later `ltm build --audit` after builds that rewrote sources can show;
- prints source keys on their own line, marked as local paths to redact before posting publicly.

When writing the record fails, the error SHALL still carry the audit's findings. When the record exists, a failure SHALL NOT remove it. The audit and the writing or clearing of the record SHALL run in one write transaction, so that the five checks read one snapshot and no other SQLite connection writes between the audit and the record.

When an audit passes, the final report on stdout SHALL state that it ran, whether it ran before the scan or after the build, and how many chunks and sources it checked. The pre-query merge of `ltm query` SHALL NOT run the audit, owed or not. While an audit is owed, the human and JSON-mode diagnostics of `ltm query`, the recall block and the MCP response SHALL each carry one line saying so and naming `ltm build`. When the pre-query merge was deferred because another process held the build lock — another query's merge, or an `ltm build` such as a from-scratch build after its stamps commit — each of those surfaces SHALL say that another process is building or merging, and the owed line SHALL say that an `ltm build` audits at its own end instead of telling the user to run `ltm build` now. When the structural gate refuses on an index that owes an audit, the query path's refusal SHALL itself direct the user to run `ltm build` rather than `ltm build --full`, so that every surface that prints the error — the CLI and the MCP response — carries the remedy.

#### Scenario: A consistent index passes the audit

- **WHEN** `ltm build --audit` runs on an index built by this binary
- **THEN** it exits 0 and the final report states the audit ran before the scan with the number of chunks and sources checked

#### Scenario: A corrupted count fails the audit and is remembered

- **WHEN** one chunk's `source_count` is set by hand to a value other than its number of `chunk_sources` rows on an index that owes no audit, and `ltm build --audit` runs
- **THEN** it exits non-zero, the message names 1 divergent chunk and 0 divergent sources, states that nothing was merged, says ltm cannot tell the cause, and describes `ltm build --full`; nothing is merged; an audit is owed afterwards: `ltm query` carries the owed line and the next `ltm build` stops before the scan

#### Scenario: A dangling link fails the audit

- **WHEN** a chunk is deleted from outside ltm so that a `chunk_sources` row points to a missing chunk, and `ltm build --audit` runs
- **THEN** the audit fails naming one dangling link, and an audit is owed afterwards

#### Scenario: A failed record write still reports the audit

- **WHEN** an audit fails and writing the owed-audit record fails
- **THEN** the error still carries the audit's findings, and the message says the record was not written

#### Scenario: A from-scratch build ends with the audit

- **WHEN** `ltm build --full` runs over a corpus
- **THEN** the audit runs after the last batch commits, and the build exits 0 with the audit reported in the final report as having run after the build

#### Scenario: An interrupted from-scratch build is audited by the build that finishes it

- **WHEN** a from-scratch build fails after committing some batches, and a later `ltm build` finishes the work incrementally
- **THEN** that later build runs the audit before the scan and again after its last batch, reports both, and no audit is owed afterwards

#### Scenario: A bounded from-scratch build that stops short leaves the audit owed

- **WHEN** a from-scratch build with a time budget stops with sources unmerged
- **THEN** it runs no audit and an audit is still owed

#### Scenario: A rebuild whose end-of-build audit fails stays owed

- **WHEN** the audit at the end of a from-scratch build finds a count that differs from its recomputation, and a later `ltm build` runs
- **THEN** both exit non-zero without attributing the cause; the first says its merge was committed; the later build stops before the scan and merges nothing; an audit is still owed

#### Scenario: An owed audit after an interrupted rebuild

- **WHEN** a from-scratch build was interrupted, a count is then changed outside ltm, and `ltm build` runs
- **THEN** it exits non-zero before the scan, merges nothing, says ltm cannot tell the cause, describes what `ltm build --full` does and does not show, and an audit is still owed

#### Scenario: The query path does not audit and says an audit is owed

- **WHEN** `ltm query` runs its pre-query merge on an index that owes an audit and whose counts the audit would reject, but which the structural gate admits — with `--format recall`, or while another process holds the build lock
- **THEN** the query answers, its diagnostics (the recall block, in recall format) carry the owed-audit line naming `ltm build` — while the lock is held, together with the line saying another process is building or merging, and in its deferred form — and an audit is still owed

#### Scenario: A gate refusal on an index that owes an audit names ltm build

- **WHEN** the structural gate refuses during the pre-query merge of `ltm query` or of an MCP `ltm_query` call, and the index owes an audit
- **THEN** the error itself directs the user to run `ltm build`, not `ltm build --full`

## MODIFIED Requirements

### Requirement: ltm query offers a marker-wrapped recall format sized for hook injection

`ltm query` SHALL accept `--format recall`. Output SHALL be: first line exactly `<!-- ltm:recall v1 -->`; second line the same data-not-instructions banner the MCP tool emits; then the hits, each as `<rank>. [<project>] <timestamp>` followed by an indented snippet of at most 200 characters and an indented pointer line naming every holding session and the turn uuid; then, only when `unmergedSources > 0`, one line `索引落後 <count> 個來源（有界併入未涵蓋，跑一次 ltm build 補齊）`; then, only when the pre-query merge was deferred because another process held the build lock, one line saying so; then, only when the index owes a whole-index audit, one line saying so and naming `ltm build`, in its deferred form when the merge was deferred; last line exactly `<!-- /ltm:recall -->`. Total output SHALL NOT exceed 4,000 characters; when it would, snippets SHALL be truncated first and hits dropped from the tail second, and the closing marker SHALL always be present. `--format recall` and `--json` SHALL be mutually exclusive: given together the command SHALL exit non-zero with a message naming both flags.

#### Scenario: Recall format is marker-delimited

- **WHEN** `ltm query <text> --format recall --k 3` runs with an index that yields three hits
- **THEN** stdout starts with `<!-- ltm:recall v1 -->`, ends with `<!-- /ltm:recall -->`, contains exactly three ranked entries, and is at most 4,000 characters

#### Scenario: Conflicting output formats are refused

- **WHEN** `ltm query <text> --format recall --json` runs
- **THEN** the command exits non-zero, prints no hits, and the message names `--format recall` and `--json`

#### Scenario: Oversized output is truncated from snippets first

- **WHEN** the untruncated recall block would exceed 4,000 characters
- **THEN** snippets are shortened until the block fits or all snippets are at their minimum, hits are then dropped from the last rank upward until it fits, and the closing marker is the last line

#### Scenario: The recall block carries the deferred-merge and owed-audit lines

- **WHEN** `ltm query --format recall` runs on an index that owes an audit while another process holds the build lock
- **THEN** the block contains the deferred-merge line and the deferred form of the owed-audit line before the closing marker
