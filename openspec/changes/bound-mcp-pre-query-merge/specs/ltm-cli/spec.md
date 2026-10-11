## ADDED Requirements

### Requirement: The MCP ltm_query call bounds its pre-query merge by default and reports the shortfall

Every MCP `ltm_query` call SHALL run its pre-query merge with a bound, using the same semantics as `ltm query --max-refresh-seconds` in "ltm query can bound the pre-query merge and reports the shortfall": append sources only, rewritten sources skipped with their cursors untouched, a deadline that starts before the scan, a stop at the first batch boundary reached after the deadline, and nothing partial committed. The bound SHALL be 20 seconds unless the environment variable `LTM_MCP_REFRESH_SECONDS` holds a positive integer, in which case that many seconds SHALL be the bound. The variable SHALL be read once when the server starts.

When `LTM_MCP_REFRESH_SECONDS` is set to anything other than a positive integer, the server SHALL use 20 seconds and every `ltm_query` response from that server process SHALL carry a warning line naming the variable and the rejected value. The call SHALL NOT fail because of it.

Whenever the refresh report's `unmergedSources` is greater than zero, the MCP response SHALL include the line `索引落後 <count> 個來源（有界併入未涵蓋，跑一次 ltm build 補齊）` among its warnings, with or without hits. The CLI's stderr line and the recall format's lag line SHALL use the same wording from the same source.

The bound is not an upper bound on the call: the deadline is checked only at the start of each batch, so the work before the first check, the batch in progress at the deadline and the work after the last batch run to completion whatever the bound is (the stages are named in "ltm query can bound the pre-query merge and reports the shortfall"), and retrieval runs afterwards. No response, document or log line SHALL state that a call finished within the bound.

#### Scenario: A large backlog is cut at a batch boundary and reported

- **WHEN** the corpus has grown by more sources than can be merged within the bound and an MCP `ltm_query` call is made
- **THEN** the call commits only whole batches, answers from the index as it stands, and its response includes the lag line with an unmerged count greater than zero

#### Scenario: A small backlog changes nothing

- **WHEN** the backlog merges before the deadline
- **THEN** the response has no lag line and its hits are identical to an unbounded call on the same corpus

#### Scenario: An invalid override is ignored with a warning

- **WHEN** the server starts with `LTM_MCP_REFRESH_SECONDS=abc` and an `ltm_query` call is made
- **THEN** the call succeeds, the merge is bounded at 20 seconds, and the response carries a warning naming `LTM_MCP_REFRESH_SECONDS` and `abc`

##### Example: resolving the bound

| `LTM_MCP_REFRESH_SECONDS` | Bound | Warning line |
| --- | --- | --- |
| unset | 20 s | none |
| `45` | 45 s | none |
| `0` | 20 s | names the variable and `0` |
| `abc` | 20 s | names the variable and `abc` |

## MODIFIED Requirements

### Requirement: ltm query can bound the pre-query merge and reports the shortfall

`ltm query` SHALL accept `--max-refresh-seconds <N>` where N is an integer ≥ 1. When given, the incremental merge that runs before retrieval SHALL process only append (new) sources and SHALL skip rewritten sources (an `invalidatedSources` entry that also has new chunks) entirely — a rewrite is a delete + full re-insert that cannot be safely stopped between batches, so a bounded merge leaves it unmerged with its cursor untouched rather than start it. The deadline is the start of the merge plus N and **covers the scan phase**: the scan is not interruptible, so if the scan alone exceeds N the first batch boundary is already past the deadline and zero append batches merge; otherwise append sources merge until the deadline, stopping at the first batch boundary reached after it, leaving every already-committed batch in place and committing nothing partial. Retrieval then runs on the index as it stands. N is **not** an upper bound on the merge: the deadline is checked only at the start of each batch, so the work before the first check (taking the lock, the structural gate, the scan, the transaction that removes deleted sources), the batch in progress at the deadline, and the work after the last batch (the transaction that writes the source cursors, the chunk count in the report) run to completion whatever N is, and retrieval runs afterwards. No output or document SHALL state that the command finished within N. The refresh report SHALL carry the number of source files not yet merged and a flag that the budget was exhausted. In both human-readable and `--json` modes the shortfall SHALL be printed on **stderr** as `索引落後 <count> 個來源（有界併入未涵蓋，跑一次 ltm build 補齊）` **whenever `unmergedSources > 0`** (which includes rewritten sources skipped even when the deadline was not reached — the count, not the budget-exhausted flag, is the trigger), leaving `--json` stdout a bare JSON array of hits as the existing output requirement demands. Without the flag the merge SHALL run to completion as before, the report SHALL show zero unmerged sources and `budgetExhausted` false, and no shortfall line SHALL be printed.

#### Scenario: Large backlog is truncated at a batch boundary

- **WHEN** the corpus has grown by more sources than can be merged in N seconds and `ltm query <text> --max-refresh-seconds N` runs
- **THEN** the index contains only whole committed batches, no batch was started after the deadline, and the report names the unmerged source count greater than zero

#### Scenario: Small backlog merges fully within the budget

- **WHEN** the backlog merges in less than N seconds
- **THEN** the report shows zero unmerged sources and `budgetExhausted` false, stderr carries no shortfall line, and stdout is identical to a run without the flag

#### Scenario: The next merge completes the truncated one

- **WHEN** a bounded query left sources unmerged and a later `ltm build` runs
- **THEN** the resulting index is byte-equivalent to one produced by a single uninterrupted build over the same corpus (invariant 2)
