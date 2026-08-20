## MODIFIED Requirements

### Requirement: ltm query prints pointered hits in human and JSON forms

`ltm query <text>` SHALL print up to k (default 20) hits. Human-readable output SHALL show rank, project, timestamp, snippet, and the pointer. With `--json`, output SHALL be a JSON array whose objects each carry `project`, `sessionId`, `uuid`, `timestamp`, `snippet`, `score`, and `band`; when a reordering strategy is active each object SHALL additionally carry the seam's displacement and reason fields; when event recording produced a presentation identifier for that hit, the object SHALL additionally carry a `presentation` field containing that identifier.

#### Scenario: JSON output is machine-complete

- **WHEN** `ltm query "fixture phrase" --json` returns 3 hits
- **THEN** the output parses as a JSON array of 3 objects and every object contains non-empty `project`, `sessionId`, `uuid`, `timestamp` fields plus `snippet`, `score`, `band`

#### Scenario: JSON output exposes the presentation identifier when events were recorded

- **WHEN** `ltm query "fixture phrase" --json --record` returns hits and successfully writes events
- **THEN** every object in the output array carries a `presentation` field, and running the same query without `--record` produces objects with no `presentation` field
