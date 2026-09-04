## Why

Recall today depends entirely on Claude noticing a cue in the user's words and reaching for the `ltm-recall` skill. Measured on this machine (2026-09-03, #64 diagnosis): outside the `claude-code-ltm` development project, **zero** `ltm_query` tool calls exist across 2,313 session files — the skill-triggered path does not happen in practice. The plugin needs a mechanism that fires without the model having to think of it, while staying inside the constraints the official hooks documentation imposes (30-second `UserPromptSubmit` budget with silent discard on timeout; injected text is saved to the transcript and therefore re-indexed).

## What Changes

- New plugin hooks: a `UserPromptSubmit` hook that runs `ltm query` **only when the prompt matches a cue list** and injects at most three pointered hits; a `SessionStart` hook that prints a one-line reminder that `ltm_query` exists (also on resume). Mode switch `LTM_RECALL_MODE = cued | always | off`, default `cued`.
- New cue list data file shipped with the plugin (`plugin/hooks/recall-cues.txt`, one pattern per line, UTF-8), overridable via `LTM_RECALL_CUES=<path>`. The list is an enumeration and will miss; the documented cost of a miss is today's behaviour (no recall).
- `ltm query` gains three flags, shared by any caller: `--max-refresh-seconds N` (bounded pre-query merge: stop at the last committed batch when the budget is reached, answer on the existing index, report how many sources remain unmerged), `--exclude-session <id>` (drop hits whose only holding sessions are the excluded one), and `--format recall` (a compact, marker-wrapped block sized for hook injection).
- Injected recall blocks never become chunks — verified rather than built: Claude Code stores hook injections as `attachment` records, which the indexer already skips (the first draft added a marker-based chunker exclusion; verify R1 showed it bought nothing and could delete real conversation, and it was removed).
- Measurement record under `docs/measurements/` covering hook latency per turn (including gate-miss turns), gate hit rate, injected bytes, and how often the refresh budget is hit. No claim about answer quality is made anywhere.

## Capabilities

### New Capabilities

- `proactive-recall-hook`: the plugin's hook contract — cue gate and modes, bounded latency with visible degradation, injection format and size, session-start reminder, cue-file semantics.

### Modified Capabilities

- `ltm-cli`: `ltm query` accepts `--max-refresh-seconds`, `--exclude-session`, `--format recall`; the pre-query merge becomes boundable and its shortfall is reported.
- `corpus-indexing`: records that are not `user`/`assistant` turns (hook `attachment` records included) never yield chunks; the indexer does not inspect turn text for recall markers.

## Impact

- Affected specs: `proactive-recall-hook` (new), `ltm-cli` (modified), `corpus-indexing` (modified)
- Affected code:
  - New: `plugin/hooks/hooks.json`, `plugin/hooks/ltm-recall-gate.sh`, `plugin/hooks/ltm-session-start.sh`, `plugin/hooks/recall-cues.txt`, `Tests/LTMMCPTests/RecallHookShellTests.swift`, `docs/measurements/2026-09-04-proactive-recall.md`
  - Modified: `Sources/ltm/Commands.swift`, `Sources/LTMService/LTMService.swift`, `Sources/LTMIndex/CorpusScanner.swift`, `Sources/LTMIndex/IndexBuilder.swift`, `Tests/LTMServiceTests/LTMServiceTests.swift`, `Tests/LTMIndexTests/CorpusScannerTests.swift`, `Tests/LTMMCPTests/PluginShellTests.swift`, `plugin/README.md`, `plugin/skills/ltm-recall/SKILL.md`, `CHANGELOG.md`
  - Removed: (none)
