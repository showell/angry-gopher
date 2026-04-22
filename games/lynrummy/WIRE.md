# Lyn Rummy wire format (Python-emitter scope)

**As-of:** 2026-04-21 (post-CardStack-ref refactor).
**Scope:** every wire shape the Python agent currently sends.
Elm-only actions (today: `undo`) are out of scope here — see
`wire_action.go` for the complete union.
**Status:** `STILL_EVOLVING`. Stable for Python's emitter
surface. Undo is not yet wired from the agent.

Canonical Go-side source: `games/lynrummy/wire_action.go`. Elm
counterpart: `games/lynrummy/elm/src/Game/WireAction.elm`. This
document is the reader-friendly surface for both.

## Endpoint + envelope

All actions POST to the same endpoint:

```
POST /gopher/lynrummy-elm/actions?session=<SID>
Content-Type: application/json
```

The body is an **envelope**: a `"action"` sibling plus an
optional `"gesture_metadata"` sibling. Keeps the action's JSON
clean (no telemetry fields) and leaves room for more metadata
kinds later without touching action shapes.

```json
{
  "action": { "action": "move_stack", "...": "..." },
  "gesture_metadata": {
    "path": [ { "t": 1700000000000.0, "x": 136, "y": 40 } ],
    "path_frame": "board",
    "pointer_type": "synthetic"
  }
}
```

`gesture_metadata` is **required** for intra-board actions
(`split`, `merge_stack`, `move_stack`) — the server rejects
them with 400 if `gesture_metadata.path` is missing or empty.
This keeps "Elm has no path to replay" from being a silent
degradation: every intra-board replay either runs the
captured path faithfully or the action was never accepted in
the first place.

`gesture_metadata` is **never** shipped for hand-origin
actions (`merge_hand`, `place_hand`). Neither sender ships a
captured path: Python doesn't know viewport pixels for hand
cards, and Elm — which could theoretically ship the human's
real viewport-frame path — deliberately doesn't. The viewport
path would be stale after any window resize / DPR change,
whereas Elm's replay can always synthesize from a fresh live
DOM measurement of the hand card's current rect. One
consistent replay path, regardless of sender.

`complete_turn` and `undo` also ship without
`gesture_metadata`.

`complete_turn` has its own endpoint:

```
POST /gopher/lynrummy-elm/complete-turn?session=<SID>
```

Its body is the envelope above, with `action` set to
`complete_turn`.

## Shared shapes

### `Card`

Every card in the double deck is globally unique by
`(value, suit, origin_deck)`.

```json
{ "value": 7, "suit": 3, "origin_deck": 0 }
```

| Field         | Type | Meaning |
|---|---|---|
| `value`       | int 1–13 | 1 = Ace, 11 = Jack, 12 = Queen, 13 = King |
| `suit`        | int 0–3  | 0 = Club, 1 = Diamond, 2 = Spade, 3 = Heart |
| `origin_deck` | int 0–1  | Which half of the double deck this card came from |

### `Location`

Board-frame coordinate pair. Origin is the board's top-left.

```json
{ "top": 20, "left": 40 }
```

Accepts both integer and floating-point on decode (Cat's old
drag UI sent floats; referee truncates).

### `CardStack`

Full contents of a board stack. When an action references a
stack, it **embeds the full CardStack object** — cards + loc —
rather than a positional index. Server resolves via
`FindStack(board, ref)` which matches on card-multiset + loc.
See the "Why CardStack, not an index" section at the bottom.

```json
{
  "board_cards": [
    { "card": { "value": 7, "suit": 2, "origin_deck": 0 }, "state": 0 },
    { "card": { "value": 7, "suit": 1, "origin_deck": 0 }, "state": 0 },
    { "card": { "value": 7, "suit": 0, "origin_deck": 0 }, "state": 0 }
  ],
  "loc": { "top": 200, "left": 130 }
}
```

`state` on each `BoardCard` is a turn-accounting flag
(`0 = FirmlyOnBoard`, `1 = FreshlyPlayed`, `2 =
FreshlyPlayedByLastPlayer`) — it's on the wire because the
server stores it per-card for age tracking, but `FindStack`
ignores state when matching stacks. Only card identity + loc
count.

## Actions sent by the Python agent

### `split`

Cleave the source stack into two at `card_index`. The first
`card_index` cards become the left half; the remainder the
right.

