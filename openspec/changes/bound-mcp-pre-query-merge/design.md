## Context

`ltm mcp` runs a synchronous JSON-RPC loop; each `tools/call` for `ltm_query` builds an `LTMService`, and `LTMService.query` runs `refreshIncrementally(budget:)` before retrieval. `RetrievalTool.make` passes no budget, so the merge is unbounded. `IndexBuilder.build(budget:)` already implements bounded merging for the CLI flag: the deadline starts before the lock and scan, is checked only at batch boundaries, skips rewritten sources, and reports `unmergedSources` and `budgetExhausted` in the refresh report. The recall format and the CLI already print the lag line; `RetrievalTool.render` does not.

The #71 handoff note from #76 (`issuecomment-6106998187`) adds two constraints: the merge bound has to leave room for retrieval inside the 30-second end-to-end budget, and the bound is not an end-to-end upper bound, because the check happens only at batch boundaries and the MCP path has no outer kill (`docs/measurements/2026-09-04-proactive-recall.md` §2 recorded that with the first hook's 15-second merge budget all twenty rounds hit the hook's 20-second `GUARD`, at about 21.5 seconds each).

## Goals / Non-Goals

**Goals:**

- Every MCP `ltm_query` call runs a bounded pre-query merge; the operator can change the bound but not remove it.
- A call that leaves sources unmerged says so in its response, in the same words as the CLI and the recall format.
- The analogy file stops describing query-time merging as seamless.

**Non-Goals:**

