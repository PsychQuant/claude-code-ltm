## ADDED Requirements

### Requirement: ltm build can audit the index against its derived counts

`ltm build --audit` SHALL, before scanning the corpus and in place of the structural cursor-coverage gate, run a whole-index audit consisting of: the orphan-chunk count by `NOT IN` over `chunk_sources`; the source keys of `chunk_sources` lacking a `scan_state` row; a recomputation of every chunk's `source_count`; and a recomputation of every source's row count compared with `source_chunk_counts`. When a stored count differs from its recomputation, this pre-scan audit SHALL exit non-zero with a message naming how many chunks and how many sources diverge, stating that nothing was merged, and directing the user to `ltm build --full`; when the counts agree but it finds orphan chunks or sources without a cursor, it SHALL refuse with the same message as the structural gate.

A from-scratch build (`--full`, or a layout or embedding-revision mismatch) SHALL record, in the same transaction that writes the new layout stamps, that an audit is owed. The build that completes the from-scratch work — the from-scratch build itself, or, when it was interrupted, the next `ltm build` that finishes it incrementally — SHALL run the same audit after its last batch commits, and SHALL clear the record only when the audit passes. A build that leaves any source unmerged (a bounded merge whose budget ran out) has not completed the from-scratch work: it SHALL NOT run that audit and SHALL leave the record in place. When that end-of-build audit fails, `ltm build` SHALL exit non-zero with a message that states the rebuild was committed, names how many chunks and sources diverge and any coverage findings, identifies the divergence as a defect in ltm rather than damage to the index, and SHALL NOT direct the user to `ltm build --full` as the remedy; the record stays, so the next `ltm build` audits again.

When an audit passes, the final report on stdout SHALL state that it ran, whether it ran before the scan or after the build, and how many chunks and sources it checked. The pre-query merge of `ltm query` SHALL NOT run the audit, owed or not; an owed audit waits for the next `ltm build`.

#### Scenario: A consistent index passes the audit

- **WHEN** `ltm build --audit` runs on an index built by this binary
- **THEN** it exits 0 and the final report states the audit ran with the number of chunks and sources checked

#### Scenario: A corrupted count fails the audit with a named remedy

- **WHEN** one chunk's `source_count` is set by hand to a value other than its number of `chunk_sources` rows, and `ltm build --audit` runs
- **THEN** it exits non-zero, the message names 1 divergent chunk and 0 divergent sources and directs the user to `ltm build --full`, and nothing is merged

#### Scenario: A from-scratch build ends with the audit

- **WHEN** `ltm build --full` runs over a corpus
- **THEN** the audit runs after the last batch commits, and the build exits 0 with the audit reported in the final report as having run after the build

#### Scenario: An interrupted from-scratch build is audited by the build that finishes it

- **WHEN** a from-scratch build fails after committing some batches, and a later `ltm build` finishes the work incrementally
- **THEN** that later build runs the audit after its last batch, reports it, and no audit is owed afterwards

#### Scenario: A failed end-of-build audit is reported as an ltm defect

- **WHEN** the audit at the end of a build that completes from-scratch work finds a count that differs from its recomputation
- **THEN** `ltm build` exits non-zero, the message says the rebuild was committed and that this is a defect in ltm, it does not offer `ltm build --full` as the remedy, and an audit is still owed

#### Scenario: The query path does not audit

- **WHEN** `ltm query` runs its pre-query merge, including when an audit is owed
- **THEN** the merge runs the structural gate and not the whole-index audit, and an owed audit remains owed
