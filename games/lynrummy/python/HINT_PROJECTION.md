# HINT_PROJECTION — how the Python hint-projection strategy works

Audience: future agent or developer porting the hint logic to Elm.

---

## 1. What `agent_prelude.find_play` does

`find_play(hand, board)` (agent_prelude.py, lines 30–94) is the
hand-aware outer loop. It returns:

```python
{"placements": [card, ...], "plan": [(line, desc), ...]}
```

or `None` if no play was found.

Search order (encodes game preference; no scoring):

- **(a) Pairs with a completing third in hand** — 3 cards leave
  the hand in one move, no BFS needed. Tried first across all
  meldable pairs.
- **(b) Pairs without a third** — project the pair as a 2-card
  trouble stack onto the board, run BFS. First pair that yields
  a plan returns.
- **(c) Singletons** — project each remaining card as a 1-card
  trouble stack onto the board, run BFS. First card that yields
  a plan returns.
- **(d) Nothing fired** — return `None`.

"Meldable pair" means `rules.is_partial_ok([c1, c2])` is true
(the two cards could be part of a legal set or run).

---

## 2. How the dirty-board constraint is enforced (`_try_projection`)

`_try_projection(board, extra_stacks)` (agent_prelude.py,
lines 121–162):

1. Builds `augmented = board + extra_stacks` (the board after
   the proposed placement).
2. Classifies every stack: stacks where `classify(stack) != "other"`
   are HELPER; everything else (including pre-existing singletons
   or 2-card partials already on the board AND the newly placed
   cards) goes into TROUBLE.
3. Passes `initial = (helper, trouble, [], [])` to
   `bfs.solve_state_with_descs`.
4. BFS must clear **all** trouble — not just the newly placed
   cards. You only get a plan if the hand card(s) AND every messy
   stack on the board can be resolved together.

This is the core constraint: projecting a singleton onto a board
that already has 2 trouble stacks means BFS must clean all 3 in
one plan. If it can't, the placement is rejected.

---

## 3. Actual transcript (seed 42, 7-card hands)

Run: `python3 tools/hint_demo.py` from `games/lynrummy/python/`.

```
=== Turn 1 ===
Hand (7): 3S:1  4S  8D:1  JD:1  4C:1  6D  QD:1
Board: 6 stacks (6 helper, 0 trouble)

Projecting hand cards...
  pair (3S:1, 4S): no plan
  pair (4S, 4C:1): no plan
  pair (JD:1, QD:1): plan found (1 step)
  singleton 3S:1: no plan
  singleton 4S: plan found (1 step)
  singleton 8D:1: no plan
  singleton JD:1: no plan
  singleton 4C:1: plan found (1 step)
  singleton 6D: no plan
  singleton QD:1: no plan

Hint: play [JD:1 QD:1]
  Step 1: peel TD from HELPER [TD JD QD KD], absorb onto trouble [JD:1 QD:1] → [TD JD:1 QD:1] [→COMPLETE]
  (drew: 8H JS:1)

=== Turn 2 ===
Hand (7): 3S:1  4S  8D:1  4C:1  6D  8H  JS:1
Board: 7 stacks (6 helper, 1 trouble)

Projecting hand cards...
  pair (3S:1, 4S): no plan
  pair (4S, 4C:1): no plan
  pair (8D:1, 8H): no plan
  singleton 3S:1: no plan
  singleton 4S: plan found (2 steps)
  singleton 8D:1: no plan
  singleton 4C:1: plan found (2 steps)
  singleton 6D: no plan
  singleton 8H: no plan
  singleton JS:1: no plan

Hint: play [4S]
  Step 1: peel TD from HELPER [TD JD QD KD], absorb onto trouble [JD:1 QD:1] → [TD JD:1 QD:1] [→COMPLETE]
  Step 2: splice [4S] into HELPER [2C 3D 4C 5H 6S 7H] → [2C 3D 4S] + [4C 5H 6S 7H]
  (drew: 2S:1 2D:1)

=== Turn 3 ===
Hand (8): 3S:1  8D:1  4C:1  6D  8H  JS:1  2S:1  2D:1
Board: 8 stacks (6 helper, 2 trouble)

Projecting hand cards...
  pair (8D:1, 8H): no plan
  pair (2S:1, 2D:1): plan found (3 steps)
  singleton 3S:1: plan found (5 steps)
  singleton 8D:1: no plan
  singleton 4C:1: plan found (3 steps)
  singleton 6D: no plan
  singleton 8H: no plan
  singleton JS:1: no plan
  singleton 2S:1: plan found (3 steps)
  singleton 2D:1: plan found (6 steps)

Hint: play [2S:1 2D:1]
  Step 1: peel TD from HELPER [TD JD QD KD], absorb onto trouble [JD:1 QD:1] → [TD JD:1 QD:1] [→COMPLETE]
  Step 2: push TROUBLE [4S] onto HELPER [KS AS 2S 3S] → [KS AS 2S 3S 4S]
  Step 3: peel 2C from HELPER [2C 3D 4C 5H 6S 7H], absorb onto trouble [2S:1 2D:1] → [2S:1 2D:1 2C] [→COMPLETE]
  (drew: 5S:1 5C:1)
```

