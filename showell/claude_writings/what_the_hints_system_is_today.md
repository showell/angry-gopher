# What the Hints System Is Today

*A descriptive walk through the current LynRummy hint/trick code.
No proposals. No speculation about changes. Just: this is what
exists, this is how it flows, these are the axes of complexity I
can see, and these are the flaws I notice.*

---

## What it is, in one sentence

Given a `(hand, board)` snapshot, the hints system enumerates
every legal move from three independent sources, annotates each
with a result-score preview, and returns the whole list. Clients
choose what to display.

---

## The three sources

### 1. `LegalHandMerges` — put one hand card onto a stack

Lives in `games/lynrummy/hints.go`. Two nested loops over the
hand × the board, times two sides:

```go
for _, hc := range hand.HandCards {
    for targetIdx, target := range board {
        for _, side := range []Side{LeftSide, RightSide} {
            merged := tryHandMergeMerged(target, hc, side)
            if merged == nil { continue }
            out = append(out, Hint{
                Kind:        HintMergeHand,
                HandCard:    &card,
                TargetStack: targetIdx,
                Side:        side,
                ResultScore: scoreAfterReplace(...),
            })
        }
    }
}
```

Returns `[]Hint`, a flat struct where unused fields stay at zero.

### 2. `LegalStackMerges` — push one board stack onto another

Same shape: O(stacks × stacks × 2 sides). Skips self-merge via
an index check.

### 3. `enumerateTrickPlays` — the seven trick recognizers

Lives in `views/lynrummy_elm.go`. Walks the canonical
`tricks.DefaultOrder` list:

```
HandStacks → DirectPlay → RbSwap → PairPeel → SplitForSet →
PeelForRun → LooseCardPlay
```

Each trick is a stateless singleton satisfying the interface in
`tricks/trick.go`:

```go
type Trick interface {
    ID() string
    Description() string
    FindPlays(hand []HandCard, board []CardStack) []Play
}
```

For each trick, `FindPlays` returns zero or more `Play` values.
Each play knows `Apply(board) → (newBoard, cardsConsumed)`. The
enumeration then scores each play by calling `ScoreForStacks` on
the post-Apply board and packages everything as a `trickPlayEntry`.

---

## The seven tricks, in their own words

Paraphrased from each sidecar — these are the canonical descriptions.

**`direct_play`** (SIMPLE, 69 lines) — one hand card extends an
existing stack. Iterates `(hand × board)`, tries RightMerge
first then LeftMerge for determinism. This is the simplest trick
and trivially overlaps with `LegalHandMerges`.

**`hand_stacks`** (INTRICATE, 257 lines) — hand already contains
a 3+ set or run; emit the whole group as a new stack. Three
buckets in order: sets by value, pure runs by suit, rb-runs
across all cards. Dedups doubles (can't have two K♥ in one set
or run).

**`rb_swap`** (INTRICATE, 183 lines) — substitute a same-value,
same-color, different-suit card out of an existing RedBlackRun;
kicked card must find a home (a same-value set with room, or a
PureRun that accepts it at an end).

**`pair_peel`** (INTRICATE, 187 lines) — two hand cards form a
pair (set pair, pure-run pair, or rb-run pair); peel a board
card to complete the triplet as a new 3-card stack.

**`split_for_set`** (INTRICATE, 169 lines) — hand card V finds
two same-value different-suit extractable board cards; combine
into a new 3-set. Rejects candidates matching the hand card's
suit (need three distinct suits).

**`peel_for_run`** (INTRICATE, 157 lines) — hand card V finds
board cards at V-1 and V+1 that can both be extracted from
different stacks; combine into a new 3-run. Apply ordering
matters: extract the higher `(stackIdx, cardIdx)` first so the
earlier index stays valid, then re-locate the second card by
identity.

