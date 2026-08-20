## MODIFIED Requirements

### Requirement: An event is either scored, legitimately skipped, or rejected

When scoring, each interaction event SHALL fall into exactly one of **three** dispositions:

1. **Scored** — the event names a presentation present in the supplied records, that presentation is attributed, and the event's anchor is among its attributed anchors.
2. **Legitimately skipped** — exactly three cases, and no fourth: the event names no presentation at all (an interaction can originate outside a presented list); the event's presentation is a null comparison (required by the attribution rules above); or the event names a presentation that is absent from the supplied records.
3. **Rejected** — a data inconsistency; scoring SHALL fail loudly rather than skip. The causes are open to extension, and are currently: the named anchor was never attributed by an attributed presentation that IS present in the supplied records; the event's own generation disagrees with its presentation record's.

The set of *dispositions* is closed at three; the set of *rejection causes* is not, and adding one does not change the contract. An earlier draft of this requirement declared a closed four-way enumeration that folded the rejection causes into the top level, and the implementation written against it rejected on a third cause twelve lines below its own closed-enumeration comment. Enumerate the axis that is genuinely closed, not the one that will grow.

**"Presentation absent from supplied records" moved from Rejected to Legitimately skipped.** `PresentationID` is a randomly generated identifier that every recording query now attaches to its events (not only events originating from a formal comparison run), because a separate mechanism — spreading activation — depends on the same identifier to group co-presented anchors. As a structural consequence, most events naming a presentation absent from the supplied records are now ordinary production interactions that were never part of any comparison, not evidence of a broken harness. Because `PresentationID` is UUID-backed, collision between an unrelated production presentation and a genuinely-missing comparison record is not distinguishable by this check, and the two cases are no longer told apart: a comparison harness that generates a presentation, writes events against it, but fails to persist the matching record would previously have been caught here and is no longer caught by this requirement. This is an accepted, documented reduction in detection power, not an oversight — recovering it would require giving presentation identifiers used for comparison a distinguishable identity from those used only for spreading, which is out of scope for the change that introduced this trade-off.

Record-level validation runs before any event is scored and SHALL reject: a duplicated presentation identifier, an attribution naming a strategy outside the compared pair, the same anchor appearing twice in one presentation, and records that do not all compare the same pair of strategies.

The report SHALL carry the count of each legitimate skip so that the size of the scored population is readable from the report itself. An earlier implementation collapsed everything into a single silent skip, so a missing presentation record deflated the denominator with no trace in the output.

#### Scenario: An event naming a presentation absent from the supplied records is legitimately skipped

- **GIVEN** an event whose presentation identifier appears in no supplied record
- **WHEN** the report is computed
- **THEN** scoring succeeds and the event is counted among the legitimate skips, not rejected

#### Scenario: An event naming an anchor the presentation never showed is rejected

- **GIVEN** an attributed presentation that IS present in the supplied records, and an event referencing it with an anchor absent from its attribution
- **WHEN** the report is computed
- **THEN** scoring fails and names the presentation and the anchor

#### Scenario: Records comparing different strategy pairs are rejected

- **GIVEN** one presentation record comparing A with B and another comparing B with C
- **WHEN** a single report is computed over both
- **THEN** scoring fails rather than presenting the three strategies in one table

#### Scenario: Two strategies with the same identifier cannot be interleaved

- **GIVEN** two strategy instances that report the same policy identifier
- **WHEN** the harness is asked to interleave them
- **THEN** the invocation fails, because attribution is recorded per identifier and would credit neither side distinguishably

#### Scenario: Legitimate skips are counted

- **GIVEN** one event with no presentation, one event belonging to a null comparison, and one event naming a presentation absent from the supplied records
- **WHEN** the report is computed
- **THEN** the report reports one skip of each of the three kinds
