## Context

Two evaluation paths exist in code. Neither runs.

The comparison path scores interleaved presentations: a record says which strategy contributed each position, later interaction events are attributed through it, and the report aggregates preference per query class. Every piece of that is implemented and tested. What is missing is the first step — something has to present two strategies interleaved and write the record. The harness that does the interleaving has no caller outside its own tests, and the record type is constructed nowhere else. The query path's opt-in event recording writes a presentation identifier that no record describes, so the scorer classifies every such event as belonging to an untracked presentation and drops it. This is a legitimate skip in the scorer's contract, which is why it is silent.

The retrieval path scores a query against the turn it should have retrieved, in two stages and per channel. Also implemented, also uncalled, for a simpler reason: nothing produces the pairs. An earlier tokenizer measurement produced them by extraction — sample a chunk, take a substring as the query, treat the chunk as gold — and that measurement's own record notes it should be redone through a proper harness when one exists.

The two paths need opposite things. Retrieval evaluation needs query-and-gold pairs and no usage history. Comparison evaluation needs usage history and no gold at all, because the user's choice is the criterion. Conflating them produced the framing this change replaces.

There is a bootstrap consequence worth stating up front. With no recorded history, every anchor's net strength is zero, the bounded reordering core's strict comparison never fires, and all three strategies return the input order unchanged — which the comparison capability already names as a null comparison and excludes from scoring. So the comparison path produces nothing until interaction events accumulate, and the first place it can produce anything is where retrieval ties are dense.

## Goals / Non-Goals

**Goals:**

- Make the query path able to produce interleaved presentations, so that ordinary use accumulates the material the comparison scorer consumes.
- Give the two-stage and per-channel retrieval scoring functions their first caller, and produce one dated measurement record from it.
- Keep query text out of every durable surface: generated at measurement time, used, discarded.
- State the bootstrap behaviour and the unchanged honesty boundary in the artifacts, rather than leaving a reader to discover that the mechanism produces nothing yet.

**Non-Goals:**

- Producing a strategy-comparison measurement record. It requires accumulated real usage.
- Synthesising usage history.
- Changing default behaviour of the query command.
- Collecting negative cases. The comparison capability's existing exclusion stands.

## Decisions

### Comparison mode lives in the service layer, not the CLI

The service already owns strategy selection, event-store access, and the retrieval call. Comparison mode is a second shape of the same operation: retrieve once, rank twice, interleave, record. Putting it in the service keeps the CLI a thin argument parser, and makes the behaviour reachable by any future caller — a future MCP surface would otherwise need to reimplement it.

**Alternative rejected — assemble the comparison in the CLI.** It would put strategy construction, harness invocation, and record persistence into an argument-parsing layer, and a second caller would have to duplicate all three. That is the two-writers failure this project has repeatedly paid for.

### One retrieval, two rankings

The candidate list is produced once and both strategies rank that same list. Retrieving twice would let the two sides differ for reasons unrelated to the strategies, and the comparison would silently measure retrieval variance instead of strategy preference.

### Comparison mode implies recording

A comparison that is not recorded produces nothing and changes what the user sees for no benefit. Rather than allow an incoherent combination, requesting comparison mode enables event recording for that invocation. The user does not have to remember to pass both.

**Alternative rejected — require both flags and error when only one is given.** More surface, more to explain, and the error would exist only to describe a combination with no use.

### The known-item generator is committed; its output is not

The generator samples from a corpus at run time and derives queries from sampled chunks. Both the queries and the gold pointers are transient: they exist for the duration of the measurement and are never written to disk. What is committed is the generator, its sampling discipline, and the aggregate numbers it produced — which is exactly the shape the earlier tokenizer probe used, and which satisfies both the privacy boundary and the measurements directory's expectation that a record ships with a way to re-run it.

### The record must say what it does not cover

Three limits belong in the record because a reader will otherwise assume more than it establishes: the known-item queries are extracted from the chunks they retrieve and so do not represent real queries; the population excludes retrieval failures invisible to the event log; and retrieval quality says nothing about strategy quality. The last one matters most, because this change's whole context is strategy comparison, and a retrieval record filed under that context invites exactly that misreading.

## Implementation Contract

**Behavior.**

The query command accepts a comparison flag. In that mode it retrieves once, ranks the candidate list with two strategies, interleaves the two orderings through the existing harness, prints the interleaved result in the same shape as an ordinary query, and persists both the presentation record and the shown events for that presentation. Without the flag, behaviour is byte-identical to today.

A separate committed script runs the known-item evaluation: it samples chunks from a specified corpus, derives one query per sampled chunk, scores each against the lexical-only, vector-only, and fused channels using the existing two-stage function, and prints aggregate results grouped by query class. It writes no queries and no gold pointers to disk.

**Interface and data shape.**

- The service gains a comparison entry point taking the query text, limit, scope, the two strategy identities, and a flag for whether to persist; it returns the interleaved hits plus the presentation identifier that was recorded.
- The CLI gains one flag on the query subcommand. Passing it enables event recording for that invocation without requiring the recording flag as well. Passing an unknown strategy name fails with the existing unknown-strategy message.
- The known-item harness exposes a function taking a corpus reader, a sample size, a seed, and a retrieval entry point, returning per-query-class aggregates of the two-stage outcome for each of the three channels.
- No query text, gold pointer, or chunk text appears in any persisted record, in the harness's return type, or in the script's printed output. Aggregate counts and the closed query-class labels only.

**Failure modes.**

- Comparison mode with no event store available fails with the existing message for that condition rather than silently discarding the record — a comparison that cannot be recorded is not run.
- Comparison mode where both strategies produce the same ordering records a null comparison, which is the existing represented state, and is excluded by the scorer. This is expected during bootstrap and is not an error.
- The known-item generator failing to derive a usable query from a sampled chunk skips that sample and counts the skip; the count appears in the printed output. A silent skip would let the effective sample size drift from the requested one.

**Acceptance criteria.**

1. Running the query command with the comparison flag against a corpus with an event store produces a persisted presentation record whose attribution names both strategies, and shown events referring to that presentation.
2. Feeding those persisted records and events to the comparison scorer produces a report — that is, the events are no longer classified as belonging to an untracked presentation. This is the property whose absence motivated the change and must be asserted end to end, not inferred from the parts.
3. Running the query command without the flag produces output byte-identical to before the change, and writes no presentation record.
4. The known-item harness, run over a synthetic corpus with a fixed seed, returns per-channel outcomes for every sampled pair, and the same seed returns the same aggregates on a second run.
5. Neither the persisted record, the harness's return value, nor the script's output contains query text, chunk text, or a gold pointer. Asserted by a test over the serialised record and the harness's return type, not by inspection.
6. A dated record exists under the measurements directory reporting the known-item results per query class and per channel, and states the three limits named in the decisions above.
7. The whole test suite passes.

**Scope boundaries.**

In scope: the service comparison entry point, the CLI flag, the known-item harness and its script, the two specification updates, the tests in the acceptance criteria, and the one retrieval measurement record.

Out of scope: any strategy-comparison measurement record; synthetic history; changes to the scoring code, the harness's interleaving logic, or the strategies; negative-case collection; making comparison mode default.

**Documentation constraint.** The project instructions state that strategy comparison has no measurement support and that no evaluation set exists. That statement remains accurate after this change and must not be edited to suggest otherwise. The accurate update, if one is made, is that the mechanism now exists and the data does not.
