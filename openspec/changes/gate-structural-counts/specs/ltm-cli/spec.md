## ADDED Requirements

### Requirement: ltm build can audit the index against its derived counts

`ltm build --audit` SHALL, on an incremental build, before scanning the corpus and in place of the structural cursor-coverage gate, run a whole-index audit consisting of: the orphan-chunk count by `NOT IN` over `chunk_sources`; the source keys of `chunk_sources` lacking a `scan_state` row; a recomputation of every chunk's `source_count`; and a recomputation of every source's row count compared with `source_chunk_counts`. When the index owes no audit and a stored count differs from its recomputation, this pre-scan audit SHALL record that an audit is owed and exit non-zero with a message naming how many chunks and how many sources diverge and, when any exist, how many coverage findings it found, stating that nothing was merged, and describing `ltm build --full` as in item 2 below; when the index owes no audit and the counts agree but it finds orphan chunks or sources without a cursor, it SHALL refuse with the same message as the structural gate. On an index that owes an audit, `--audit` behaves as described below for owed audits. On a from-scratch build (`--full`, or a layout or embedding-revision mismatch) the index is discarded before the scan, so only the end-of-build audit runs.

A from-scratch build SHALL record, in the same transaction that writes the new layout stamps, that an audit is owed. The build that completes the from-scratch work — the from-scratch build itself, or, when it was interrupted, a later `ltm build` that finishes it incrementally — SHALL run the same audit after its last batch commits, and SHALL clear the record only when the audit passes. A build that leaves any source unmerged (a bounded merge whose budget ran out) has not completed the from-scratch work: it SHALL NOT run that audit and SHALL leave the record in place. While an audit is owed, every `ltm build` SHALL also run the audit before the scan, in place of the structural gate, and SHALL merge nothing when that audit fails.

When an audit fails on an index that owes one, or at the end of a from-scratch build, `ltm build` SHALL exit non-zero with a message that states whether this build merged anything, names the divergent chunk and source counts when any diverge, names the number of coverage findings when any exist, and attributes the failure in exactly one of two ways — no third. The criterion is whether the counts were known to be correct when this build started, and it coincides with the moment of the failure:

1. **End-of-build failures.** The build started from nothing or its own pre-scan audit passed, so the counts were known correct at its start. The message SHALL identify the problem as a defect in ltm, unless a program other than ltm wrote the file during the build, and SHALL say that `ltm build --full` with the same binary is not a remedy, because a from-scratch build does not take the incremental invalidation and deletion paths and its passing does not show the defect is absent, and that a from-scratch rebuild — `--full`, or one triggered by an embedding-revision or layout change — discards this verdict. When only coverage findings exist, the message SHALL NOT describe a count mismatch. The index SHALL be recorded as having had such a failure.
2. **Pre-scan failures.** The counts grew during a period no audit has covered — a from-scratch build interrupted and finished by a later build, the time before a failed `--audit`, or the time since a recorded end-of-build failure. The message SHALL say it cannot tell a defect from a change made outside ltm, and SHALL mention a recorded earlier failure when there is one. It SHALL describe `ltm build --full` as regrowing the counts while checking only the from-scratch paths: a failure at its end is a defect; a pass does not rule out a defect on the incremental paths, which only a later `ltm build --audit` after builds that rewrote sources can show. A pre-scan failure SHALL NOT change a recorded earlier failure.

When writing the record fails, the message SHALL still report the audit's findings and SHALL say the verdict was not recorded. Source keys in the message SHALL be printed on their own line, marked as local paths to redact before posting publicly. The record that an audit is owed stays.

Source keys in the message SHALL be printed on their own line, marked as local paths to redact before posting publicly. The record that an audit is owed stays.

