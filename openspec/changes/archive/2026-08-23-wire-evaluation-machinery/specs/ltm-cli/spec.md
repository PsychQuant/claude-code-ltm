## ADDED Requirements

### Requirement: ltm query offers an opt-in comparison mode

`ltm query` SHALL accept a `--compare` flag. With it, the command SHALL rank one retrieved candidate list with two strategies, present the interleaved ordering, and persist the presentation record and shown events for that presentation. Without it, the command's behaviour SHALL be unchanged.

`--compare` SHALL imply `--record`. Requiring both would offer a combination — comparing without recording — that produces nothing and only changes what the user sees, so the flag enables persistence for that invocation on its own. Passing both SHALL be accepted and behave the same as passing `--compare` alone.

`--compare` and `--strategy` SHALL be mutually exclusive, and giving both SHALL fail with a usage error naming the conflict. `--strategy` selects the single strategy that ranks the results; `--compare` ranks with two. Silently letting one win would make the printed ordering unattributable to either flag.

When no event store is available, `--compare` SHALL fail with the existing message for that condition and SHALL NOT print results. Printing an interleaved ordering whose record was lost is indistinguishable, to the reader of the output, from one that was recorded.

The human-readable output in comparison mode SHALL have the same shape as an ordinary query — one line per hit with its pointer — and SHALL NOT label which strategy contributed each position. Which side supplied a position is attribution data for the scorer; showing it to the user during the comparison is what interleaved evaluation exists to avoid.

#### Scenario: Comparison mode records a presentation

- **WHEN** `ltm query --compare` runs with an event store available and returns hits
- **THEN** one presentation record is written describing which strategy contributed each position, and one `shown` event per emitted hit refers to that presentation

#### Scenario: The flag implies recording

- **WHEN** `ltm query --compare` runs without `--record`
- **THEN** events are appended exactly as if `--record` had been given

#### Scenario: Comparison and single-strategy selection conflict

- **WHEN** `ltm query --compare --strategy human-like` runs
- **THEN** the command fails with a usage error naming the conflict, and no query is executed

#### Scenario: Output does not reveal attribution

- **WHEN** `ltm query --compare` prints hits in human-readable form
- **THEN** no line indicates which of the two strategies contributed that position
