## ADDED Requirements

### Requirement: Recall-marked spans are excluded from indexable text

When extracting indexable text from a turn, the indexer SHALL remove every span that begins with `<!-- ltm:recall` and ends with the first following `<!-- /ltm:recall -->`, inclusive, matching across line breaks, before any chunk text, trigram, token, or vector is derived. A `text` block that is empty after removal SHALL contribute nothing. A span with an opening marker but no closing marker SHALL be removed through the end of that `text` block. Turns containing no marker SHALL be indexed exactly as before, so no rebuild is required for existing indexes. The marker prefix SHALL be defined once in the indexing module and reused by the writer of the recall format.

#### Scenario: An injected recall block does not become a chunk

- **WHEN** a user turn's text contains `<!-- ltm:recall v1 -->` … `<!-- /ltm:recall -->` around three pointered hits and the token `ZQXJ-7731` appears only inside that span
- **THEN** after `ltm build`, `ltm query ZQXJ-7731` returns no hit for that turn, and the turn's chunk text equals the turn text with the span removed

#### Scenario: Unmarked turns are unchanged

- **WHEN** a fixture corpus with no marker text is indexed before and after this change
- **THEN** the resulting `chunks` rows are identical

#### Scenario: Unterminated marker is removed to the end of the block

- **WHEN** a `text` block contains `<!-- ltm:recall v1 -->` with no closing marker
- **THEN** the text from the opening marker to the end of that block is excluded and preceding text in the block is kept

##### Example: Span removal

| Block text | Indexable text |
| ---------- | -------------- |
| `A <!-- ltm:recall v1 -->hit<!-- /ltm:recall --> B` | `A  B` |
| `<!-- ltm:recall v1 -->hit<!-- /ltm:recall -->` | (empty, contributes nothing) |
| `A <!-- ltm:recall v1 -->hit` | `A ` |
| `A B` | `A B` |
