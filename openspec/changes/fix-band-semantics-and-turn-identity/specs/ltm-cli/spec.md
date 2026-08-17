## MODIFIED Requirements

### Requirement: Event recording is opt-in and off by default

`ltm query` SHALL NOT append any event to the memory event store unless `--record` is given. With `--record`, it SHALL append one `shown` event per emitted hit through the facade's event sink.

Reading usage history SHALL NOT be conditioned on `--record`. When a strategy consumes events, the event store SHALL be opened for reading whether or not recording is requested; `--record` governs only whether a `shown` event is appended afterwards. Binding the two together made `--strategy` silently ineffective without `--record`, because the strategy received an empty projection while the output continued to report the strategy's name.

#### Scenario: Default query leaves the event log untouched

- **WHEN** `ltm query` runs without `--record` and returns hits
- **THEN** the event store under `~/.claude-ltm/memory/` has the same content after the query as before

#### Scenario: Recording emits one shown event per hit

- **WHEN** `ltm query --record` returns 5 hits
- **THEN** exactly 5 `shown` events are appended, each anchored to the corresponding hit's chunk

#### Scenario: A strategy reads history without recording

- **GIVEN** an event store containing recorded history for some indexed turns
- **WHEN** `ltm query --strategy human-like` runs without `--record`
- **THEN** the strategy's ordering reflects that history, and no event is appended

## ADDED Requirements

### Requirement: Numeric options are validated before use

`ltm query` SHALL reject a `--k` value outside the range 1 through 1000 with a non-zero exit whose message names the accepted range. It SHALL NOT pass an unvalidated value into retrieval, where a negative count terminates the process through a standard-library precondition rather than an error message.

A value that is present but not parseable as an integer SHALL be rejected rather than silently replaced by the default: silent replacement reports success while doing something the caller did not ask for.

#### Scenario: A negative count is refused

- **WHEN** `ltm query "text" --all-projects --k -1` runs
- **THEN** the command exits non-zero, names the accepted range, and does not crash

#### Scenario: A non-numeric count is refused rather than defaulted

- **WHEN** `--k abc` is given
- **THEN** the command exits non-zero naming the accepted range, and does not run the query with the default count

### Requirement: Roots are containment-checked before anything is created

Every filesystem root the CLI resolves — derived root and memory root alike — SHALL be checked for containment against every corpus root in use **before** any directory or file is created under it. A root that resolves inside a corpus root SHALL be refused with a non-zero exit naming the offending path.

The check SHALL be bound to the corpus root actually in use, not to a fixed default. When the corpus root is overridden, a containment check against the default root permits a derived root inside the corpus being scanned, which is the read-only invariant's exact failure.

The CLI and its tests SHALL construct the service through the same code path, parameterised by roots. A separate constructor used only in production leaves the shipped guard unexercised while the tested path injects a substitute.

#### Scenario: Memory root inside the corpus is refused before creation

- **WHEN** the memory root resolves inside a corpus root and `ltm query --record` runs
- **THEN** the command exits non-zero naming the path, and no directory has been created under the corpus root

#### Scenario: Containment follows an overridden corpus root

- **GIVEN** a corpus root overridden to a directory `D`
- **WHEN** the derived root is set to `D` or to a path inside `D`
- **THEN** the command exits non-zero naming the path, and no index artifact is created inside `D`

### Requirement: An index built under a superseded anchor format is refused

When the index's recorded anchor format differs from the running binary's, `ltm query` SHALL refuse the query with a non-zero exit naming `ltm build --full`, in the same manner as an embedding-revision mismatch. It SHALL NOT rebuild the index implicitly during a query.

#### Scenario: Superseded anchor format names the rebuild command

- **WHEN** the index records an anchor format the binary no longer produces
- **THEN** the query exits non-zero, the message contains `ltm build --full`, and no results are returned
