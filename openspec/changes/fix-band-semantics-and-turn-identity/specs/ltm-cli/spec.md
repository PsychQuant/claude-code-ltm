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

## ADDED Requirements

### Requirement: A command exists to inspect and repair the event store

`ltm memory` SHALL report, per event store file, how many records are readable and the file line numbers of those that are not, separating records that failed canonical decoding from records written under a superseded anchor rule. It SHALL print no record content — line numbers and counts only — because the store's privacy constraint is that nothing outside it ever carries record text.

With `--prune` it SHALL copy the file to a backup before changing it, then drop exactly the unreadable records and report how many were kept and how many dropped. Without `--prune` it SHALL NOT write.

The command's root SHALL be validated against the read-only corpus before any write, the same way the service validates it. A repair command that can write inside the corpus violates the corpus's read-only invariant with the one operation the invariant exists to prevent.

This command exists because `Failure messages name their remediation` is otherwise unsatisfiable for the event store: the anchor-rule refusal fires for every user who recorded events before the rule changed, and before this command there was no remediation to name.

#### Scenario: Inspection does not write

- **WHEN** `ltm memory` runs without `--prune` on a store containing unreadable records
- **THEN** it reports their line numbers and the file is unchanged

#### Scenario: Repair backs up first

- **WHEN** `ltm memory --prune` runs on a store containing unreadable records
- **THEN** a backup copy exists before the store is modified, and the command reports the kept and dropped counts

#### Scenario: The repair command refuses a root inside the corpus

- **GIVEN** the memory root resolves inside the read-only corpus
- **WHEN** `ltm memory --prune` runs
- **THEN** it exits non-zero naming the path, and writes nothing
