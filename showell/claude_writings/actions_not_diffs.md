# Actions, Not Diffs

*Forward plan, 2026-04-18. Proposes a new wire format for the
LynRummy port — action-shaped rather than diff-shaped. Opens
with a brief tour of the current format to show why the gap
is structural, then the new shape with Elm + JSON sketches.*

**← Prev:** [Click and Drag](click_and_drag.md)
**→ Next:** [The Wire, Working](the_wire_working.md)

---

You asked for a wire format that gives me introspection into
the moves you make on the board. Not replay capability —
you already have that — but *intent visibility*. I want to
propose skipping the faithful port of the current wire and
jumping to a new shape, because the current shape can't
actually carry what you're asking for. Let me walk through
why.

## What the current wire carries

Four event types (constants in `games/lynrummy/events.go:29`):
`AdvanceTurn`, `MaybeCompleteTurn`, `PlayerAction`, `Undo`.
The interesting one is `PlayerAction`, whose JSON shape is:

```json
{
  "json_game_event": {
    "type": 2,
    "player_action": {
      "board_event": {
        "stacks_to_remove": [...CardStack...],
        "stacks_to_add":    [...CardStack...]
      },
      "hand_cards_to_release": [...HandCard...]
    }
  },
  "addr": "..."
}
```

The payload is a **diff**: which stacks come off the board,
which stacks go on, which hand cards get consumed. The
server validates that the diff is geometrically legal
(`validate_wire_event`) and persists the raw JSON to
`game_events`. On replay, `advanceBoard` applies the diff to
a running board state; `retroDetectAndAdvance` tries to
infer the *trick* the player used by running
`tricks.Detect(hand_cards_played, board_before)`.

A separate `lynrummy_plays` table stores the inferred
strategic layer (trick_id, description, detail_json). That
table is server-side only, not on the wire. It's populated
at ingest by re-running trick detection against the diff.

## Why this format can't carry intent

The structural limitation: **a diff describes a
post-state change, not the action that caused it.** Several
distinct actions can produce identical diffs, so the inverse
inference (diff → action) is lossy by construction.

Concrete failures of retro-inference:

- **Click-to-split vs drag-split-apart.** Both remove one
  stack and add two. Post-state is identical; the gesture
  isn't recoverable. (This isn't hypothetical — this came up
  as recently as this morning.)
- **Which side of a set the player targeted.** A set merge
  can land on either end with the same resulting cards.
  Post-state equality hides the target side, which is
  exactly the information I want to see when analyzing your
  play.
- **Sequenced tricks that bisect the same diff space.**
  SplitForSet and PeelForRun can produce overlapping
  mechanical outcomes; `tricks.Detect` picks one by
  heuristic. If the heuristic is wrong, we log the wrong
  trick.

The `lynrummy_plays` table papers over the gap by running
the inference at ingest, but it's inference not
observation. The same lossy-ness that makes replay-CRUD
readable makes agent-introspection unreliable.

## The proposed shape: actions-as-events

Instead of diffs, the wire carries **the action the player
performed**, tagged by kind. The server (and any replay) can
derive the post-state diff by applying the action to the
known prior state. The diff stops being the wire's concern.

Elm sketch of the type:

```elm
type WireAction
    = Split { stackIndex : Int, cardIndex : Int }
    | MergeStack { sourceStack : Int, targetStack : Int, side : Side }
    | MergeHand { handCard : HandCardRef, targetStack : Int, side : Side }
    | PlaceHand { handCard : HandCardRef, loc : BoardLocation }
    | MoveStack { stackIndex : Int, newLoc : BoardLocation }
    | Draw
    | Discard { handCard : HandCardRef }
    | CompleteTurn
    | Undo
```

JSON per action (one concrete example per kind):

```json
{"action":"split", "stack_index":5, "card_index":2}
{"action":"merge_stack", "source_stack":5, "target_stack":3, "side":"right"}
{"action":"merge_hand", "hand_card":{"value":8,"suit":"H","deck":0}, "target_stack":5, "side":"right"}
{"action":"place_hand", "hand_card":{"value":8,"suit":"C","deck":0}, "loc":{"top":140,"left":220}}
{"action":"move_stack", "stack_index":5, "new_loc":{"top":140,"left":220}}
{"action":"complete_turn"}
```

Each row tells me, unambiguously, *what the player did*.
"You split stack 5 at card index 2" means click-to-split on
a specific card — no inference needed. "You merged the 7H
from your hand onto the right of stack 3" tells me the
target side.

Identifiers (`stack_index`, `hand_card`) need to be stable
across the wire. Options I see:

- **Positional indexing.** `stack_index` is the stack's
  position in the board list. Simple but fragile — if the
  board reorders between sender and receiver, indices
  diverge. Acceptable for strict in-turn wire; fragile for
  async.