```json
{
  "action": "split",
  "stack": {
    "board_cards": [
      { "card": { "value": 13, "suit": 2, "origin_deck": 0 }, "state": 0 },
      { "card": { "value": 1,  "suit": 2, "origin_deck": 0 }, "state": 0 },
      { "card": { "value": 2,  "suit": 2, "origin_deck": 0 }, "state": 0 },
      { "card": { "value": 3,  "suit": 2, "origin_deck": 0 }, "state": 0 }
    ],
    "loc": { "top": 20, "left": 40 }
  },
  "card_index": 2
}
```

### `merge_stack`

Merge the source stack into the target on a given side.

```json
{
  "action": "merge_stack",
  "source": { "board_cards": [ ... ], "loc": { ... } },
  "target": { "board_cards": [ ... ], "loc": { ... } },
  "side": "right"
}
```

`side` is `"left"` or `"right"`.

### `merge_hand`

Merge a hand card onto a board stack on a given side.

```json
{
  "action": "merge_hand",
  "hand_card": { "value": 7, "suit": 3, "origin_deck": 1 },
  "target": { "board_cards": [ ... ], "loc": { ... } },
  "side": "right"
}
```

### `place_hand`

Place a hand card on the board at a specified location as a
new one-card stack.

```json
{
  "action": "place_hand",
  "hand_card": { "value": 7, "suit": 3, "origin_deck": 1 },
  "loc": { "top": 400, "left": 500 }
}
```

### `move_stack`

Reposition one board stack. No card movement.

```json
{
  "action": "move_stack",
  "stack": { "board_cards": [ ... ], "loc": { ... } },
  "new_loc": { "top": 20, "left": 310 }
}
```

### `complete_turn`

End-of-turn signal. No per-action fields.

```json
{ "action": "complete_turn" }
```

## Gesture metadata (sibling of `action`)

Required for intra-board actions (`split`, `merge_stack`,
`move_stack`); omitted for hand-origin actions (`merge_hand`,
`place_hand` — sender doesn't know where hand cards sit in the
viewport; Elm synthesizes those at replay time from its own
DOM).

```json
{
  "path": [
    { "t": 1776813872050.0, "x": 136, "y": 40 },
    { "t": 1776813872250.0, "x": 148, "y": 41 },
    { "t": 1776813873640.0, "x": 566, "y": 470 }
  ],
  "path_frame": "board",
  "pointer_type": "synthetic"
}
```

| Field         | Meaning |
|---|---|
| `path`        | Ordered samples. Each has `t` (unix-ms, float), `x`, `y` (ints). |
| `path_frame`  | `"board"` (origin at board top-left) or `"viewport"` (origin at browser top-left). Both senders emit `"board"` for intra-board drags: Python synthesizes in board frame directly; Elm captures viewport samples and translates them at send time by subtracting the live board rect. Board-frame paths are env-durable — viewport size, DPR, or monitor can change between capture and replay and the path still lands correctly. `"viewport"` only appears as a defensive fallback when the board rect wasn't measured in time; not expected in normal traffic. |
| `pointer_type`| `"synthetic"` (Python-generated) or `"mouse"` (Elm-captured human drag). Informational. |

## Coordinate frames — summary

- **Board frame.** Origin `(0, 0)` at the board's top-left.
  The wire's `Location` fields (`loc`, `new_loc`) are always
  board-frame. Python synthesizes gesture paths in board frame
  too.
- **Viewport frame.** Origin at the browser viewport top-left.
  Only relevant for Elm-captured live drags that cross the
  board widget boundary (hand→board). On the wire, that shows
  up as `path_frame: "viewport"` in `gesture_metadata`.

See `games/lynrummy/ARCHITECTURE.md` § "Frames of reference"
for the broader rule: pick the right frame, don't maintain
parallel coords.

## Why CardStack, not an index

Three benefits stacking:

1. **Stable across the reducer's reordering.** The server's
   reducer removes the affected stack and appends the result
   on every split / merge / move, so positional indices shift
   under it. CardStack references are content-based and stable.

2. **Readable at a glance in the raw JSON.** Someone eyeballing
   the actions table can see which stack an action referred to
   — "oh, this is the 7-set at (130, 200)" — without
   cross-referencing anything.

3. **Built-in divergence check.** The server compares the
   client-sent CardStack against what it has on the board via
   `FindStack` (multiset cards + loc). A mismatch means the
   client was operating on stale state, and the action is
   rejected at the wire boundary — no silent corruption.

`FindStack` matches by card **multiset** rather than sequence:
two clients that independently form the same logical group in
different visual orders still read as the same stack. Sequence
equality would be a stricter check and is possible if needed
later — multiset is the defensive, forgiving choice.
