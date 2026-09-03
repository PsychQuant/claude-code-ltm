## ADDED Requirements

### Requirement: ltm query can bound the pre-query merge and reports the shortfall

`ltm query` SHALL accept `--max-refresh-seconds <N>` where N is an integer ≥ 1. When given, the incremental merge that runs before retrieval SHALL stop at the first batch boundary reached after N seconds of wall-clock time, leaving every already-committed batch in place and committing nothing partial, and retrieval SHALL run on the index as it then stands. The refresh report SHALL carry the number of source files not yet merged and a flag that the budget was exhausted. In both human-readable and `--json` modes the shortfall SHALL be printed on **stderr** as `索引落後 <count> 個來源（併入預算 <N> s 已用完）`, leaving `--json` stdout a bare JSON array of hits as the existing output requirement demands. Without the flag the merge SHALL run to completion as before, the report SHALL show zero unmerged sources and `budgetExhausted` false, and no shortfall line SHALL be printed.

#### Scenario: Large backlog is truncated at a batch boundary

- **WHEN** the corpus has grown by more sources than can be merged in N seconds and `ltm query <text> --max-refresh-seconds N` runs
- **THEN** the command returns after N seconds plus retrieval time, the index contains only whole committed batches, and the report names the unmerged source count greater than zero

#### Scenario: Small backlog merges fully within the budget

- **WHEN** the backlog merges in less than N seconds
- **THEN** the report shows zero unmerged sources and `budgetExhausted` false, stderr carries no shortfall line, and stdout is identical to a run without the flag

#### Scenario: The next merge completes the truncated one

- **WHEN** a bounded query left sources unmerged and a later `ltm build` runs
- **THEN** the resulting index is byte-equivalent to one produced by a single uninterrupted build over the same corpus (invariant 2)

### Requirement: ltm query can exclude the caller's own session

`ltm query` SHALL accept `--exclude-session <id>`. A hit SHALL be omitted from the results when its `sessions` set is a subset of the excluded set. A hit whose `sessions` set contains any identifier outside the excluded set SHALL be kept unchanged, including its full `sessions` set. Exclusion SHALL apply after ranking and SHALL NOT alter the relative order of the remaining hits.

#### Scenario: A turn held only by the excluded session is dropped

- **WHEN** a hit's `sessions` set is `{S}` and `--exclude-session S` is given
- **THEN** the hit does not appear in the output

#### Scenario: A resume copy in another session keeps the turn

- **WHEN** a hit's `sessions` set is `{S, T}` and `--exclude-session S` is given
- **THEN** the hit appears with `sessions` `{S, T}` unchanged

##### Example: Exclusion on a ranked list

| Rank before | sessions | `--exclude-session S` result |
| ----------- | -------- | ---------------------------- |
| 1 | `{S}` | dropped |
| 2 | `{S, T}` | rank 1, sessions `{S, T}` |
| 3 | `{U}` | rank 2 |

### Requirement: ltm query offers a marker-wrapped recall format sized for hook injection

`ltm query` SHALL accept `--format recall`. Output SHALL be: first line exactly `<!-- ltm:recall v1 -->`; second line the same data-not-instructions banner the MCP tool emits; then the hits, each as `<rank>. [<project>] <timestamp>` followed by an indented snippet of at most 200 characters and an indented pointer line naming every holding session and the turn uuid; then, only when the merge budget was exhausted, one line `索引落後 <count> 個來源（併入預算 <N> s 已用完）`; last line exactly `<!-- /ltm:recall -->`. Total output SHALL NOT exceed 4,000 characters; when it would, snippets SHALL be truncated first and hits dropped from the tail second, and the closing marker SHALL always be present. `--format recall` and `--json` SHALL be mutually exclusive: given together the command SHALL exit non-zero with a message naming both flags.

#### Scenario: Recall format is marker-delimited

- **WHEN** `ltm query <text> --format recall --k 3` runs with an index that yields three hits
- **THEN** stdout starts with `<!-- ltm:recall v1 -->`, ends with `<!-- /ltm:recall -->`, contains exactly three ranked entries, and is at most 4,000 characters

#### Scenario: Conflicting output formats are refused

- **WHEN** `ltm query <text> --format recall --json` runs
- **THEN** the command exits non-zero, prints no hits, and the message names `--format recall` and `--json`

#### Scenario: Oversized output is truncated from snippets first

- **WHEN** the untruncated recall block would exceed 4,000 characters
- **THEN** snippets are shortened until the block fits or all snippets are at their minimum, hits are then dropped from the last rank upward until it fits, and the closing marker is the last line
