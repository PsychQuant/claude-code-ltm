## MODIFIED Requirements

### Requirement: MemoryStrategy is the sole seam between retrieval and memory

The system SHALL expose exactly one abstraction through which usage history influences result ordering. That abstraction SHALL take an ordered candidate list carrying base scores and relevance bands, together with a projection of per-anchor statistics, and SHALL return a reordered result list. Retrieval SHALL NOT read the event store directly, and no strategy SHALL read the corpus directly.

**Those two prohibitions bind implementations, not the compiler, and this specification SHALL NOT be read as claiming otherwise.** A dependency graph controls which types a module can name; it does not control what a module can do. Any module that can open a file can read the event file or the corpus using the standard library alone, against a JSON Lines format whose field names this specification publishes. Two directions have been proposed for making the prohibitions type-level facts — moving the event type's coded representation out of the shared core module, and making the corpus-reading protocol and the anchor dereference method internal — and neither achieves it: the executable counter-examples that refuted the original claim used neither of those types, so removing them would not make those counter-examples fail. The prohibitions are stated because the design intends them, and the paragraphs below name what is enforced instead.

**Ordering correctness is enforced at the seam, by seven checks performed on every invocation.** They are enumerated here rather than summarised, because a summarising criterion acquires cases the enumeration never agreed to:

1. The strategy's reported identifier has an entry in the authority table; a strategy whose identifier has none is refused before any reordering occurs. Violation: `unauthorizedStrategy`.
2. The reported displacement bound is non-negative. Violation: `negativeDisplacementBound`.
3. Each position's relevance band equals the band at that position in the input order. Violation: `crossedRelevanceBand`.
4. The returned list is a permutation of the input candidates, compared as a multiset so that a duplicate cannot mask an omission. Violation: `candidateSetChanged`.
5. No candidate moves further than the displacement bound permits. Violation: `displacementBoundExceeded`.
6. Every placement constraint in the union of the authority table's entry and the strategy's own declaration holds. Violation: `movedAcrossTieRuns` for the tie-run constraint.
7. Each result's reported displacement, and separately its reported movement, equal the position change that actually occurred. Violations: `misreportedDisplacement` and `misreportedMovement` — two checks, because a strategy can report an honest displacement beside a fabricated movement.

Each violation named above is raised by a `throw` reachable from the seam's public entry point, and every such `throw` appears in this list. That correspondence is the reason the list is worth stating: an enumeration nobody can check against the implementation is a summary wearing a list's clothes.

A strategy that reads the corpus still cannot return an ordering these seven checks accept unless that ordering was already a legal reordering — at which point what it read did not change the legality of what it returned.

**The privacy boundary is enforced at the bytes that land, not at the seam.** The memory layer's canonical stores compare each line's decoded-then-re-encoded form against the original bytes, so a value that is not exactly what the schema produces is rejected. That check is indifferent to what any component read: reading corpus text is not the hazard the privacy boundary addresses; corpus text reaching the memory layer's files is, and that is where it is caught.

**The seam's entry point is unbypassable from outside the defining package, and the mechanism is a deliberate trust boundary rather than an omission.** The checked method takes a validated-candidates value whose initialiser is package-internal, so no caller outside the package can construct one and therefore none can reach the checked method directly; the only public entry runs the seven checks unconditionally. Inside the package that value can be constructed, which is what makes the seam's own violation tests writable. Whether a strategy's reported identifier and displacement bound require an authority of their own is a separate open question, tracked outside this requirement.

#### Scenario: Retrieval is unchanged when the strategy is swapped

- **WHEN** the same candidate list is passed to two different strategies
- **THEN** both invocations produce results over exactly the same set of candidates, differing only in order and in reported displacement

#### Scenario: A strategy cannot introduce candidates

- **WHEN** a strategy returns its result list
- **THEN** the returned list is a permutation of the input candidates, with no candidate added and none removed

#### Scenario: A strategy that reads the corpus gains nothing the seam will accept

- **GIVEN** a strategy that reconstructs candidate text by reading the corpus itself
- **WHEN** it returns an ordering that violates any of the seven checks
- **THEN** the invocation fails with the named violation for that check, exactly as it would for a strategy that read nothing

#### Scenario: The prohibitions are not compile-time facts

- **GIVEN** a module that does not depend on the memory layer
- **WHEN** it reads the event file using only the standard library
- **THEN** it succeeds, and this specification's prohibition is not thereby satisfied by the type system

##### Example: What removing the convenience types would and would not change

- **GIVEN** the two refuting tests recorded against this requirement — one writing and reading an event file without importing the memory layer, one reconstructing corpus text through the public corpus-reading protocol
- **WHEN** the event type's coded representation is moved out of the shared core module and the corpus-reading protocol is made internal
- **THEN** the second test stops compiling, the first still passes, and a rewrite of either against the standard library passes again — so the prohibition remains an implementation obligation either way

#### Scenario: The checked method cannot be reached from outside the package

- **GIVEN** a strategy conformer defined in another module
- **WHEN** a caller in that module attempts to invoke the checked method directly
- **THEN** it cannot, because the validated-candidates value the method requires has no initialiser visible outside the defining package
