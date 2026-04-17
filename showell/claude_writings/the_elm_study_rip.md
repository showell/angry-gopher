# The Elm Study Rip

*Written 2026-04-17. Status report, not retrospective. On today's rip of the gesture-study layer from `elm-port-docs/`.*

**← Prev:** [Two Directions](two_directions.md)

---

Status report. Today we ripped the Elm gesture-studies layer
from `angry-gopher/games/lynrummy/elm-port-docs/` to clear
ground for the upcoming playable-game port. The durable model
port stays. Below: what got cut, what we preserved, and which
bits of recently-earned vocabulary the exercise used.

## What changed

One commit (`469c4dc`): 19 files ripped, −6125 lines. The
harness files (`Main.elm`, `Drag.elm`, `Layout.elm`,
`Study.elm`, `Style.elm`, the root-level `Card.elm`,
`BoardBrowser.elm.bak`), the five gesture modules
(`src/Gesture/*`), the study-sink (`study_server.py`),
captured logs (`study_logs/*.jsonl`), the built artifact
(`elm.js`) and host page (`index.html`), and
`STUDY_RESULTS.md`. `check.sh` was simplified to drop the
gesture list; `README.md` rewritten to reflect the new scope.

A second commit (`157c3ff`) fixed a pre-existing test failure
in `CardStackTest` that I flagged during the rip-verification
pass — one assertion claimed deck-blind `stacksEqual`
"mirrors TS" when in fact the TS source is explicitly
deck-aware. Expected value flipped `True` → `False`;
description rewritten; 207/207 tests green.

## New vocabulary that did real work

- **Ebb and flow** made the scope of the rip legible. The work
  is an *ebb* — scaling back `elm-port-docs/` to its durable
  core before the next *flow* (wire a fresh host shell on top
  of the preserved LynRummy modules). Without the vocabulary,
  this rip would read as "delete a bunch of code" instead of
  "complete the current pole of the oscillation."

- **Layer 1 / Layer 2** — not a durable term, but a specific
  use of the *clarifying question* discipline you flagged. You
  said "mostly going to remove all of this code." I asked which
  of two legitimate readings you meant. The clarification
  prevented a disaster (ripping the durable model port we
  intended to build on today).

- **Asset-preservation checklist** (from
  `feedback_fearlessness_from_confidence`). Applied before the
  cut: grepped for Layer 2 imports of any Layer 1 module
  (none); skimmed the three meta-docs (`POSTMORTEM_PREP`,
  `OPEN_QUESTIONS`, `PORTING_NOTES`) to confirm they're
  Layer-2-adjacent; noted that `STUDY_RESULTS.md`'s numerical
  findings are information you said you remember as a reliable
  historian.

- **TS-as-source-of-truth** + the `feedback_display_vs_identity`
  memory. The failing test's mistaken claim about TS semantics
  dissolved when I went straight to
  `angry-cat/src/lyn_rummy/core/card_stack.ts`, where the
  original author had spelled out the inventory-accounting
  rationale explicitly ("origin_deck matters... deck-blind
  equality lets a client claim to remove 5♥(d0) while adding
  5♥(d1) it never held"). The fix aligned with the memory
  (referee/accounting code compares full identity).

- **Rip methodology** from
  `feedback_rip_features_fearlessly` + `feedback_fearlessness_from_confidence`.
  Commit message documented what was cut, one-line why, what
  was preserved, and verification result — per the rule that
  "a rip that preserves a useful insight is stronger than one
  that just deletes."

- **Consolidate knowledge**. This essay + the commit messages
  + the updated `README.md` are the consolidation half of the
  rip, done in the flow.

## State after

`elm-port-docs/` now contains: `src/LynRummy/` (15 durable
modules), `tests/LynRummy/*` (207 tests, all green), generated
`Fixtures.elm`, the six port-specific docs (`ARCHITECTURE`,
`OPEN_QUESTIONS`, `PORTING_NOTES`, `POSTMORTEM_PREP`,
`CONFORMANCE_FIXTURES`, `TS_TO_ELM`), `elm.json`, and the
simplified `check.sh`. Ready surface for today's upcoming
work: a fresh host shell for the playable game, built on top
of these modules.

Parked here. Next: the playable-game port.

— C.

---

**Next →** [Inventory of a Partial Port](inventory_of_a_partial_port.md)
