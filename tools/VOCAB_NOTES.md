# Action vocabulary notes (working file for the glossary conversation)

Captured while building the puzzle miner. Each row = one
word-or-phrase used in the system, with where it lives. Not
yet rationalized — that's the conversation we're saving for
after Phase 1.

> **Historical:** the DB schema and `POST /new-puzzle-session`
> sections that originally headed this file have been retired.
> Sessions live as JSONL files under
> `games/lynrummy/data/lynrummy-elm/sessions/` (full game) and
> `games/lynrummy/data/puzzle/sessions/` (puzzle); the wire
> endpoints are now `POST /gopher/lynrummy-elm/sessions/<id>/actions`
> and `POST /gopher/puzzle/sessions/<id>/actions`. The wire
> `WireAction` shape itself is unchanged.

## Wire (HTTP)
- `POST /gopher/lynrummy-elm/sessions/<id>/actions` body: a `{seq, action, ...}` envelope wrapping a WireAction
- `POST /gopher/puzzle/sessions/<id>/actions` body: same shape
- WireAction shape (from `views/lynrummy_elm.go`): JSON object
  with `action: "..."` discriminator.

## WireAction discriminators (the wire's verb set)
- `place_hand` — drop a card from hand onto the board at a
  fresh location.
- `merge_hand` — drop a card from hand onto an existing board
  stack (left or right side).
- `split` — divide one board stack into two.
- `merge_stack` — combine two board stacks.
- `move_stack` — relocate a board stack to a new position
  without changing its contents.

## BFS-internal "verbs" (extract sub-vocabulary)
(Originally Python; live now in the TS engine.) Live as the `verb` field of `ExtractAbsorbDesc`:
- `peel` — extract from an end of a length-4+ run, or
  any-position of a length-4+ set.
- `pluck` — extract from interior of a length-7+ run, both
  halves stay length-3+.
- `yank` — extract from interior of a length-5+ run, one
  half stays length-3+ (the other spawns trouble).
- `steal` — extract from end of length-3 run, or any
  position of length-3 set.
- `split_out` — extract from interior of length-3 run.

## BFS Move types (the planner DSL output)
- `ExtractAbsorbDesc` — verb-based extract + absorb onto
  trouble/growing.
- `FreePullDesc` — pull a TROUBLE singleton onto another
  trouble/growing target.
- `PushDesc` — push a trouble partial onto a helper
  (or growing engulfs helper).
- `SpliceDesc` — insert a trouble singleton into a helper
  pure/rb run, splitting it.
- `ShiftDesc` — peel a donor card to replace the stolen end
  of a length-3 run.

## Verb → Primitive layer
(Originally `verbs.py`; lives now in `games/lynrummy/ts/src/verbs.ts`.)
Public: `physicalPlan(initialBoard, hand, planDescs)` over
honest state. A "primitive" is a single-action dict with
shape `{action, stack_index, ...}` — i.e., a WireAction
without the wire (no session id wrapping).

## Gestures (UI-layer)
- A "gesture" = a drag path with timing. Captured live from
  the user's pointer in `Game.BoardGesture` /
  `Game.HandGesture`; for replay the path is either
  captured from the original drag (board) or synthesized
  from a linear interpolation between measured DOM rects
  (hand). Pure UI concept; not on the wire as such.

## Naming-tension observations (initial)
- The word **action** appears on the wire as the discriminator
  field (`"action": "place_hand"`), as the table name
  (`lynrummy_actions`), and informally for the BFS desc
  ("each move is an action").
- The word **move** is overloaded: `Move` is the BFS sum
  type; `move_stack` is a wire action; "make a move" is also
  a player verb.
- The word **primitive** is internal-only (Python `verbs.py`,
  Elm `Game.WireAction`). Maps 1:1 to wire action types.
- The word **verb** is internal-only — only the 5 extract
  flavors. Overlaps in spirit with "action" but lives
  inside Move desc, not on the wire.

## Steve's framing (2026-04-26)
- "A WireAction is really just an Action."
- "Wire is just a current artifact, not a constraint."
- The split between Move / Primitive / WireAction may
  collapse once Elm is fully autonomous.
