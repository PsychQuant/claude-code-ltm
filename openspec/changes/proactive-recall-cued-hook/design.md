## Context

Recall in the `ltm` plugin is skill-triggered only: `plugin/skills/ltm-recall/SKILL.md` lists cue phrases and the MCP tool `ltm_query` exists, but nothing fires without the model deciding to. Measured 2026-09-03 (#64): outside this repository's own project, zero `ltm_query` tool calls in 2,313 session files. The decision recorded on #64 (spectra-discuss, 2026-09-03) chose **C: a cue-gated `UserPromptSubmit` hook**, plus **A′: a one-line `SessionStart` reminder**, with a mode switch that lets the always-on variant (B) be measured later without a rewrite.

Constraints established from the official hooks documentation (`code.claude.com/docs/en/hooks.md`, fetched 2026-09-03):

- `UserPromptSubmit` command hooks default to a **30-second timeout**; a hook that reaches it has its output **discarded silently** and renders no decision.
- Plain stdout (or JSON `additionalContext`) from `UserPromptSubmit` and `SessionStart` is added to Claude's context and **saved in the session transcript — as records whose top-level `type` is `attachment`** (`attachment.type` = `hook_additional_context`, with `hookEvent`), not as `user` turns. Verified on this machine's corpus 2026-09-04 (check: scan `~/.claude/projects/**/*.jsonl` for lines containing `hook_additional_context`, tally top-level `type`: 23 `UserPromptSubmit`, 181 `SessionStart`, 706 `PostToolUse`, none under `user`/`assistant`). `CorpusScanner.chunk(from:)` already skips every record that is not `user` or `assistant`, so injected text never reaches the index. The first draft of this design assumed the opposite and added a marker-based chunker exclusion; verify R1 (DA) proved it bought nothing and would delete real conversation that quotes the marker, and it was removed.
- `async: true` hooks do not inject on the same turn; `asyncRewake` only wakes on exit 2.
- Hook input carries `session_id`, `cwd`, `transcript_path`, `prompt`; `SessionStart` input carries `source` (`startup` / `resume` / `clear` / `compact`).
- Output strings are capped at 10,000 characters.
- Plugin hooks are declared in the plugin's own hooks manifest and reference scripts via `${CLAUDE_PLUGIN_ROOT}`.

Repository constraints: `LTMService.query(text:limit:scope:strategy:recordEvents:now:)` runs `refreshIncrementally()` unconditionally before retrieval; `ltm query` has no flag to bound or skip that merge; Steady-state `ltm query` latency measured 2026-09-03: n=10, p50 1.12 s, p90 1.21 s, max 19.83 s (the max is a merge tail; after a heavy session the first merge took 2 min 32 s).

## Goals / Non-Goals

**Goals:**

- Recall fires without the model having to think of it, on turns whose prompt matches a cue, within the 30-second hook budget, and degrades **visibly** (a one-line notice) rather than silently when the budget cannot be met.
- Injected recall blocks are never re-indexed (no feedback loop) — **verified, not built**: they are `attachment` records the scanner already skips (`attachmentRecordsAreNeverTurns` pins it).
- The current session's own turns are excluded from injected hits (the hook is the only caller that knows the session id).
- Query scope stays the `cwd` project; no cross-project recall.
- Mode switch `LTM_RECALL_MODE = cued | always | off` so B can be A/B-measured later.
- Measurements before/after: per-turn hook latency (gate-miss turns included), gate hit rate, injected bytes, refresh-budget hit frequency.

**Non-Goals:**

- Any claim that answers improve. There is no evaluation set (#33); the record states only latency, context cost, and call rates.
- Making the chunker ignore every `<system-reminder>` block in user turns. That changes the meaning of the existing index and requires `ltm build --full`; it is a separate design question filed from #64.
- Bounding the merge for the MCP tool by default (#65 owns multi-process merge contention). The service-level bound exists after this change; the MCP tool's default behaviour is unchanged.
- Fixing the general self-hit problem for turns from *other* sessions that contain the query string (#62 keeps that; this change only removes the caller's own session).
- Cross-project recall, ranking changes, or strategy changes.
- A structured (JSONL) cue file. Rejected for v1: appending is equally one line either way, but the hook reads the file on every gated turn under a 30-second budget, and a plain `grep -E -f` needs no parser and no regex escaping. Revisit only when a cue needs a second field (source, language, hit count).

## Decisions

1. **Gate lives in the hook; everything heavy lives in `ltm query`.** The hook script (`plugin/hooks/ltm-recall-gate.sh`) does four things: read the hook JSON from stdin, apply the mode switch and cue gate, call `ltm query` with a wall-clock guard, and print either the recall block or a one-line degradation notice. Bounded merge, session exclusion, and the injection format are `ltm query` features so the CLI, tests, and any future caller share one implementation. Alternative rejected: implementing the bound and exclusion in the hook (post-filtering JSON in shell) — it would duplicate retrieval semantics in bash and leave the MCP path without them.

2. **Cue list is a plain-text data file, one POSIX ERE per line, `#` comments, UTF-8** (`plugin/hooks/recall-cues.txt`), overridable with `LTM_RECALL_CUES=<path>`. The file header states in prose that the list is an enumeration, that it will miss, and that the cost of a miss is today's behaviour. The gate is `grep -E -q -f <cues>` against the prompt text only (system-reminder blocks in the prompt are stripped before matching so other hooks' injections cannot trigger recall). Prompts Claude Code generates itself — beginning with `<` (slash-command expansion), `Base directory for this skill` (skill bodies), `This session is being continued` (compaction summaries), `(Re-invocation of` (skill re-load), or `Stop hook feedback:` — are treated as misses even in `always` mode: their boilerplate carries `earlier` / `previously` / `先前`, and on this machine's records they are the majority of what reaches the prompt path (`docs/measurements/2026-09-04-proactive-recall.md` §3: among the last 200 `promptSource == "typed"` records per project the cue list hits 0–2%; the earlier 9–30% figures in the first draft of that record were a wrong population that mixed in `sdk` and `system` prompts). This exclusion is a closed list of five prefixes and will miss new shapes; the cost of a miss is one unwanted recall, not a lost one. The hook cannot see `promptSource`, so text shape is the only handle it has; `LTM_RECALL_STATS_FILE` (decision 10) is how the live admit rate is measured. Initial list: `之前|上次|當初|以前|先前|過去|還記得|記得|上回|那次|earlier|last time|previously|before we|remember|recall|what did we decide|why did we`. Alternative rejected: keyword matching in Swift inside `ltm` — it would tie cue maintenance to a binary release.

3. **Bounded merge: `--max-refresh-seconds N`.** `refreshIncrementally()` gains a wall-clock budget checked at batch boundaries (the same boundaries `--batch-chunks` already commits at, #47). When the budget is reached the merge stops after the last committed batch, retrieval runs on the index as it now stands, and the `RefreshReport` carries `unmergedSources` (count) and `budgetExhausted: true`. `ltm query` prints the shortfall on **stderr** in both human and `--json` modes (the `--json` stdout shape is a published contract — a JSON array of hits, `ltm-cli` spec — and the existing refresh diagnostics already go to stderr after it); `--format recall` puts it inside the block as its own line. Without the flag behaviour is unchanged (merge to completion). **Granularity caveat (measured 2026-09-04)**: the budget is only checked at batch boundaries, and the default batch of 2,000 chunks takes ≈25 s to embed on this machine (≈78 chunks/s), so a 15-second budget never reaches its first boundary and the hook times out on every turn with a backlog. The hook therefore exports `LTM_BUILD_BATCH_CHUNKS=200` (≈2.6 s per batch) for its own query unless the user set it; each gated turn then merges up to about five batches and a large backlog drains across turns. Alternative rejected: `--no-refresh` (skip entirely) — it makes every gated turn answer on an index that is stale by the whole session; bounded merge keeps the common case (small backlog) fully fresh and only truncates the rare large backlog. Invariant 2 holds because the stopped merge is exactly the committed-batch state a crash would leave, which the next merge completes. Three details fixed after verify R1: the deadline is computed **before** the scan phase (a scan that alone exceeds the budget now stops at the first batch boundary instead of running the whole merge); sources whose earlier content was rewritten (`invalidatedSources`, whose delete + re-insert must complete within one build, #47) are ordered **last** and the budget check is suppressed while their deferred inserts are pending, so a truncated merge never leaves such a source deleted-but-not-reinserted; and exhaustion is also reported when the deadline passes during the final batch, so `budgetExhausted` is never false with time overrun.

4. **Session exclusion: `--exclude-session <id>`.** A hit is dropped when its `sessions` set is a subset of the excluded set (one id in v1); a turn that also lives in another session file (resume copy) is kept, because that other holding is a real prior occurrence. This is the cheapest correct handling of #62's same-session case and does not touch ranking. The `k` cut is applied **after** exclusion: with an exclusion the service fetches 4·k candidates and, while fewer than k survive and the fetch was full, refetches with four times the limit up to 1,000 (`exclusionRefetchesUntilKIsFilled`). The first live measurement returned an empty block because the top three candidates were all the current session's own turns and were dropped after the cut; a fixed 4·k fetch (the first fix) still returned fewer than k in a long single-session project.

5. **Injection format: `--format recall`.** Output is: line 1 `<!-- ltm:recall v1 -->`; line 2 the existing data-not-instructions banner used by the MCP tool; then at most k hits (hook passes `--k 3`) each as `N. [project] timestamp` / snippet (≤ 200 characters) / `↳ sessions … turn <uuid>`; optional line `索引落後 N 個來源（併入預算 S s 已用完）` when the refresh budget was exhausted; last line `<!-- /ltm:recall -->`. Total is capped at 4,000 characters by truncating snippets first, then dropping hits from the tail. Alternative rejected: hook formats `--json` itself — the marker literal must live in exactly one place (`RecallMarker`, pinned by `RecallMarkerSyncTests`), and shell formatting of UTF-8 snippets is where truncation bugs live.

6. **No chunker exclusion — the feedback loop is closed by the transcript format, not by us.** Injected hook text is stored as `attachment` records, which `CorpusScanner` never turns into chunks (see Context; pinned by `attachmentRecordsAreNeverTurns`). The first draft removed `<!-- ltm:recall` … `<!-- /ltm:recall -->` spans from `text` blocks; verify R1 showed the mechanism could only ever act on real `user`/`assistant` text — a turn that quotes the marker while discussing this feature, or pastes a block — and an unterminated marker would delete to the end of the block. Zero benefit, positive cost, removed. `RecallMarker` in `LTMIndex` keeps the marker constants for the writer only; `RecallMarkerSyncTests` still pins the literal to one place. `unmarkedInputIsIndexedExactlyAsBefore` keeps its pre-change digest and now guards both directions.

7. **One deadline for the whole hook; degradation is one visible line.** The script computes an absolute deadline at start (`LTM_RECALL_GUARD_SECONDS`, default 20; the manifest timeout is 28, below Claude Code's 30-second default so the script always speaks first) and runs every child — the JSON extraction, the `ltm query --help` capability probe, and the query — under it, killing the child and its children (TERM then KILL) on expiry. The first version guarded only the query, so a hung probe or parser silently hit the outer timeout. `--max-refresh-seconds` is guard − 5. Input hardening from the same review: `LTM_BIN` must be absolute (the `-x` check and the execution straddle the `cd`), a missing or unenterable `cwd`, a missing `python3`, and an unparsable input are each a notice, the prompt is passed after `--`, and a `session_id` outside `[A-Za-z0-9._-]{1,128}` is dropped rather than passed. The notice line names the condition but never echoes CLI stderr. The too-old-binary notice is emitted once per session (marker file keyed by `session_id`), otherwise every gated turn until v0.5.0 ships would carry it. The hook never exits 2 (which would block the prompt) and never prints nothing on a gated turn — silence is reserved for gate misses, `off` mode, Claude-Code-generated shapes, and the repeated old-binary case.

8. **`SessionStart` reminder (A′).** `plugin/hooks/ltm-session-start.sh` prints one line naming `ltm_query` and the cue-gated recall, for every `source` value. It adds no retrieval and no latency beyond process start.

9. **Mode switch.** `LTM_RECALL_MODE` unset or `cued` → gate applies; `always` → gate skipped, every admitted prompt queries; `off` → hook exits 0 with no output. Unknown values behave as `cued` and the notice line says so once per session (written to stderr, not injected).

10. **In-hook statistics are closed-set labels only.** With `LTM_RECALL_STATS_FILE` set the hook appends `<unix seconds> <label>` per invocation, label ∈ {`off`, `synthetic`, `miss`, `hit`, `notice`} — the same storage rule as the memory layer (labels from a closed set, never text). This is the only way to measure the live admit rate, because the hook cannot see `promptSource` and the transcript does not record hook decisions.

## Implementation Contract

**Behavior (observable):**

- On a prompt that matches a cue, Claude's context for that turn contains a `<!-- ltm:recall v1 -->` block with ≤ 3 pointered hits from the `cwd` project, none of them from the current `session_id`, delivered within 30 s; when the merge budget was exhausted the block states how many sources remain unmerged.
- On a prompt with no cue match (mode `cued`) the hook exits 0 with empty stdout in under 100 ms and nothing is injected.
- On timeout, missing binary, or missing index, exactly one notice line is injected; the prompt is never blocked.
- Session start (any `source`) injects one reminder line.
- After a turn that received a recall block, `ltm build` indexes that user turn **without** the block's text: `ltm query` for a distinctive token that appears only inside the injected block returns no hit for that turn.
- `ltm query --exclude-session S` never returns a hit whose `sessions` set is `{S}`; a hit with `sessions` `{S, T}` is still returned.
- `ltm query --max-refresh-seconds N` returns within N seconds plus retrieval time when the backlog is large, and its report names the unmerged source count; with a small backlog the report shows zero unmerged.

**Interface / data shape:**

- `ltm query` flags: `--max-refresh-seconds <Int ≥ 1>`, `--exclude-session <String>`, `--format recall` (alongside existing `--json`; the two are mutually exclusive and the CLI exits non-zero naming both when given together).
- `LTMService.query` gains parameters `refreshBudget: TimeInterval?` and `excludeSessions: Set<String>`; `RefreshReport` gains `unmergedSources: Int` and `budgetExhausted: Bool`; the CLI reports them on stderr (`--json` stdout stays a bare array of hits).
- Marker constants: `RecallMarker.open = "<!-- ltm:recall v1 -->"`, `RecallMarker.close = "<!-- /ltm:recall -->"`, exclusion matches the prefix `<!-- ltm:recall` so future versions stay excluded.
- Cue file: UTF-8 text, one ERE per line, lines starting with `#` ignored, blank lines ignored; path from `LTM_RECALL_CUES` else `${CLAUDE_PLUGIN_ROOT}/hooks/recall-cues.txt`.
- Plugin hooks manifest `plugin/hooks/hooks.json`: `UserPromptSubmit` → `${CLAUDE_PLUGIN_ROOT}/hooks/ltm-recall-gate.sh` with `timeout: 28`; `SessionStart` → `${CLAUDE_PLUGIN_ROOT}/hooks/ltm-session-start.sh` with `timeout: 5`.
- Environment: `LTM_RECALL_MODE` (`cued` | `always` | `off`), `LTM_RECALL_CUES` (path).

**Failure modes:**

- Merge budget exhausted → answer on committed state, report shortfall (never silent).
- Hook guard fires → one notice line, exit 0.
- Cue file unreadable → gate treats as no cues (nothing injected) and writes one stderr line naming the path.
- `--json` together with `--format recall` → exit non-zero, message names both flags.
- Index missing → `ltm query` exits non-zero as today; the hook converts that to the notice line.

**Scope boundaries:**

- In scope: the two hooks, the cue file, the three `ltm query` flags, `LTMService`/`RefreshReport` changes, the `attachment`-is-not-a-turn pin, tests for each, plugin README and `ltm-recall` skill text, measurement record, CHANGELOG.
- Out of scope: MCP tool parameters for the bound or exclusion, `<system-reminder>`-wide exclusion, ranking or strategy changes, cross-project recall, cue-hit statistics in the memory layer.

## Risks / Trade-offs

- **Cue misses** are the accepted cost of C; the mode switch exists so `always` can be measured rather than argued.
- **Bounded merge staleness**: a gated turn right after a heavy session answers on an index missing the newest sources; the block says so. The alternative (blocking up to 2.5 min or injecting nothing) is worse on both axes.
- **Per-turn cost in `always` mode** is measured before it can become the default.
- **Marker forgery**: any text containing the marker pair is excluded from indexing. Accepted: the only effect is a chunk missing that span, which is forgetting, not fabrication (ltm-analogy property 5).

## Migration Plan

No index migration. Existing indexes contain no marker text, so the new exclusion changes nothing for previously indexed turns; the invariant-2 equivalence test runs on a fixture with and without marked blocks. Plugin users receive the hooks on the next `claude plugin update ltm@claude-code-ltm`; the binary features ship in the next release, and the hook checks the installed binary supports `--format recall` (exit status of a probe) before relying on it, otherwise it prints the notice line naming the required version.

## Open Questions

- Whether the initial cue list should carry Japanese cues; deferred until a Japanese-language session shows a miss.
- Whether the `SessionStart` reminder should be suppressed when `LTM_RECALL_MODE=off`; v1 prints it regardless because the reminder is about the tool, not the hook.
