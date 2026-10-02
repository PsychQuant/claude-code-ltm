## ADDED Requirements

### Requirement: ltm build can audit the index against its derived counts

`ltm build --audit` SHALL, before scanning the corpus and in place of the structural cursor-coverage gate, run a whole-index audit consisting of: the orphan-chunk count by `NOT IN` over `chunk_sources`; the source keys of `chunk_sources` lacking a `scan_state` row; a recomputation of every chunk's `source_count`; and a recomputation of every source's row count compared with `source_chunk_counts`. Every from-scratch build (`--full`, or a layout or embedding-revision mismatch) SHALL run the same audit after its last batch commits. When a stored count differs from its recomputation, `ltm build` SHALL exit non-zero with a message naming how many chunks and how many sources diverge and directing the user to `ltm build --full`. When the counts agree but the audit finds orphan chunks or sources without a cursor, it SHALL refuse with the same message as the structural gate. When the audit passes, the final report on stdout SHALL state that the audit ran and how many chunks and sources it checked. The pre-query merge of `ltm query` SHALL NOT run the audit.

#### Scenario: A consistent index passes the audit

- **WHEN** `ltm build --audit` runs on an index built by this binary
- **THEN** it exits 0 and the final report states the audit ran with the number of chunks and sources checked

#### Scenario: A corrupted count fails the audit with a named remedy

- **WHEN** one chunk's `source_count` is set by hand to a value other than its number of `chunk_sources` rows, and `ltm build --audit` runs
- **THEN** it exits non-zero, the message names 1 divergent chunk and 0 divergent sources and directs the user to `ltm build --full`, and nothing is merged

#### Scenario: A from-scratch build ends with the audit

- **WHEN** `ltm build --full` runs over a corpus
- **THEN** the audit runs after the last batch commits, and the build exits 0 with the audit reported in the final report

#### Scenario: The query path does not audit

- **WHEN** `ltm query` runs its pre-query merge
- **THEN** the merge runs the structural gate and not the whole-index audit