**`loose_card_play`** (INTRICATE, 273 lines) — "move one board
card to a new home, then play a hand card on the resulting
board." Quadruple-nested loop: `(src stack × src card × dest
stack × stranded hand card)`. Pre-filters to only hand cards
that can't already direct-play (rescues orphans).

---

## The extraction primitive: `extractCard`

In `tricks/helpers.go`. Three legal peel shapes:

- End-peel: size ≥ 4, first or last card → shortened stack
- Set-peel: size ≥ 4 Set, any middle card → card removed
- Middle-peel: run (Pure or RB), both halves ≥ 3 → stack splits

Returns `(newBoard, extractedCard, ok)`. Does not mutate input.
Called by `pair_peel`, `split_for_set`, `peel_for_run`, and
indirectly via `peelIntoResidual` in `loose_card_play`.

---

## Detection: from actions back to trick IDs

`tricks/detect.go` has two closely related functions:

**`FindPlay(trickID, handCards, board) Play`** — submission-time
lookup. When a client POSTs a `PlayTrickAction` with a trick_id
and hand_cards, the server re-runs the named trick's `FindPlays`
and returns the first play whose hand-card multiset matches. The
result is used to compute a `TrickResultAction` that actually
gets logged.

**`Detect(handCards, board) string`** — retroactive attribution.
Walks `DefaultOrder`, runs each trick, returns the first
matching trick's ID. Used by the Elm session turn-log view and
by `/hints` to label each merge with a trick_id when possible.

Both use the same multiset match on hand cards. Neither verifies
the board-after state — ambiguity is possible in principle;
DefaultOrder makes it deterministic.

---

## Ranking (added today)

`tricks/hint_priority.go` — `RankHints(hand, board) []RankedHint`.
Enumerates all three sources into a uniform shape:

```go
type RankedHint struct {
    Kind            string    // "hand_merge" / "stack_merge" / trick_id
    HandCards       []Card
    ResultScore     int
    ResultStackType StackType
}
```

Tiered sort: `PureRun < RedBlackRun < Set < other`, `ResultScore
descending` within tier. Not currently called by `/hints` — the
endpoint still returns the three arrays separately, and the Elm
client's `pickBestHint` does its own `argmax(resultScore)`.
`RankHints` exists as a staging ground for the new priority logic
and has one passing test.

---

## Client consumption

### Elm (`Main.elm`)

GET `/hints` → decode three arrays → concatenate into flat
`List HintOption` with `{description, handCards, resultScore}` →
`pickBestHint` returns the one with max `resultScore` → show
description in status bar + highlight its hand cards in green.

Only **one** hint is surfaced to the user at a time.

### Python (`greedy.py`)

```python
atomic = (hand_merges) + (stack_merges)
multi_trick = [p for p in trick_plays if p["trick_id"] != "direct_play"]
best_kind, best = max(atomic + multi_trick, key=lambda h: h["result_score"])
```

Same pattern — flat-combine, pick argmax. Explicitly drops
`direct_play` entries because they duplicate `hand_merges`.

---

## Wire shape

GET `/gopher/lynrummy-elm/sessions/<id>/hints` returns:

```json
{
  "session_id": 14,
  "base_score": 1760,
  "hand_merges":  [<Hint>, ...],
  "stack_merges": [<Hint>, ...],
  "trick_plays":  [<trickPlayEntry>, ...]
}
```

`Hint` and `trickPlayEntry` have different field shapes. Client
code normalizes them into a common `HintOption` at decode time.

---

## Axes of complexity

1. **Three enumeration pipelines, three output shapes.** Client has
   to normalize.
2. **Seven tricks, each with its own `FindPlays` and `Apply`.**
   Shared helpers (`extractCard`, `substituteInStack`, etc.) keep
   the file sizes down but the conceptual surface is still wide.
3. **Computational cost varies by orders of magnitude.**
   `direct_play` is O(hand × board). `loose_card_play` is
   `O(src_stacks × stacks_size × dest_stacks × stranded_hand)`.
4. **Tricks know about extractability.** `pair_peel`,
   `split_for_set`, `peel_for_run`, `loose_card_play` all
   inspect the board's internal structure (what can be peeled
   without leaving incomplete stacks).
5. **DefaultOrder is load-bearing.** Both `Detect` and `FindPlay`
   assume it. Changing the order changes trick attribution.
6. **Score coupling.** Every hint carries `result_score`, computed
   by calling into the scoring code. If scoring rules change, every
   enumeration path sees it.
7. **Detection vs enumeration share code but differ in intent.**
   Detection wants "which trick explains a finished move?"
   Enumeration wants "what moves exist?" Both walk `FindPlays`.
8. **Apply-time index instability.** `split_for_set` and
   `peel_for_run` use `relocate` to re-find targets by identity
   because previous plays this turn may have shifted indices.
9. **Wire format has two representations per trick play.**
   `PlayTrickAction` (client-submitted, by ID) and
   `TrickResultAction` (server-stored, by board diff). Server
   expands the former into the latter via `FindPlay`.

---

## Flaws I notice (strictly descriptive)

- **`direct_play` and `hand_merge` overlap** by design. Python
  explicitly filters out `direct_play` trick entries as
  duplicates. Elm's `pickBestHint` can still pick either.

- **No unified contract for "what does a hint highlight?"**
  `hand_merge` implies one hand card. `trick_plays` imply N hand
  cards. `stack_merge` implies zero hand cards. The current UI
  (`hintedCards`) only highlights hand cards, so stack merges
  never show visual feedback on the hand.

- **Priority is pure score-descending.** Produces the
  DeepRummy-era behavior of surfacing the highest-scoring move
  regardless of whether a human would spot it. Captured in today's
  postmortem note about layout requirements — same class of issue
  for hint requirements.

- **`hand_stacks` prolific.** A hand with a 4-card run emits a
  single `[A,B,C,D]` candidate; but the presence of overlapping
  shorter runs can emit several. I haven't audited whether shorter
  subsets of a longer run both show up.

- **`loose_card_play` cost.** Quadruple-nested loop with a
  `simulateMove` in the inner check. On a busy board this is
  noticeably slow; no timing instrumentation in place.

- **Belt-and-suspenders validation.** `isValidGroup` after
  candidate selection in `hand_stacks`; `GetStackType` re-check
  before push in `pair_peel`. These exist because the upstream
  enumerators can produce candidates that don't classify
  cleanly. The re-validations work, but they imply the enumerators
  are slightly too permissive by themselves.

- **"Tricks" vs "hints" terminology is mushy.** Tricks are
  enumeration primitives producing Plays. Hints are what clients
  see (after `/hints` packages them). The words get used
  interchangeably in comments.

- **Mid-turn staleness.** Each play a client makes changes the
  board. The previous `/hints` response is stale immediately.
  Clients that want to play multiple cards in a turn have to
  re-fetch after each one.

- **No notion of "the one best hint."** `/hints` returns
  everything and trusts the client to pick. When Elm shows a
  single hint in the status bar, the server has no say in which
  one that is.

- **`RankHints` exists but isn't wired in.** The server endpoint
  still returns three arrays; the Elm client still does its own
  pick-max. The tiered sort is therefore tested but not visible
  to users yet.

---

## What lives where (quick map)

```
games/lynrummy/
  hints.go                    # Hint type + LegalHandMerges + LegalStackMerges
  tricks/
    trick.go                  # Trick + Play interfaces
    helpers.go                # extractCard + other shared primitives
    direct_play.go            # trick 1
    hand_stacks.go            # trick 2
    rb_swap.go                # trick 3
    pair_peel.go              # trick 4
    split_for_set.go          # trick 5
    peel_for_run.go           # trick 6
    loose_card_play.go        # trick 7
    detect.go                 # DefaultOrder + FindPlay + Detect
    hint_priority.go          # RankHints (staging, not wired)
    hint_priority_test.go     # one passing test against the opening hand
views/lynrummy_elm.go        # /hints handler; enumerateTrickPlays;
                             #   annotateHints (adds trick_id to each merge)
```

Total: ~1800 lines of Go + ~150 lines of `.claude` sidecars, plus
the Elm/Python client-side normalization.