- Cancellation and progress notifications (#78). A bound does not cap the work an abandoned call leaves running: the deadline is checked only at the start of each batch, so the work before the first check (for example the lock, the structural gate, the scan, a delete-only transaction — the query path never runs an owed full audit, because it passes `honorPendingAudit: false`), the batch in progress at the deadline, and the work after the last batch (the cursor transaction, the chunk count) run to completion whatever the bound is (#76 handoff note `issuecomment-6106998187`, point 2). It is not cancellable. The stages named here are examples, not a complete list; the MODIFIED requirement gives more.
- Making the bound precise: the scan before the first batch boundary and a long batch can overrun it (#69).
- A per-call argument on the tool. The agent cannot judge the trade-off better than the operator's setting, and a new tool argument is a contract to maintain.
- Any claim that MCP calls now finish within 30 seconds or any other latency claim. Measurement belongs to #79 and #75 under the comparison rule in `docs/latency-budget.md`.

## Decisions

### Default bound of 20 seconds, labelled as a starting value

The end-to-end budget is 30 seconds. Retrieval time on today's index has not been measured, so the split is a guess: 20 seconds for the merge leaves about 10 for retrieval and rendering. Alternatives were 15 seconds and 25 seconds (leaves about 5 for retrieval). The value is a named constant with a comment saying it is not measured and pointing at `docs/latency-budget.md`.

### Batches of 200 chunks, as the hook uses

The bound is checked only at the start of each batch. `docs/measurements/2026-09-04-proactive-recall.md` §2 derived about 25 seconds for one batch of the default 2,000 chunks from a build's throughput (about 78 chunks per second; not a timed batch) — longer than the bound — which is why the hook sets 200. With 2,000, any call that starts a batch runs it whole, so 15, 20 and 25 seconds would merge the same amount and take about as long (verify R1, inferred from that record, not measured again). `MCPCommand` therefore sets `LTM_BUILD_BATCH_CHUNKS=200` in its own environment at start when the variable is unset or empty, the same rule as the hook's `${LTM_BUILD_BATCH_CHUNKS:-200}`; a value the user set is passed on as is (user decision `issuecomment-6111570876`); a value that is not a positive integer is rejected by `BuildTuning`, which falls back to 2,000 and reports the rejection — the same as on the hook path.

### Override through `LTM_MCP_REFRESH_SECONDS`, parsed once at server start

`MCPCommand` reads the variable once, with `BuildTuning.parsePositive`, the parser `LTM_BUILD_*` already use. An invalid value yields a `BuildTuning.Rejection`; the default applies, and every response from that server process carries the rejection as a warning line, the same rendering `tuningRejections` already get. Rejecting the call instead would turn a days-old typo into a failing tool, which is the over-reaction `BuildTuning` already avoids.

### One shared lag line

The sentence `索引落後 <count> 個來源（有界併入未涵蓋，跑一次 ltm build 補齊）` exists twice today, in `RecallBlock` and in the CLI's stderr path. It moves to one function in `LTMService`, used by the CLI, the recall format and the MCP response. The trigger stays `unmergedSources > 0`, as the existing requirement specifies.

### The bound lives in the tool, not in `LTMService.query`

`LTMService.query` keeps `refreshBudget: nil` as its default, because the CLI's contract ("without the flag the merge runs to completion") depends on it. `RetrievalTool.make` takes the resolved budget and passes it on each call.

### Correct the CLI requirement's "bounded by roughly N"

The ltm-cli requirement "ltm query can bound the pre-query merge and reports the shortfall" says the merge is "bounded by roughly N (scan included)", and its first scenario says the command returns after roughly N seconds plus retrieval. Both are false for the reason in Non-Goals: the deadline is checked only at batch starts, and several stages before the first check and after the last batch cannot be interrupted. The new MCP requirement points at that requirement for its semantics, so this change modifies it: the sentence becomes a statement that N is not an upper bound, naming the uninterruptible stages, and the scenario's outcome becomes what is guaranteed — only whole committed batches, no batch started after the deadline, an unmerged count above zero. The CLI's behavior does not change, and no test asserts the old timing.

### Update the analogy file in the same change

`.claude/rules/ltm-analogy.md` argues against a SessionEnd merge because query-time merging is seamless and fails loudly. With bounded merges on both the hook path (#64) and MCP, an answer can come from a lagging index; the hook's lag line reaches only the model (#81), and whether a user sees it in an MCP response has not been checked. The table and the "premise for reopening" paragraph are updated to say that a SessionEnd merge would now buy coverage as well as latency, and that the measurement precondition still holds.

## Implementation Contract

- **Observable behavior**: an MCP `ltm_query` call with a backlog larger than the bound commits whole batches up to the first batch boundary after the deadline, answers from that index, and its response begins with the lag line naming the unmerged source count; with a small backlog of new content only, the response is identical to today's. Rewritten sources are never merged by a bounded call, whatever the bound is (`IndexBuilder.build` skips them whenever a budget is passed), so a backlog that contains one always yields the lag line until `ltm build` runs — before this change the unbounded MCP call merged them.
- **Interface**: `RetrievalTool.make(service:refreshBudget:rejections:)`, where `refreshBudget` is seconds as `TimeInterval` and `rejections` are the startup parse rejections; a default-bound constant; a shared lag-line function in `LTMService`.
- **Configuration**: `LTM_MCP_REFRESH_SECONDS`, a positive integer; unset means 20; invalid means 20 plus a warning line on every response (successful responses carry it among the warnings, error responses after the error text). `LTM_BUILD_BATCH_CHUNKS` unset or empty means 200 for the MCP server.
- **Failure modes**: unchanged. `lockHeld` still yields the merge-deferred warning; `lockUnavailable` still fails the call.
- **Acceptance**:
  - `RetrievalToolRenderTests`: lag line present with hits and with zero hits when `unmergedSources > 0`, absent when 0; a startup rejection appears as a warning.
  - A tool-level test runs `RetrievalTool` against a fixture backlog with a stepping clock and a 1-second bound and finds the lag line; the same backlog with a large bound produces no lag line and identical hits.
  - The CLI and recall-format wording tests still pass against the shared function.
  - Removing the budget argument from the tool's `service.query` call turns the tool-level test red (mutation, CLAUDE.md recipe).
  - Subprocess tests of `ltm mcp` pin the server's wiring: passing `nil` as the budget, dropping the batch default, or dropping the rejections each turns a named test red (verify R1 found that none of them did).
  - The full suite passes.
- **Scope boundaries**: in scope — the MCP tool, `MCPCommand` startup parsing and its batch default and test clock seam, the shared lag line, the sanitizer of rejected values (`LTMService.describe`), the `ltm query --help` line for `--max-refresh-seconds`, the two plugin skills that describe query-time merging, the wording of the ltm-cli bounded-merge requirement (no behavior change), the measurement script's environment whitelist (one name added, required by the whitelist sync test), the analogy file, `docs/latency-budget.md`'s MCP row, `plugin/README.md`, CHANGELOG. Out of scope — the CLI flag's behavior, the hook, `IndexBuilder`, cancellation, progress.

## Risks / Trade-offs

- [Answers from a lagging index] → the lag line says how many sources are missing. On the hook it reaches only the model (#81); whether a user sees it in an MCP response has not been checked.
- [Rewritten sources wait for `ltm build`] → a bounded merge cannot stop between deleting and re-inserting a rewritten source, so it skips them; until `ltm build` runs, the old text of a rewritten transcript (for example one where a pasted secret was deleted) stays searchable through MCP and the hook, and every response carries the lag line. The user kept the bound and asked for a follow-up that lets small rewrites happen inside the bound (`issuecomment-6111570876`; #86).
- [The backlog never catches up when queries are rare] → a call commits whole batches when the work before the first batch check (the scan of all new bytes among it) finishes inside the bound; when that work alone exceeds the bound, the call commits nothing and the next call re-scans the same backlog. Whether the backlog keeps up is not established, and `ltm build` remains the catch-up path (#71 Residue).
- [20 seconds may be wrong] → it is a labelled starting value; #79 and #75 measurements are the place to revise it.

## Migration Plan

No data migration. No value of `LTM_MCP_REFRESH_SECONDS` restores the old unbounded behavior: any bound makes the merge skip rewritten sources. A large value only makes the deadline unreachable for new content.

## Open Questions

(none)
