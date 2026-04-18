# Hints From First Principles

*Architecture doc for a tricks-based hint system, rebuilt from
scratch around product constraints we've settled today. Python is
the first customer; the UI retrofit follows.*

---

## What a hint is for

**A hint is the server's answer to a player who wants help.** It
names one concrete move they could make right now.

That's it. Not a ranking of all legal moves. Not a score-optimal
recommendation. Not a retroactive attribution of what just
happened. Just: "here's a thing you can do."

**A hint is not:**

- A scoring oracle. The board tells you scores; the hint doesn't
  pretend to optimize them.
- An enumeration. We don't list every legal merge.
- An analysis of stack-to-stack merges. That's a scoring tactic,
  not a how-do-I-move-forward question.
- A retroactive explanation. If a play is already in the log,
  the action itself records what trick it was.

The surface is tight on purpose. A hint is a compass needle, not
a map.

---

## The mission

The player is at a kitchen table. They look at their hand and
their shared board. They don't see a move. They press Hint.

The response should answer **the simplest question a beginner
would ask**: *"is there a card in my hand I can put on the
board right now?"*

If yes: show them that card, and where it goes. Done.

If no: step up the complexity, one rung at a time. Can they
build a run or set from multiple hand cards? Can they combine a
pair with a peeled board card? And so on, increasingly
strategic, until either a move is found or the system honestly
reports "no obvious play."

The hint system is about **unsticking**, not optimizing.

---

## The seven tricks, by role

We have seven recognizers already written. Each captures a
distinct pattern a human might notice. Their roles, ordered by
"how hard is this to spot?":

### Tier 1: a single hand card finds a home

**`direct_play`** — the simplest pattern. One hand card extends
an existing stack on the board. For a beginner, this is the
whole game. If any direct play exists, that is THE hint.

### Tier 2: the hand already contains a group

**`hand_stacks`** — three or more hand cards form a complete
set or run; push them onto the board as a new stack. Within
this trick, there's an internal priority:

1. Pure-suit runs (5♥ 6♥ 7♥) — easiest for humans to spot.
2. Red/black alternating runs — takes more parsing (two signals:
   value AND color).
3. Sets (three 7s across different suits) — same-value
   recognition, a different cognitive pattern.

### Tier 3: combine one hand card with a peeled board card

**`pair_peel`** — two hand cards form a pair, plus one peeled
board card completes a set or run of three.

**`split_for_set`** — one hand card finds two same-value cards
on the board that can be peeled; the three form a new set.

**`peel_for_run`** — one hand card at value V finds board cards
at V-1 and V+1 that can both be peeled; the three form a new
run.

These three are equally "strategic" — they all involve
disturbing an existing board stack to create a new one. I'd
guess pair-peel is the easiest to notice at the table
(humans see pairs fast), then split-for-set (same values
cluster visually), then peel-for-run (requires two-step
reasoning about predecessor + successor).

### Tier 4: the rearrangement trick

**`rb_swap`** — substitute a hand card into an existing
red/black run by kicking out the same-value same-color card it
replaces. The kicked card must find a new home.

This is hard to spot because it requires understanding the
existing run's color pattern. Steve has called it "the
substitute trick."

### Tier 5: the last-resort rearrangement

**`loose_card_play`** — move a board card to a new location
specifically to let a stranded hand card play. Quadruple-nested
loop; the most computationally expensive.

This is the "there's no direct play, but if I rearrange
something I can make one" trick. Almost never the visually
obvious move.

---

## Priority is processing order

The ranking criterion is not a metric. It's the sequence we
walk the tricks in. First trick to produce a play wins.

**The priority order** (my best first principles guess, worth
debating):

```
1. direct_play       ← beginner-favorite, one card, obvious
2. hand_stacks       ← pure runs, then rb runs, then sets
3. pair_peel         ← visually near-obvious
4. split_for_set     ← same-value clustering
5. peel_for_run      ← two-step reasoning
6. rb_swap           ← rearrangement, specialist pattern
7. loose_card_play   ← last resort, move-then-play
```

Within each trick, its `FindPlays` is already internally
ordered (or we can order it — `hand_stacks` needs its sub-tier
sort). We take the FIRST play from the FIRST trick that fires.

**Why ordering, not scoring:** a score metric encodes a
judgment ("higher is better") that drifts with scoring rule
changes. Ordering encodes a hierarchy ("simpler first") that
stays stable even if scoring rules evolve. The hierarchy is a
design decision we own explicitly.

**What makes tier 1 "favorite":** Steve's words — beginners
need to see one card and one card only that can get onto the
board. `direct_play` gives exactly that.

---

## The wire shape

**Server over-shares. Client filters.** Info is cheap on the
wire; it's not a sin to tell the client more than it strictly
needs. The client picks what it wants to use.

Shape proposal (subject to iteration):

```json
GET /sessions/<id>/hint
{
  "session_id": 42,
  "suggestions": [
    {
      "rank": 1,
      "trick_id": "direct_play",
      "description": "Play the 8♥ onto the 5♥-6♥-7♥ run.",
      "hand_cards": [ { "value":8,"suit":3,"origin_deck":0 } ],
      "action": {
        "kind": "merge_hand",
        "hand_card": { "value":8,"suit":3,"origin_deck":0 },
        "target_stack": 2,
        "side": "right"
      }
    },
    {
      "rank": 2,
      "trick_id": "hand_stacks",
      "description": "You have three hearts in a row: 6♥-7♥-8♥.",
      "hand_cards": [ ... ],
      "action": { "kind": "play_trick", "trick_id": "hand_stacks", "hand_cards": [...] }
    }
  ]
}
```

