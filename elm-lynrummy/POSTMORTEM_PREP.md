# Postmortem prep — LynRummy → Elm port (2026-04-13/14)

My (developer's) self-review ahead of the postmortem meeting.
Steve is PM; I'm the dev. Written unattended; notes are frank,
including self-criticism.

Context:
- Scope: port `angry-cat/src/lyn_rummy/` game-state + legal-move
  logic to Elm. Excluded: player/AI logic, UI.
- Knobs: durability=10, learning=10, efficiency=1.
- Wall time across two work blocks: ~2h 10m.
- Outputs: 6 durable Elm modules, 148 tests (all green), five
  commits, `PORTING_NOTES.md` with 19 process insights.

---

## What went well

### Technical

1. **Mulberry32 shared-fixture verification.** The single biggest
   confidence signal in the whole port. Captured the TS output
   for seed=42 (8 floats, 9 int-range pulls, 10-element shuffle),
   pasted as hard-coded expectations in Elm. Byte-identical pass.
   This is the quality of correctness evidence I'd want for every
   port and should be promoted to a general practice.

2. **Test coverage proportional to risk.** 148 tests across 6
   modules. Focused coverage on the central
   `getStackType` classifier, the referee's four stages, and
   bitwise-sensitive PRNG. Not box-ticking.

3. **check.sh is a one-command truth.** Every commit runs:
   compile + standalone type-check of each module + elm-test.
   Green means "nothing has rotted."

4. **Elm-idiomatic divergences documented.** Color derived
   (not stored). Parsers return `Maybe` (not throw). `stackType`
   derived (not precomputed). Each documented inline with
   rationale, traceable via PORTING_NOTES #5.

5. **Stage-based validator → Result.andThen.** The Elm port of
   the referee's four-stage early-exit pattern is cleaner than
   the TS source (monadic chain vs. repeated early-return).
   Prediction in insight #7 held up.

6. **Explicit open questions retained.** `CardStack.equals`
   deck-blindness, `CARD_WIDTH` placement, belt-and-suspenders
   checks — all flagged in PORTING_NOTES open-questions list
   rather than silently decided. Future-Claude has a proper
   punch list.

### Process

7. **Discovery-before-porting paid off.** Reading card / stack_type
   / card_stack / referee before writing any Elm caught the
   deck-blindness, the `CARD_WIDTH`-in-domain coupling, the
   recency-aging fields. No "rewrite it all" moments.

8. **Live PORTING_NOTES artifact.** Writing insights as they
   emerged, with `[initial]` / `[validated]` tags so revisions
   are diff-legible. Steve's `[Steve]` annotations add
   provenance.

9. **Autonomy calibration mostly correct.** I took reversible
   port-time calls (layout, field locations, aging semantics)
   without asking. I stopped at scope edges (JSON, protocol
   validation) and let Steve make the call.

10. **Commit cadence.** Three MILESTONE commits bracketed the
    major landmarks (foundation; geometry+PRNG; stop-point).
    Diffs are scoped and messages narrate the decisions.

11. **Vocabulary capture.** Past/current/future-Claude and -Steve
    handles let us reason about trust across sessions with
    precision.

---

## What went poorly / mixed

### Technical

1. **PORTING_NOTES structure drifted.** Mid-session I appended
   #16, #17 out of order, lost the title for #14, ended up with
   duplicated "Open questions" sections. Cleaned up in a later
   commit. Avoidable if I'd respected a fixed structure from
   the start.

2. **Type-annotation syntax error** (`([] : List Int)`) cost a
   build cycle. Elm doesn't support inline type annotations;
   I should have tested locally before committing. Caught
   quickly (build failed), no lost work, but unforced.

3. **Minor churn on `successor/predecessor/valueDistance`
   placement.** First pass put them in Card.elm. Had to move
   to StackType.elm for source parity. ~15 lines shuffled.
   Root cause: wrote Card.elm before reading stack_type.ts's
   layout. Lesson #3 in PORTING_NOTES covers this retroactively.

4. **`swapAt` is O(n²) over lists.** My Fisher-Yates shuffle
   uses a `List.indexedMap`-based swap that scans the whole
   list twice per swap. For a 104-card deck that's ~22k
   comparisons. Fine for deck sizes; lazy. Should use
   `elm/core Array` if performance becomes an issue. Noted in
   code comment.

5. **Never ran end-to-end test.** All tests are unit/stage
   scoped. I haven't exercised "start game → play a turn →
   validate end state" through the Elm code as a single trace.
   The TS source has `test_valid_game_sequence` which I ported
   as move-by-move unit tests, not a single narrative. A true
   end-to-end test is missing.

6. **`buildFullDoubleDeck` lacks a shared-fixture test.** I
   verified mulberry32 + Fisher-Yates byte-for-byte against TS,
   but `buildFullDoubleDeck` I only tested structurally (104
   cards, all distinct). An "exact deck order for seed=42"
   fixture would raise confidence another notch and took maybe
   60 seconds to capture.

### Process

7. **Took a "port" structure that might not fit a non-port
   session.** PORTING_NOTES is organized as insights-in-order.
   If someone else picks it up to do a different port, they
   have to read linearly. No index, no entry point, no
   "start here." It's a journal, not a handbook.

8. **snake_case vs camelCase naming** is a port-wide divergence
   I never explicitly flagged. TS source uses snake_case
   (`get_stack_type`); Elm port uses camelCase (`getStackType`).
   This means grep across the two codebases won't match. Should
   have been an insight: "case convention divergence has
   tooling cost."

9. **Slowness was budgeted but not fully used.** Efficiency=1
   was set to enable meta-process pauses. I took some ("which
   sub-binary first?") but could have taken more, especially
   around the PORTING_NOTES restructuring and the swapAt
   performance choice.

10. **Did not challenge past-Claude enough.** I set the tone
    that past-Claude's tests are subject to scrutiny, then
    ported them largely as-is. Two tests I felt were thin
    (`valueDistance` source test, `stack_type` source test)
    got additional cases from current-Claude, but the rest
    passed through. "Past-Claude wrote this, I'll trust" was
    probably still the default in practice.

11. **`pullFromDeck` deferral is a standing shortcut.** I
    couldn't cleanly port it because TS uses a mutable
    `DeckRef` interface. The honest Elm design is a
    `(newStack, newDeckState)` return, but I didn't draft
    even a stub. Defer list grew, future-me will need to
    revisit.

---

## Unknowns / standing questions for the meeting

### Technical questions

- **CardStack.equals deck-blindness (insight #11).** The TS
  `equals` uses `str()` which omits `origin_deck`; my port
  mirrors. Referee now uses this to match `stacks_to_remove`.
  In a two-deck game, two stacks with the same value+suit
  cards but different decks compare equal. Is this intentional
  (feature), or a latent bug past-Claude missed (shared
  blind spot)? If bug, fixing it is one line.

- **`CARD_WIDTH` in the domain layer.** I mirrored TS and kept
  it in `CardStack.elm`. Insight #12 flagged as port-time
  decision. Should the durable Elm port sever this coupling
  (move to a presentation module) on the way to durability=10,
  or leave it for source-diff legibility?

- **Belt-and-suspenders semantic checks.** `maybeMerge` rejects
  problematic merges at construction; `checkSemantics` also
  rejects Bogus/Dup stacks at turn-complete. Two layers enforce
  the same invariant. Consolidate (which), or preserve both
  (defensive)?

- **buildFullDoubleDeck shared-fixture test.** Should I capture
  a known-seed deck order from TS and add it to CardTest.elm,
  to close the mulberry32 → buildFullDoubleDeck validation gap?

- **End-to-end narrative test.** The TS `test_valid_game_sequence`
  is a 4-move story; my Elm version has each move as a separate
  unit test. Should there be a single narrative test that
  threads the board state through all four moves?

### Process questions

- **Did I surface the right judgment calls at the right moments?**
  E.g., did I escalate too few (drifted without consultation)
  or too many (broke flow)? Your read?

- **PORTING_NOTES: journal or handbook?** Currently a
  chronological journal. If it's meant to be handbook-shaped
  (reusable for future ports), it needs reorganization — index,
  by-phase chapters, "start here for a new port." Should we
  spend time reorganizing?

- **Split-durability in one repo.** Working in practice, or
  accumulating friction? Future-Steve will look at this repo
  and see both spike and durable code side by side. Is that
  clarifying or confusing?

- **Scope boundary.** JSON + protocol_validation are cleanly
  deferred for now. They'd add ~100 lines and unlock external
  interop. Is the unspoken plan to port them when interop is
  the goal, or consciously never (in favor of Go/TS at the
  boundary)?

- **Time budget calibration.** Your target was ~1h; we spent
  ~2h10m. Significant overage. Was the scope right-sized, or
  did durability=10 + learning=10 pull us long?

### Meta-learning questions (the harder ones)

- **Which insights in PORTING_NOTES actually generalize?** I
  tagged them as though they would, but I haven't tested them
  against a different-language port. Is there low-hanging
  validation (try insights against Python→Rust in your head,
  see which hold up)?

- **What did we NOT capture that we learned?** My fear: the
  most valuable insights are tacit and didn't make it into the
  notes. Worth 10 min of "what did you notice that isn't in
  there?"

- **Is the shared-fixture pattern scalable?** For mulberry32 it
  was perfect (deterministic, small output). For larger surfaces
  (a whole referee playthrough), capturing fixtures gets
  expensive. Where's the break-point?

- **What's the equivalent of shared fixtures for non-deterministic
  functions?** We dodged the question. For future ports of
  stochastic code, how do we validate?

---

## Action items I'd propose for the meeting

(If we agree on them.)

1. **Reorganize PORTING_NOTES** into handbook form: index +
   "starter kit" + chronological appendix.
2. **Decide on the three open technical questions** (deck-blind
   equality, CARD_WIDTH, belt-and-suspenders) and close them
   as resolved.
3. **Add a `buildFullDoubleDeck` shared-fixture test** using a
   captured TS trace.
4. **Add an end-to-end narrative test** that threads board state
   through a full multi-move turn.
5. **Explicit scope decision**: port JSON + protocol_validation
   now, later, or never.
6. **Capture "what didn't make it into PORTING_NOTES"** as a
   final meta-insight pass.

---

## Self-grade (honest)

- **Code quality**: 8/10. Clean, Elm-idiomatic where appropriate,
  divergences documented. Points off for the `swapAt` O(n²) and
  the `pullFromDeck` deferral.
- **Test rigor**: 8/10. Shared-fixture pattern was excellent;
  buildFullDoubleDeck gap and end-to-end absence keep this
  from 9.
- **Process discipline**: 7/10. Autonomy and judgment calls
  mostly right; PORTING_NOTES drift was sloppy; took some meta
  pauses but not as many as efficiency=1 invited.
- **Meta-learning capture**: 7/10. Insights are there but
  journal-shaped. Useful now, hard to reuse later without a
  reorganization pass.

Overall: solid delivery on scope #1 (durable assets for LynRummy).
Scope #2 (lessons for future ports) is staged but not packaged.
Work left to do before we can declare victory on #2.
