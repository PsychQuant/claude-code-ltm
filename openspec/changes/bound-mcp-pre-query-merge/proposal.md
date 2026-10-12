## Why

An MCP `ltm_query` call merges the whole corpus backlog before it answers: `RetrievalTool` calls `LTMService.query(text:limit:scope:)` without a `refreshBudget`, so the pre-query merge runs unbounded (#71 diagnosis, `issuecomment-6106131741`). The CLI has `--max-refresh-seconds` and the recall hook passes it; the MCP path has neither a bound nor a spec requirement. #71 records 19 calls from the local MCP logs: 11 succeeded, 7 of those after 8 to 27 minutes, and 2 were aborted by the client's 1800-second idle timeout. #76 set the MCP end-to-end budget at 30 seconds (`docs/latency-budget.md`).

## What Changes

- The MCP `ltm_query` tool bounds its pre-query merge by default, with the same semantics as `ltm query --max-refresh-seconds`: append sources only, rewritten sources skipped, stop at the first batch boundary after the deadline, nothing partial committed.
- The default bound is 20 seconds. It is a starting value derived from #76's 30-second end-to-end budget minus an unmeasured share for retrieval, not a measured value.
- `LTM_MCP_REFRESH_SECONDS` (a positive integer) overrides the default. An invalid value is ignored, the default applies, and the response carries a warning naming the variable, the same way `LTM_BUILD_*` rejections surface today.
- When sources were left unmerged, the MCP response carries the same lag line the CLI and the recall format already print. The wording moves into one shared constant used by all three entry points.
- `.claude/rules/ltm-analogy.md` is updated: with bounded merges on the hook and MCP paths, query-time merging is no longer "seamless", and the premise for reconsidering a SessionEnd merge changes from latency alone to latency and coverage.
- `docs/latency-budget.md`'s MCP row is updated to describe the new current setting.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `ltm-cli`: a new requirement for the MCP `ltm_query` call's default bounded merge and its shortfall report.

## Impact

- Affected specs: ltm-cli
- Affected code:
  - Modified: Sources/LTMMCP/RetrievalTool.swift, Sources/ltm/MCPCommand.swift, Sources/LTMService/RecallBlock.swift, Sources/ltm/Commands.swift, Tests/LTMMCPTests/RetrievalToolRenderTests.swift, Tests/LTMServiceTests/CLICommandTests.swift, Sources/LTMService/LTMService.swift, plugin/skills/ltm-setup/SKILL.md, plugin/skills/ltm-recall/SKILL.md, scripts/measure-baseline.sh, .claude/rules/ltm-analogy.md, docs/latency-budget.md, plugin/README.md, CHANGELOG.md
  - New: Sources/LTMService/ShortfallMessage.swift, Tests/LTMMCPTests/RetrievalToolBoundTests.swift