Each `suggestion` is the representative play for one trick:
- `rank` = position in the priority order
- `trick_id` identifies which recognizer produced it
- `description` is the human-readable label
- `hand_cards` are the cards to highlight in the hand
- `action` is a ready-to-POST wire action

**Why a list and not a single hint:** we over-share. A beginner
UI uses `suggestions[0]`. A strategic bot can scan the list and
pick differently. Debugging is easier when you can see what
each trick saw.

**Endpoint rename:** `/hint` (singular), not `/hints` — the new
semantic is "what's one thing I can do?" The old plural suggested
an enumeration.

**Empty list:** `"suggestions": []` means no trick fires. The
client shows "no obvious play." Never a 404.

---

## Why a Python-first rollout

Build Python client first, verify the shape feels right, THEN
retrofit Elm.

**Python as first customer** means:

1. **Forcing function for clean wire contracts.** Python can't
   afford any UI-specific hacks. If the shape works for Python,
   it works for anything.
2. **Agent-first testing.** A greedy bot or a solitaire bot that
   just takes `suggestions[0]` and plays it is a real end-to-end
   test of the hint system.
3. **Decoupled from rendering.** UI ergonomics (colors,
   highlighting, button states) shouldn't leak into the hint
   format. Building Python first protects that boundary.
4. **Faster iteration.** No Elm rebuild, no DOM, no browser. A
   script that plays turns against the server exercises the whole
   loop in seconds.

Once Python is stable — meaning `suggestions[0]` drives a
sensible sequence of plays across many sessions — we retrofit
Elm. Elm's concerns then are narrow: render the hint button,
highlight hand cards from `hand_cards`, display `description`
in the status bar, optionally show lower-ranked suggestions in
a collapsed detail.

**Anti-pattern to avoid:** building Elm-first with polish and
discovering too late that the shape is awkward for agents.

---

## The seven tricks as salvaged assets

The current `tricks/` package is in `_cribbed/`. Its
`FindPlays` implementations are known-good and backed by
conformance scenarios. We reimport them as-is when the rebuild
begins — no need to re-derive the enumeration logic.

What we DON'T salvage:

- `Detect` (retroactive attribution) — wire format carries the
  trick_id now, so this is unnecessary.
- `FindPlay` (at-submission expansion) — we're proposing that
  hints return a concrete `action` directly, not a `PlayTrick`
  that needs expansion.
- The score-annotation wrapping (`trickPlayEntry`,
  `annotatedHint`) — obsolete under the ordering regime.
- `LegalHandMerges` / `LegalStackMerges` — redundant with
  `direct_play`, and stack-merges aren't player-facing hints.
- `RankHints` — the metric approach we rejected.

Each of the seven trick files — `direct_play.go`,
`hand_stacks.go`, `pair_peel.go`, `split_for_set.go`,
`peel_for_run.go`, `rb_swap.go`, `loose_card_play.go` — can be
copy-pasted back into the new package with minimal changes.
They're good.

---

## What we're NOT doing

Calling these out because they were real features before and
their absence is a DECISION, not an oversight:

1. **No score-based ranking.** Rank = position in processing
   order.
2. **No stack-merge hints.** Player hints don't suggest
   stack-to-stack combines (scoring optimization, not a
   stuck-player problem).
3. **No retroactive trick detection.** The wire carries trick_id.
4. **No per-trick play enumeration.** Each trick contributes one
   representative suggestion. Callers that want all plays can
   call the trick directly if we later expose that.
5. **No mid-turn hint update.** Client re-fetches after each
   play; server has no notion of "still the same request."
6. **No score preview on suggestions.** If we find we need it,
   add it back. Starting without.

Each of these is a deliberate subtraction from what the old
system did. If we find the missing piece genuinely hurts, we
add it back — but we add it back with intention, not default.

---

## Test-first plan

Starting test (Go): `TestHint_OpeningHand_DirectPlayFirst`.

- Setup: `InitialState()` — canned opening board + seat-0 hand.
- Expected: the top suggestion has `trick_id: "direct_play"`
  with a specific hand card + target stack.
- Hardcoded expected values (per the
  `feedback_hardcoded_test_values` memory) so scoring changes
  don't silently drift the test.

Next test: `TestHint_EmptyHand_NoSuggestions`.

- Setup: hand-empty state.
- Expected: `suggestions: []`, no panic.

Then: `TestHint_ContrivedHand_HandStacksPureRunWins`.

- Setup: a board with no direct-play target + a hand that has
  a pure-run subset.
- Expected: `suggestions[0].trick_id == "hand_stacks"` with the
  pure-run cards, not an rb-run or set.

Python-side: a one-turn greedy that just POSTs `suggestions[0].action`
each call. Run against many sessions; the hand sizes should go
down and games should conclude without the server rejecting
anything.

---

## Open questions

Things the first pass will probably reveal:

- **Does every trick produce a useful "one representative
  play"?** `hand_stacks` can emit multiple; picking the pure
  run is easy. `pair_peel` can emit many; which is
  representative?
- **Is the hand-merge vs direct-play overlap a problem?** If
  `direct_play` always fires when a hand card can merge onto a
  stack, we never reach `hand_stacks` when the user has an
  extend-existing-stack play. That might hide runs in the
  hand. Might need to propose a lower-tier hint when a
  pure-run hand-stacks is also available.
- **Does the "order matters" principle survive contact with
  compound turns?** If a player takes the direct-play hint, the
  next hint re-evaluates on the new board. Should we cache
  anything?

These are best answered by watching the Python client play.

---

## The one-sentence summary

**Walk the seven tricks in priority order; return each
fired-trick's first play as a ranked suggestion; let the client
pick the top one. Don't enumerate, don't score, don't
retroactively explain. Just: here's a move.**
