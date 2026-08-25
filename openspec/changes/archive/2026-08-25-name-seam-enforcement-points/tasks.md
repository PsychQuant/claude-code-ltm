## 1. Rewrite the requirement

- [x] 1.1 Replace the "MemoryStrategy is the sole seam between retrieval and memory" requirement in `openspec/specs/memory-strategy/spec.md` with the delta spec's version. Both original scenarios ("Retrieval is unchanged when the strategy is swapped", "A strategy cannot introduce candidates") must survive verbatim — a MODIFIED requirement replaces the whole block, and dropping a scenario is how change 25 lost clauses. Verify: after the edit, both scenario headings still appear under that requirement.
- [x] 1.2 Confirm the seven enumerated checks match the seam's implementation before the edit lands. Read `MemoryStrategy.rerank` in `Sources/LTMQuery/MemoryStrategy.swift` and record, for each of the seven, the violation case it raises. Verify: each numbered item in the spec text corresponds to a `throw` reachable from `rerank`, and no `throw` reachable from `rerank` is missing from the list. An enumeration that is wrong is worse than a summary.

## 2. Align the source comments

- [x] 2.1 In `Package.swift`, rewrite the target-declaration comment that currently says the compile-time-fact claim was downgraded to a dependency-graph convention and that moving the event encoding out of the core module would make it true. Replace the "would make it true" clause with a pointer to the rewritten requirement. Verify: the file no longer asserts that any refactor makes the prohibition a compile-time fact.
- [x] 2.2 In `Sources/LTMQuery/Module.swift`, rewrite the module note that says the two prohibitions have no enforcement point and that moving the event encoding out of the core module is what they need. Replace it with a pointer to the rewritten requirement, which names the enforcement points that do exist. Verify: the file no longer says the prohibitions have no enforcement point, because they do — just not the one the sentence implied.
- [x] 2.3 In `Sources/LTMQuery/MemoryStrategy.swift`, update the note on the validated-candidates type so it points at the rewritten requirement's trust-boundary paragraph instead of at issue 14. Verify: the comment names the requirement, and does not restate the rationale a second time.
- [x] 2.4 Search the tracked source tree for any remaining assertion that the prohibitions are or could become compile-time facts. Verify: the only surviving statements of that kind are in `openspec/changes/archive/`, which is historical and out of scope.

## 3. Confirm nothing else moved

- [x] 3.1 Run the full test suite. Verify: the count matches the pre-change run and no test changes status. This change edits specification prose and comments only, so any test movement means something unintended was touched.
- [x] 3.2 Confirm no type visibility, dependency edge, or seam check was altered. Verify: the diff contains no change to any `public`/`internal` keyword, no change to any target's `dependencies:` array, and no change to control flow inside `rerank`.
