## ADDED Requirements

### Requirement: Hook-injected context never becomes a turn

Claude Code stores the text a hook injects (`UserPromptSubmit` / `SessionStart` stdout or `additionalContext`) in the session transcript as records whose top-level `type` is `attachment` (`attachment.type` = `hook_additional_context`, `attachment.hookEvent` naming the hook), not as `user` or `assistant` records. The indexer SHALL derive chunks only from records whose top-level `type` is `user` or `assistant`; every other record SHALL be counted under the `notATurn` skip tally and SHALL contribute no chunk, no trigram, no token, and no vector, regardless of its content. The indexer SHALL NOT inspect turn text for recall markers: verification on this machine's corpus (2026-09-04; check: scan `~/.claude/projects/**/*.jsonl` for lines containing `hook_additional_context` and tally the top-level `type` — 23 `UserPromptSubmit`, 181 `SessionStart`, 706 `PostToolUse`, zero under `user` or `assistant`) showed that a marker-based exclusion would remove nothing that reaches the index while deleting real conversation that quotes or discusses the marker.

#### Scenario: An injected recall block is an attachment and yields no chunk

- **WHEN** a session file contains a `user` turn, an `attachment` record with `hookEvent` `UserPromptSubmit` whose content is a full `<!-- ltm:recall v1 -->` … `<!-- /ltm:recall -->` block containing the token `ZQXJTOKENA`, an `attachment` record with `hookEvent` `UserPromptSubmit` whose content is unmarked text, and an `attachment` record with `hookEvent` `SessionStart`
- **THEN** the scan produces exactly one chunk, whose text is the user turn, no chunk text contains `ZQXJTOKEN`, and `skipped.notATurn` equals 3

#### Scenario: Turn text that mentions the marker is indexed verbatim

- **WHEN** a `user` turn's text quotes the literal string `<!-- ltm:recall v1 -->` while discussing this feature
- **THEN** the chunk text equals the turn text unchanged (the pinned digest in `unmarkedInputIsIndexedExactlyAsBefore` holds for every input; there is no marker-dependent path)