- **Content identity.** Reference stacks by their cards +
  position, like `stacksEqual` does. Unambiguous but
  verbose.
- **Server-assigned stable IDs.** Each stack gets an `id`
  when it's created (on deal, on split, on merge), and the
  wire references by ID. Cleanest long-term; requires
  server-side ID allocation.

My lean: start with **positional indexing for stacks, content
identity for hand cards**. Positional is fine for the
one-server-two-clients pattern we're building toward. Hand
cards are small enough that content identity is cheap, and
hand positions are more volatile (sort order, size) than
board stack positions within a single move.

## Replay and validation, now simpler

The diff-based format required `validate_wire_event` to
simulate the apply and re-check geometry. With actions, the
server logic becomes:

1. Receive action from player.
2. Apply action to known prior state → derive `(diff,
   newState)`.
3. Validate: action is legal (player's turn, cards are
   present, merge is geometrically legal, etc.).
4. Persist the action. Update prior state.
5. Broadcast to opponent.

Validation becomes a check on the action *and* the derived
new state, with full structural context. No inference
step. If a client sends a malformed action, the server sees
it directly.

Replay becomes: walk the action list, re-apply each to the
running state. Same as current, but the per-event payload is
richer and the "what trick did this use?" question is
answered by the action tag itself.

## Migration — clean cut

Per the `project_db_is_nukable` memory, production Gopher has
no durable assets. There's no corpus of V1-format games we
need to keep playable. So: clean cut.

- Drop the old wire format entirely. No support for reading
  V1 payloads from `game_events`.
- Drop the `lynrummy_plays` table (the strategic-inference
  layer). Its job is now served by reading the action tag
  directly.
- The existing `games/lynrummy/events.go` + `wire_validation.ts`
  + `gopher_game_helper.ts` become dead code once the new
  format is in.
- `retroDetectAndAdvance` in `views/games_replay.go` becomes
  a trivial walk over action tags.

If we ever get a corpus we care about keeping, we can write
a one-off migration script that runs trick detection against
the old diffs and emits best-effort action records. Not
worth building preemptively.

## Implementation path

The work splits across three places. Rough sequence:

1. **Action type in Elm** (`LynRummy.WireAction`). Define
   the sum type, write JSON encoders + decoders, add unit
   tests (both directions). Pure module; tests use the same
   `elm-test` harness as `GestureArbitration`.
2. **Action type in Go** (`games/lynrummy/wire_action.go`).
   Mirror the Elm shape. Discriminated union in Go is
   usually `struct { Action string; ...pointers to typed
   payloads... }`; or `interface{}` with type switch; your
   call on idiom. Cross-language equivalence tests can live
   where the existing conformance tests live
   (`games/lynrummy/conformance/`).
3. **Wire emit from Elm client.** Replace local `commitX`
   functions with "build WireAction + apply locally + send
   over HTTP." The apply-locally step stays so the UI
   responds instantly; the send is async.
4. **Wire receive in Go server.** Parse WireAction → apply
   → validate → persist → broadcast. Existing SSE
   infrastructure carries the broadcast.
5. **Wire receive in Elm client (opponent view).**
   Subscribe to the SSE stream, decode WireAction, apply
   to local model.

Steps 1-2 are pure and testable; could land before any
networking wires. Step 3 is where the existing commitX
functions fork: local apply stays, remote send is the new
outbound edge. Steps 4-5 are the round-trip plumbing.

## Effort re-framing

You're right that serialization is the cheap part. The
expensive parts of the current format weren't the JSON
bytes — they were the validation, the inference, and the
lossiness. Actions-as-events removes the inference entirely
and simplifies validation (it's now a direct question, not
a diff-reconstruction exercise). We should expect this to
come in faster than a "straight port" of the current wire
would have, because we're not replaying yesterday's
constraints.

Given we've been under budget throughout, and given the
current wire carries constraints from the Zulip era that no
longer apply, my recommendation is to skip the port, do the
clean cut, and build V2 directly. Under the bar-for-done's
logic, faithful porting applies when there's a working
reference to preserve — here the reference doesn't carry
what we need, so "faithful port" produces something we'd
immediately have to replace.

## What I'd like to know before starting

- Are positional indices (`stack_index`) acceptable for V1,
  or do you want server-assigned stable IDs from the start?
- How much validation should be on the Go side vs the Elm
  side? TS did most of it server-side; we could keep that
  shape or split responsibility.
- Order of operations: build actions + encoders + decoders
  first with no networking, then wire up HTTP/SSE? Or start
  with a single round-trip for one action type (e.g. just
  Split) and expand?

Standing by for the yes/no on the overall shape and the
three questions above.

— C.
