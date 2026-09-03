## ADDED Requirements

### Requirement: A cue-gated prompt hook injects pointered recall within the hook budget

The plugin SHALL register a `UserPromptSubmit` hook. When `LTM_RECALL_MODE` is unset or `cued`, the hook SHALL run `ltm query` only when the submitted prompt, after removing any `<system-reminder>…</system-reminder>` spans, matches at least one pattern of the cue file. When the mode is `always` the hook SHALL run `ltm query` for every prompt. When the mode is `off` the hook SHALL exit 0 with empty stdout. An unrecognised mode value SHALL behave as `cued`.

When the hook runs `ltm query` it SHALL pass `--format recall`, `--k 3`, `--exclude-session <session_id from the hook input>`, `--max-refresh-seconds 15`, and SHALL run it from the hook's `cwd` so the query scope is that directory's project. The hook SHALL finish within 28 seconds. The hook SHALL never exit with status 2 and SHALL never emit a `decision` of `block`.

#### Scenario: Cue match injects a recall block

- **WHEN** the mode is `cued` and the prompt is `上次那個 flock 的決定是什麼`
- **THEN** the hook's stdout is a block that begins with `<!-- ltm:recall v1 -->`, ends with `<!-- /ltm:recall -->`, contains at most three hits each carrying a project, a timestamp, a snippet, and a `turn <uuid>` pointer, and contains no hit whose sessions set is exactly the hook's `session_id`

#### Scenario: No cue match costs nothing

- **WHEN** the mode is `cued` and the prompt is `幫我改這個函式`
- **THEN** the hook exits 0 with empty stdout, runs no `ltm` process, and finishes in under 100 ms

#### Scenario: Injections from other hooks cannot trigger recall

- **WHEN** the prompt text itself contains no cue but a `<system-reminder>` span inside the prompt contains the word `earlier`
- **THEN** the hook treats the prompt as a gate miss and injects nothing

#### Scenario: Mode off is silent

- **WHEN** `LTM_RECALL_MODE=off` and the prompt matches a cue
- **THEN** the hook exits 0 with empty stdout

##### Example: Gate outcomes

| `LTM_RECALL_MODE` | Prompt | Runs `ltm query` | stdout |
| ----------------- | ------ | ---------------- | ------ |
| unset | `上次那個 flock 的決定是什麼` | yes | recall block |
| unset | `幫我改這個函式` | no | empty |
| `always` | `幫我改這個函式` | yes | recall block |
| `off` | `上次那個 flock 的決定是什麼` | no | empty |
| `bogus` | `上次那個 flock 的決定是什麼` | yes | recall block |

### Requirement: Degradation is visible and never blocks the prompt

When the gate admits a prompt but recall cannot complete — the `ltm` binary is absent, it does not support `--format recall`, the index is missing, `ltm query` exits non-zero, or the hook's 20-second guard around `ltm query` fires — the hook SHALL print exactly one line to stdout of the form `ltm：本輪回想未完成（<reason>）；可手動呼叫 ltm_query`, where `<reason>` names the specific condition, and SHALL exit 0.

#### Scenario: Guard fires on a large backlog

- **WHEN** the gate admits the prompt and `ltm query` has not returned after 20 seconds
- **THEN** the hook terminates the `ltm` process, prints the single notice line with reason `逾時 20 s`, and exits 0 before the 28-second hook timeout

#### Scenario: Binary too old

- **WHEN** the installed `ltm` rejects `--format recall`
- **THEN** the hook prints the notice line with a reason naming the minimum required `ltm` version, exits 0, and injects no recall block

### Requirement: The cue file is a plain-text enumeration that documents its own miss cost

The cue file SHALL be UTF-8 text with one POSIX extended regular expression per line. Lines that are empty or begin with `#` SHALL be ignored. The hook SHALL read the file at the path in `LTM_RECALL_CUES` when set, else `${CLAUDE_PLUGIN_ROOT}/hooks/recall-cues.txt`. The shipped file's header comment SHALL state that the list is an enumeration, that it will miss prompts that refer to the past in other words, and that the cost of a miss is the pre-hook behaviour (no automatic recall). When the file cannot be read the hook SHALL treat the gate as a miss for every prompt and SHALL write one line to stderr naming the path.

#### Scenario: Custom cue file overrides the shipped one

- **WHEN** `LTM_RECALL_CUES` points to a readable file containing only the line `deploy`
- **THEN** a prompt containing `deploy` is admitted and a prompt containing `上次` is not

#### Scenario: Unreadable cue file fails closed

- **WHEN** `LTM_RECALL_CUES` points to a path that does not exist
- **THEN** every prompt is a gate miss, stdout is empty, and stderr contains the path once

### Requirement: Session start reminds Claude that recall exists

The plugin SHALL register a `SessionStart` hook that prints one line to stdout naming the `ltm_query` tool and stating that cue-gated recall is active, for every `source` value (`startup`, `resume`, `clear`, `compact`). The hook SHALL run no query and SHALL exit 0 within 5 seconds.

#### Scenario: Resume also reminds

- **WHEN** a session starts with `source` equal to `resume`
- **THEN** the hook prints exactly one line containing `ltm_query`
