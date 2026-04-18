# The Wire, Working

*Status snapshot, 2026-04-18 late. Present-tense essay: where
we stand right now with the action-shaped wire format in
place. Not a retrospective, not a forward plan. Light
reflection on the wire work specifically; other pieces get
brief mention only where they frame the present state.*

**← Prev:** [Actions, Not Diffs](actions_not_diffs.md)

---

As of this commit, you can play LynRummy through the Elm
client at `http://localhost:9000/gopher/lynrummy-elm/`, and
every move you make turns into a `WireAction` that lands in
Gopher's SQLite. I can tail
`/tmp/angry-gopher.log | grep lynrummy-elm` and watch each
action as it arrives, or browse
`/gopher/lynrummy-elm/sessions/<N>` and read the full action
list for any session. The loop is closed. Solo player, no
opponent yet, but observable end to end.

That's the milestone. Below, what's actually in place and
what the new format looks like in practice.

## What's live right now

- Elm client ships every commit as a `WireAction` (nine
  constructors: split, merge-stack, merge-hand, place-hand,
  move-stack, draw, discard, complete-turn, undo).
- Go-side mirror: interface + nine concrete structs + per-
  type `MarshalJSON` injection of the `"action"` tag.
- Format is pinned on both sides by exact-byte format-lock
  tests. Same four canonical JSON strings on the Elm side
  and the Go side; if either drifts, both suites break.
- Sessions: each page load of the Elm client gets a fresh
  session row on boot (server-allocated via
  `POST /new-session`). Every action carries the session id
  as a query param.
- Persistence: SQLite row per action. Monotonic `seq` per
  session. `action_kind` and raw JSON both stored — kind for
  fast filtering, JSON for everything else.
- Sessions browser: one list page, one detail page. Enough
  to read history without touching the database.
- 323 Elm unit tests + 18 Go wire tests, all green.

## The old format, briefly

The TS wire was diff-shaped: `stacks_to_remove`,
`stacks_to_add`, `hand_cards_to_release`. Replay recovered
*board states* cleanly but had to *retro-infer* the trick
the player used via `tricks.Detect`, because a diff can
correspond to multiple actions. Lossy for any question
about player intent. Not ported; replaced. One paragraph is
all it needs.

## The texture of the new format

A few things I've noticed now that the format has been
through a full round-trip and a few small iterations:

**The two sides are symmetric in a way that feels useful.**
The Elm `WireAction` sum type and the Go `WireAction`
interface are visually and structurally the same shape —
nine cases, identical field names in JSON, identical
nesting. Changes on one side don't go looking for the
matching change on the other; they're in the same line of
the same test file on the other side. The format-lock tests
are the contract, and both sides enforce it independently.
This is the "redundancy as asset" pattern from the bridges
essay, manifested in something small and concrete.

**Adding a new action type will be ~35 lines total.** One
Elm constructor + encoder + decoder branch + test (~15
LOC). One Go struct + `ActionKind` + `MarshalJSON` + decode
case + test (~20 LOC). No schema migration — `action_json`
stores whatever shape, `action_kind` is just the tag
string, and SQLite doesn't care. If we decide to add a
`TidyStack` action or split `Discard` into `Discard` and
`DiscardToDraw`, the work is bounded and local.

**Decoder errors are specific.** The Go decoder uses
`strictUnmarshal` to verify every required field is present
in the raw JSON before accepting. That means a malformed
action doesn't silently become `SplitAction{0, 0}` — it
returns `"missing required field 'stack_index'"`. Same on
the Elm side via Json.Decode's default behavior. If the
wire ever carries garbage, both sides will tell us which
field and which action type.

**Reading the log is reading the game.** This is the piece
I find most satisfying in practice. A line like
`session=2 seq=5 kind=merge_hand payload={"action":"merge_hand","hand_card":{"value":7,"suit":3,"origin_deck":0},"target_stack":8,"side":"left"}`
tells me *what happened*, not *what the board diff was*.
"You merged the 7♠ from your hand onto the left of stack 8"
— directly readable, no inference. When I asked for
introspection into your moves, this is what I meant; and
now that it exists, it's sharper than I expected. The log
tail IS the interface.

## On "this would be easy"

You predicted serialization would be the cheap part and
the over-the-wire piece would come in fast. Hypothesis
confirmed. A few contributing factors, for the record but
not to dwell on:

- The decision in `actions_not_diffs.md` to rewrite rather
  than port removed ~all the impedance friction.
- Tests-first for both the Elm type and the Go type turned
  the cross-language agreement into a checkable property
  rather than a reviewable-by-eye diff.
- The old format's replacement wasn't work we had to *do*;
  it was work we got to *skip*. The scaffolding dictated its
  own shape and the shape was already right.

Short version: nothing surprising, and nothing to mine for
lessons beyond "keep rewriting when the port can't carry
what you need."

## What this unlocks

The observability is the immediate win — I can see every
move you make, in real time, with full gesture fidelity.
The sessions browser gives you the same view.

The less-immediate wins: every remaining feature the game
wants (replay animation, undo, scoring, hints, player
turns) reads from or writes to this action stream. Replay
animation applies the action list to the initial board and
walks it forward. Undo appends an `Undo` action and the
client snapshots before each commit. Scoring reads the
stream to compute points-per-play. Turn flow gates which
actions the local player can emit.

None of those features require changing the wire. They
layer on it.

## Where the snapshot ends

The game is playable, observable, and persisted. The
infrastructure is complete enough that the remaining work
is content, not foundation. Two people could in principle
play through this wire right now if we added the broadcast
half and a turn machine; we haven't, but nothing in the
current code would need to be torn up to get there.

That's where we are.

— C.
