## ADDED Requirements

### Requirement: Hook-injected context never becomes a turn

Claude Code stores the text a hook injects (`UserPromptSubmit` / `SessionStart` stdout or `additionalContext`) in the session transcript as records whose top-level `type` is `attachment` (`attachment.type` = `hook_additional_context`, `attachment.hookEvent` naming the hook), not as `user` or `assistant` records. The indexer SHALL derive chunks only from records whose top-level `type` is `user` or `assistant`; every other record SHALL be counted under the `notATurn` skip tally and SHALL contribute no chunk, no trigram, no token, and no vector, regardless of its content. The indexer SHALL NOT inspect turn text for recall markers. Verification on this machine's corpus (2026-09-04; check: scan `~/.claude/projects/**/*.jsonl` for lines containing `hook_additional_context`, decode each and tally the **top-level `type`** — the hook-injected records are all `type: "attachment"`, which `chunk(from:)` skips). Note the discriminating predicate: a naive `"hook_additional_context" in line` count also picks up a handful of real `user`/`assistant` turns (6 + 5 on this machine at a later scan) that merely **quote** the string while discussing this feature — which is precisely why a marker-based exclusion would corrupt real conversation. The counts drift with the live corpus, so the durable claim is qualitative: injected recall lands in `attachment` records, never in turns.

#### Scenario: An injected recall block is an attachment and yields no chunk

- **WHEN** a session file contains a `user` turn, an `attachment` record with `hookEvent` `UserPromptSubmit` whose content is a full `<!-- ltm:recall v1 -->` … `<!-- /ltm:recall -->` block containing the token `ZQXJTOKENA`, an `attachment` record with `hookEvent` `UserPromptSubmit` whose content is unmarked text, and an `attachment` record with `hookEvent` `SessionStart`
- **THEN** the scan produces exactly one chunk, whose text is the user turn, no chunk text contains `ZQXJTOKEN`, and `skipped.notATurn` equals 3

#### Scenario: Turn text that mentions the marker is indexed verbatim

- **WHEN** a `user` turn's text quotes the literal string `<!-- ltm:recall v1 -->` while discussing this feature
- **THEN** the chunk text equals the turn text unchanged. This holds because `indexableText` is the identity on strings and only concatenates a turn's `text` blocks — there is no marker-dependent branch; `unmarkedInputIsIndexedExactlyAsBefore` pins the digest of four representative inputs against regression