**Reading the transcript:**

- Turn 1: Board is clean (all 6 stacks are helpers). The pair
  (JD:1, QD:1) fires because projecting it onto the clean board
  produces 1 trouble stack, and BFS cleans it in 1 step (peel TD
  from the existing TD-JD-QD-KD run to absorb the new pair).
  Three singletons also have plans at turn 1, but the pair is
  found first (search order: pairs before singletons).

- Turn 2: The (JD:1, QD:1) stack placed last turn is still on the
  board as trouble (we don't simulate BFS cleanup between turns).
  `find_play` projects each candidate onto this messy board; BFS
  must now clean both the new candidate AND the pre-existing
  (JD:1 QD:1) trouble stack. Singletons 4S and 4C:1 have plans
  (2 steps each); 4S is first in iteration order.

- Turn 3: Two trouble stacks on the board. The pair (2S:1, 2D:1)
  is found first and its 3-step plan cleans both pre-existing
  trouble stacks as well.

---

## 4. What the Elm port needs to mirror

The Elm hint MVP is a singleton-only pass. For each card in hand:

1. Build a projected board: `board ++ [singletonStack card]` where
   `singletonStack` wraps the card into a `CardStack` record.
   (`Bfs.solveBoard` takes `List CardStack`, not raw cards.)
2. Classify all stacks: `solveBoard` internally calls
   `StackType.getStackType` on each stack's cards.
   Helpers stay helper; everything else (including the new
   singleton and any existing partial stacks) goes into trouble.
3. Call `Bfs.solveBoard` on the projected board.
4. Return the first card whose projection has a plan, plus the
   plan itself for display.

The transcript makes this concrete: at Turn 1, projecting 4S
onto the 6-helper board creates 1 trouble stack; BFS finds a
1-step plan. At Turn 2, projecting 4S onto the board (which
already has 1 trouble stack) creates 2 trouble stacks; BFS finds
a 2-step plan that resolves both.

The key invariant: **the Elm classifier and BFS must agree on
what "trouble" means** — same classify logic, same BFS state
machine. If Elm's classify diverges from Python's, the hint
results won't match.

---

## 5. Known gap: pairs and triplets

The Python agent tries **pairs first** (step b above), then
singletons. The Elm hint MVP can start with singletons only and
still be useful — as the transcript shows, most turns have at
least one singleton with a plan.

The pair logic adds value when:
- A pair can be completed in-hand (no BFS needed at all).
- A pair projected onto a messy board yields a shorter plan
  than any singleton would.

The transcript shows that at Turn 1 the pair (JD:1, QD:1) fires
before singleton 4S even though both have 1-step plans — because
`find_play` iterates pairs before singletons. On a clean board
the distinction is minor; on a messy board pairs are often more
efficient.

Deferred work: implement pair detection in Elm hint logic once
singleton hint is working end-to-end.
