Tasks 1–3 implement the `strategy-comparison` requirement **"Interleaved presentations are produced on the live query path"** and the `ltm-cli` requirement **"ltm query offers an opt-in comparison mode"**. Tasks 4–6 implement the `strategy-comparison` requirement **"Retrieval quality is evaluated against extracted known items"**. Each task names the design decision it carries out.

## 1. Comparison mode in the service

- [x] 1.1 Implements requirement **"Interleaved presentations are produced on the live query path"** and design decision **"Comparison mode lives in the service layer, not the CLI"**. Add a comparison entry point to the service taking query text, limit, scope, the two strategy identities, and a persistence flag; it returns the interleaved hits and the recorded presentation identifier. Behavior: strategy construction, harness invocation, and record persistence all happen here, so a future non-CLI caller needs none of them. Verify: the CLI passes arguments through and does not construct strategies, call the harness, or write records.
- [x] 1.2 Implements design decision **"One retrieval, two rankings"**. Retrieve the candidate list once and rank that same list with both strategies. Verify: a test in which retrieval is deterministic but called twice would produce different lists still yields two rankings over identical candidates — assert both sides' anchor sets are equal.
- [x] 1.3 Satisfies the requirement's clause that a comparison which cannot be recorded is not run. When no event store is available, fail with the existing message for that condition before presenting anything. Verify: no hits are printed and no record is written on that path.

## 2. CLI flag

- [x] 2.1 Implements requirement **"ltm query offers an opt-in comparison mode"** and design decision **"Comparison mode implies recording"**. Add `--compare` to the query subcommand; it implies `--record`, and passing both behaves identically to passing `--compare` alone. Verify: running with `--compare` alone appends events.
- [x] 2.2 Satisfies the requirement's mutual-exclusion clause. `--compare` with `--strategy` fails with a usage error naming the conflict, before any query runs. Verify: the error text names both flags and the exit status is the usage-error status.
- [x] 2.3 Satisfies the requirement's output clause. Human-readable output in comparison mode has the same shape as an ordinary query and reveals no per-position attribution. Verify: a test asserts the printed lines contain neither strategy identifier.

## 3. End-to-end lock

- [x] 3.1 Covers requirement scenario **"A recorded comparison reaches the scorer"** — the property whose absence motivated this change. Add a test that runs a comparison-mode query against a synthetic corpus, reads back the persisted record and events, feeds them to the comparison scorer, and asserts the events were attributed rather than counted as belonging to an untracked presentation. Verify: assert on the scorer's skipped-event counts being zero for that category, not merely that a report was produced — a report is produced even when everything is skipped.
- [x] 3.2 Covers requirement scenario **"The default path is unchanged"**. Assert that a query without the flag writes no presentation record and produces the same output as before. Verify: compare against the existing CLI output tests rather than a freshly written expectation.
- [x] 3.3 Covers requirement scenario **"Identical orderings during bootstrap are recorded, not rejected"**. With an empty projection, assert a comparison-mode query succeeds and the written record is a null comparison. Verify: the record's null-comparison flag is set and the invocation did not throw.

## 4. Known-item harness

- [x] 4.1 Implements requirement **"Retrieval quality is evaluated against extracted known items"** — its extraction clause. Add a harness that samples chunks from a corpus reader, derives one query per sampled chunk, and pairs it with that chunk as gold. Behavior: sampling is seeded and reproducible. Verify: two runs with the same corpus, sample size, and seed return equal aggregates.
- [x] 4.2 Implements design decision **"The known-item generator is committed; its output is not"** and the requirement's non-persistence clause. The harness's return type carries per-query-class aggregates only — no query text, no gold pointer, no chunk text. Verify: a test inspects the returned value's declared shape and asserts no member can carry corpus-derived text.
- [x] 4.3 Satisfies the requirement's skip-counting clause. A sample from which no usable query can be derived is skipped and counted, and the count is part of the returned aggregates. Verify: a synthetic corpus containing an unusable chunk yields a non-zero skip count.
- [x] 4.4 Covers requirement scenario **"All three channels are scored for every pair"** and its example table. Score each pair against the lexical-only, vector-only, and fused lists with the existing two-stage function. Verify: for a fixture where the gold chunk sits beyond the recall window on one channel and first on another, the outcomes differ per channel in the direction the example table shows.

## 5. Measurement script and record

- [x] 5.1 Add a committed script that drives the harness against a specified corpus and prints aggregates grouped by query class and channel, plus the skip count. Behavior: it takes the corpus root and derived-index root as explicit inputs and refuses to run unless both are given, for the same reason the tie-rate probe does — defaulting one of them silently measures a different index than the caller intended. Verify: omitting either root fails with a message naming the omission.
- [x] 5.2 Implements design decision **"The record must say what it does not cover"**. Produce a dated record under the measurements directory reporting the results. Satisfies requirement **"Retrieval quality is evaluated against extracted known items"** — its disclosure clause: the record states that it measures retrieval and not strategies, that the queries are extracted from the chunks they retrieve and so do not represent real queries, and that the population inherits the exclusion of retrieval failures invisible to the event log. Verify: all three statements are present and none is hedged into a form that could be read as covering strategy quality.

## 6. Honesty boundary

- [x] 6.1 Carries out the design's **Documentation constraint**. Confirm no artifact in this change states or implies that strategy comparison now has measurement support. Verify: the project instructions' sentence recording that absence is unchanged, and any artifact touching the subject says the mechanism exists while the data does not.
- [x] 6.2 Run the full test suite and confirm it passes.
