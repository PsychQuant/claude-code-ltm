Tasks 1–2 implement the ADDED requirement **"An authority table, not the strategy, decides which constraints govern it"**. Task 3 covers the MODIFIED requirement and the bound member's documentation. Tasks 4–5 cover the acceptance criteria and the documentation constraint. Each task names what it implements.

## 1. The authority table and the registry's move

- [x] 1.1 Implements requirement **"An authority table, not the strategy, decides which constraints govern it"** — its table clause — and design decision **"The authority table lives beside the seam, and the existing registry moves down to join it"**. Move the identifier-to-instance registry from the service layer into the strategy module unchanged, and have the service layer re-export it so existing callers compile untouched. Verify: the service layer contains no copy of the mapping, and a search for the strategy identifiers finds the moved file and the strategies' own identity properties, nothing else.
- [x] 1.2 Add the authority lookup alongside the moved registry, in the same file: identifier to the constraint set that identifier is held to. Behavior: the three shipped identifiers map to exactly what those strategies declare today, so the union is a no-op for them. Verify: assert each shipped strategy's declared set equals its authority entry — this is what makes acceptance criterion 5 mechanical rather than a claim.
- [x] 1.3 Satisfies the requirement's single-declaration clause. Confirm one enumeration of which strategies exist. Verify: a test asserts the registry's known set and the authority table's key set are equal, so adding to one without the other fails rather than drifting silently.

## 2. Composition at the seam

- [x] 2.1 Implements the requirement's composition clause and design decision **"The table governs the constraints and is silent on the bound, because it is keyed by identifier"**. Resolve the authority by identifier before any post-condition runs and take the union with the instance's set; the constraint check reads the union. Verify: the constraint loop reads the union and nothing else; the bound path is untouched, which the unedited bound tests confirm.
- [x] 2.2 Implements design decision **"Compose in one direction, so cross-call variance stops mattering"**. Behavior: the seam holds no state between calls and reads nothing outside its arguments and the table. Verify: the seam's type has no mutable storage and no synchronisation primitive; a reviewer can confirm this by reading the declaration.
- [x] 2.3 Covers requirement scenario **"An unknown identifier is refused rather than trusted"**. Add the named failure and raise it before re-ranking. Verify: assert no results are produced and the strategy's ranking method was never entered — not merely that an error was thrown.
- [x] 2.4 Implements design decision **"The table is registrable from inside the package, so tests can construct misbehaving conformers"**. Add the in-package registration entry point and register the deliberately-misbehaving conformers the existing violation tests rely on. Verify: the entry point is not visible from a module that imports the package without test access; the seam's violation tests pass with their own identifiers rather than borrowed ones.

## 3. Specification and the two members' documentation

- [x] 3.1 Covers MODIFIED requirement **"A strategy's additional acting condition is declared, and the seam enforces it"**. Update the member's own documentation to say it declares what the strategy holds itself to *in addition to* its authority, and why the composed set is what gates. Verify: the doc states the reason the guarantee holds — the composition's direction — rather than asserting that a strategy cannot weaken a check.
- [x] 3.2 Covers the requirement's clause that the table does not govern the bound. Update the bound member's documentation to record why an identity-keyed authority cannot decide it — the bound is configurable at construction, so two instances sharing an identifier may differ. Verify: the passage recording that the authority question is open **stays open**, now with the reason a table cannot close it; no artifact claims the bound is covered.

## 4. Regression locks

- [x] 4.1 Covers requirement scenario **"A declaration that varies between calls is composed away"** — the property the existing test conformer structurally cannot exhibit. Add a conformer whose constraint getter alternates, invoke it repeatedly through the seam with a violating ordering, and assert every call throws. Verify: revert the union to reading the instance's set alone and confirm this test goes red because a call was accepted — the existing conformer declares stored properties and would stay green.
- [x] 4.2 Covers requirement scenario **"The displacement bound still governs movement exactly as before"**. Verify: the existing bound tests pass with no edit — in particular the one asserting a strategy built with a larger bound produces a larger promotion, which is the test a per-identifier ceiling would have broken.
- [x] 4.3 Covers requirement scenario **"A strategy may hold itself to more than its authority requires"**. Assert the union is not merely the authority's set. Verify: replace the union with the authority's set alone and confirm this goes red — without it, a one-sided composition would pass 4.1 and 4.2.
- [x] 4.4 Covers requirement scenario **"The shipped strategies are unaffected"** and acceptance criterion 5. Verify: the existing strategy and displacement-bound tests pass unchanged, with no expectation edited to accommodate this change.

## 5. Honesty boundary and suite

- [x] 5.1 Carries out the design's **Documentation constraint**. Update the project instructions' entry on this defect: it currently narrows an earlier claim and points at this issue as the open gap. Verify: the record of the claim having been false and disproved by execution stays; what is added is what closed it and why the new claim is narrower — no artifact asserts a strategy is trusted to behave.
- [x] 5.2 Run the full test suite and confirm it passes.