When an audit passes, the final report on stdout SHALL state that it ran, whether it ran before the scan or after the build, and how many chunks and sources it checked. The pre-query merge of `ltm query` SHALL NOT run the audit, owed or not. While an audit is owed, the human and JSON-mode diagnostics of `ltm query`, the recall block and the MCP response SHALL each carry one line saying so and naming `ltm build`. When the merge was deferred because another process held the build lock — which is the case throughout a from-scratch build, since it records the owed audit before its first batch — each of those surfaces SHALL say that another build is running, and the owed line SHALL say that a from-scratch or auditing build audits at its own end, instead of telling the user to run `ltm build` now. When the structural gate refuses on an index that owes an audit, the query path's refusal SHALL itself direct the user to run `ltm build` rather than `ltm build --full`, so that every surface that prints the error — the CLI and the MCP response — carries the remedy.

#### Scenario: A consistent index passes the audit

- **WHEN** `ltm build --audit` runs on an index built by this binary
- **THEN** it exits 0 and the final report states the audit ran before the scan with the number of chunks and sources checked

#### Scenario: A corrupted count fails the audit with a named remedy

- **WHEN** one chunk's `source_count` is set by hand to a value other than its number of `chunk_sources` rows on an index that owes no audit, and `ltm build --audit` runs
- **THEN** it exits non-zero, the message names 1 divergent chunk and 0 divergent sources, states that nothing was merged and directs the user to `ltm build --full`, nothing is merged, and an audit is owed afterwards: `ltm query` carries the owed line and the next `ltm build` stops before the scan

#### Scenario: A from-scratch build ends with the audit

- **WHEN** `ltm build --full` runs over a corpus
- **THEN** the audit runs after the last batch commits, and the build exits 0 with the audit reported in the final report as having run after the build

#### Scenario: An interrupted from-scratch build is audited by the build that finishes it

- **WHEN** a from-scratch build fails after committing some batches, and a later `ltm build` finishes the work incrementally
- **THEN** that later build runs the audit before the scan and again after its last batch, reports both, and no audit is owed afterwards

#### Scenario: A bounded from-scratch build that stops short leaves the audit owed

- **WHEN** a from-scratch build with a time budget stops with sources unmerged
- **THEN** it runs no audit and an audit is still owed

#### Scenario: An uninterrupted rebuild whose audit fails is reported as an ltm defect

- **WHEN** the audit at the end of an uninterrupted from-scratch build finds a count that differs from its recomputation, and a later `ltm build` runs with no merge in between
- **THEN** both exit non-zero; the first message identifies a defect in ltm and says that `ltm build --full` with the same binary is not a remedy; the later build stops before the scan, merges nothing, says it cannot tell a defect from an outside change and mentions the earlier verdict; the record of the earlier failure is unchanged

#### Scenario: An owed build whose pre-scan audit passes but whose end-of-build audit fails is a defect

- **WHEN** a build on an index that owes an audit passes its pre-scan audit, and its own writes leave a count that differs from its recomputation
- **THEN** the build exits non-zero after committing, attributes the divergence to a defect in ltm, and says that `ltm build --full` with the same binary is not a remedy

#### Scenario: An owed audit after an interrupted rebuild cannot tell a defect from an outside change

- **WHEN** a from-scratch build was interrupted, a count is then changed outside ltm, and `ltm build` runs
- **THEN** it exits non-zero before the scan, merges nothing, says it cannot tell a defect from an outside change, describes what `ltm build --full` does and does not show, and an audit is still owed

#### Scenario: The query path does not audit and says an audit is owed

- **WHEN** `ltm query` runs its pre-query merge on an index that owes an audit and whose counts the audit would reject, but which the structural gate admits — with `--format recall`, or while another process holds the build lock
- **THEN** the query answers, its diagnostics (the recall block, in recall format) carry the owed-audit line naming `ltm build` — while the lock is held, together with the line saying another build is running — and an audit is still owed

#### Scenario: A gate refusal on an index that owes an audit names ltm build

- **WHEN** the structural gate refuses during the pre-query merge of `ltm query` or of an MCP `ltm_query` call, and the index owes an audit
- **THEN** the error itself directs the user to run `ltm build`, not `ltm build --full`
