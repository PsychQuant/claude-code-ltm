## 1. Tests first

- [x] 1.1 Extend `Tests/LTMMCPTests/RetrievalToolRenderTests.swift` for "The MCP ltm_query call bounds its pre-query merge by default and reports the shortfall": the lag line appears when `unmergedSources > 0` with hits and with zero hits, is absent when it is 0, and a startup rejection of `LTM_MCP_REFRESH_SECONDS` appears as a warning line. Verify: the new tests fail before 2.2 (no lag line in the MCP render; no rejection parameter).
- [x] 1.2 Add a tool-level test that builds the `ltm_query` tool over a fixture corpus with a backlog, a stepping test clock and a 1-second bound, calls it, and finds the lag line with a count above zero; the same backlog with a bound of 3600 seconds yields no lag line and the same hits. Verify: fails before 2.2 because the tool passes no budget.
- [x] 1.3 Add a resolution test for the example table in the spec delta (unset → 20, `45` → 45, `0` and `abc` → 20 plus a rejection naming the variable and value). Verify: fails before 2.3.

## 2. Implementation

- [x] 2.1 Implement design decision "One shared lag line": one function in `LTMService` produces `索引落後 <count> 個來源（有界併入未涵蓋，跑一次 ltm build 補齊）`, and `RecallBlock` and the CLI's stderr path in `Sources/ltm/Commands.swift` call it. Verify: the existing CLI and recall-format wording tests pass unchanged.
- [x] 2.2 Implement design decision "The bound lives in the tool, not in `LTMService.query`": `RetrievalTool.make(service:refreshBudget:rejections:)` passes the budget to `service.query(..., refreshBudget:)` and renders the lag line and the rejections. Verify: tests 1.1 and 1.2 pass.
- [x] 2.3 Implement design decision "Override through `LTM_MCP_REFRESH_SECONDS`, parsed once at server start": `MCPCommand` resolves the bound with `BuildTuning.parsePositive` and a named default constant of 20 seconds whose comment says it is a starting value, not a measurement, and points at `docs/latency-budget.md`. Verify: test 1.3 passes and `MCPStdoutTests` still pass.
- [x] 2.4 Mutation check with the CLAUDE.md backup-and-restore recipe: drop the `refreshBudget:` argument from the tool's query call and confirm test 1.2 fails by name; restore and confirm `git hash-object` matches. Verify: recorded test name and hash.

## 3. Documents

- [x] 3.1 Implement design decision "Update the analogy file in the same change": in `.claude/rules/ltm-analogy.md`, the comparison table and the paragraph on reopening a SessionEnd merge say that bounded merges on the hook and MCP paths make query-time merging no longer seamless, that the lag line reaches only the model (#81), and that a SessionEnd merge would buy coverage as well as latency, with the measurement precondition unchanged. Verify: content review against the hook and MCP code paths.
- [x] 3.2 Update `docs/latency-budget.md`'s MCP row ("current setting" and "gap" cells) to the new default and override, keeping the statement that the bound is not an end-to-end limit; mention `LTM_MCP_REFRESH_SECONDS` in `plugin/README.md`; add a CHANGELOG entry under Unreleased with no effect numbers. Verify: content review against the honesty rule in CLAUDE.md.

- [x] 3.3 Implement design decision "Correct the CLI requirement's 'bounded by roughly N'": the spec delta's MODIFIED requirement replaces the sentence and the first scenario's outcome; no code or test change. Verify: `grep` finds no test asserting the old timing, and `spectra validate bound-mcp-pre-query-merge` passes.

- [x] 3.4 Add `LTM_MCP_REFRESH_SECONDS` to the environment whitelist of `scripts/measure-baseline.sh` (the variable line and the header prose), because `BaselineQueryFileTests` requires every environment variable that `Sources/` reads with a literal key to be forwarded by the measurement script; the resolver reads the variable with a literal key for the same reason. Verify: `BaselineQueryFileTests` passes (only its known issue), `bash -n scripts/measure-baseline.sh` passes.

## 4. Whole suite

- [x] 4.1 Run the full `swift test`. Verify: everything passes except the known issue in `BaselineQueryFileTests` that predates this change; record the counts and delete the `ltm-*` directories the run leaves in `TMPDIR`.

## 5. Verify R1 additions

- [x] 5.1 Implement the user decision "batches of 200, as the hook uses" (`issuecomment-6111570876`): `RetrievalTool.batchChunksDefault(environment:)` returns `200` when `LTM_BUILD_BATCH_CHUNKS` is unset or empty and `nil` otherwise; `MCPCommand` sets it into its environment at start. Verify: `theMCPBatchDefaultFollowsTheHook`.
- [x] 5.2 Pin `MCPCommand`'s wiring with subprocess tests of `ltm mcp` (`theMCPServerWiresTheBoundAndTheBatchDefault`, `theMCPServerReportsAnInvalidOverride`); `MCPCommand` passes the test clock seam (`CommandSupport.serviceClock`) to the service; `rejections` loses its default value. Verify: passing `nil` as the budget, dropping the batch default, and dropping the rejections each turn a named test red (mutations recorded against `3ef60bb77b08067420c4ed54a6d264aaf7896ebc`).
- [x] 5.3 Error responses carry the startup rejection too (`RetrievalTool.AnnotatedError`). Verify: `aStartupRejectionAlsoRidesOnErrors`.
- [x] 5.4 Pin the lag-line trigger on `unmergedSources`, not `budgetExhausted` (`theLagLineFollowsUnmergedSourcesNotTheExhaustedFlag`). Verify: changing the trigger to `budgetExhausted` turns it red (recorded against `2530d17619657486e040b26b60c19eb27de582fd`).
- [x] 5.5 The sanitizer for rejected values flattens every Unicode line break and caps length by Unicode scalars. Verify: `rejectionUnicodeLineBreaksAreFlattened`.
- [x] 5.6 Documents: rewritten sources wait for `ltm build` whatever the bound (README, skills, design, analogy file, latency budget, CHANGELOG, spec); the #81 claim narrowed to the hook; the §2 citation keeps that 21.5 s was a kill time; the stage lists are marked as examples and the per-call service construction is named; the CLI `--help` line; the backlog-shrinks claim qualified; no value of the override restores the old behavior. #86 tracks small rewrites inside the bound. Verify: content review; `PluginShellTests` and `BaselineQueryFileTests` pass.

