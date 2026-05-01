# Card-tracker query accelerator

## Status: landed across three phases (2026-05-01)

The accelerator is in production. The high-level shape:

- A 104-element `card_loc` array maps card-id → bucket tag, built per
  state from a `Buckets` namedtuple.
- A precomputed `NEIGHBORS[c]` table (built once at import) gives every
  partner pair `(c1, c2)` such that `{c, c1, c2}` is a legal 3-card
  group. 72 pairs per card; uniform across the 104-card space because
  Lyn Rummy run values wrap K → A.
- `is_live(c, card_loc)` answers "can c form a triple with two
  accessible partners?" in one short loop over `NEIGHBORS[c]` — no
  classify, no permutations, no allocations.

Two BFS call sites use it:

1. **Static pre-BFS filter** (`_all_trouble_singletons_live`): rules
   out boards where some trouble singleton has no live partner triple
   even at the start. Runs once per `solve_state_with_descs` call.
2. **Dynamic per-state prune** (`_any_trouble_singleton_newly_doomed`):
   inside `bfs_with_cap`, gated on group-completion events
   (`len(nb.complete) > parent_complete_count`). Catches singletons
   whose only partners just got sealed into COMPLETE.

The gating on the dynamic check is load-bearing — see "What we tried"
below — without it, the per-state cost dominates the prune savings on
the broader corpus.

## Cumulative numbers vs pre-session master

| metric | before | after | delta |
|---|---|---|---|
| `bench_outer_shell` full | 6238ms | 4288ms | **−31%** |
| `bench_outer_shell` solo | 7844ms | 5332ms | **−32%** |
| `baseline_board_2Cp` | 517ms | ~435ms | **−16%** |
| `baseline_board_2Sp` | 664ms | ~517ms | **−22%** |
| plan quality | better=19 same=41 worse=0 | identical | ✓ |

## What we tried

A lot of plausible-looking optimizations turned out to be net-negative.
The pattern that won: the accelerator wins when the alternative is
*genuinely expensive* (full classify with permutations, O(pool²)
liveness scans). It loses against early-return rule checks and against
per-state overhead with no consumer.

What landed:
- **Hoisting pass** (commits `fa5d4f4`, `b759682`): lifted redundant
  per-state work in `enumerate_moves` (`classify`, `neighbors`,
  splice/shift eligibility, push-trouble filter, frontier `tc` cache),
  and fixed a 3-of-6 ordering bug in the legacy `_singleton_is_live`
  along the way. Made the call sites' precondition shapes visible —
  the input contract the accelerator wanted.
- **Static filter via accelerator** (commit `31d3801`): replaced the
  O(pool²) classify-with-permutations scan with the O(72)
  neighbor-table lookup.
- **Gated dynamic prune** (commit `6b1b27b`): ran the same accelerator
  query per state, but only when a group just completed in the move
  that produced the state. The gating idea is what flipped this from
  net-negative to a 18–21% bench win.

What didn't land (don't re-derive these):
- Replacing `is_partial_ok` length-2 with a precomputed pair-partner
  set. The "5-branch tower" framing was misleading — `is_partial_ok`
  is an early-return chain that exits in ~3 ops for the dominant
  case, while a hash lookup needs ~10 ops.
- Hoisting `card_loc` into `enumerate_moves` as plumbing for future
  consumers. Building it per state without an immediate consumer is
  pure overhead.
- Pushing the dynamic doomed-singleton prune unconditionally on every
  state. The per-state cost dominated the prune savings; the gating
  on graduation events fixed it.

## Data shapes (reference)

`card_neighbors.py` exposes:

```python
def card_id(card): ...                  # (v, s, d) → 0..103
NEIGHBORS: list[list[tuple[int, int]]]  # 104 entries; each a list of partner pairs
ABSENT, HELPER, TROUBLE, GROWING, COMPLETE = 0, 1, 2, 3, 4
def build_card_loc(buckets): ...        # Buckets → 104-element list
def is_live(c, card_loc): ...           # bool, scans NEIGHBORS[card_id(c)]
```

Bucket tag membership is tested by range: `0 < loc < 4` covers HELPER,
TROUBLE, GROWING (the accessible buckets). COMPLETE and ABSENT both
fall outside.

## Group-membership semantics

The accelerator tracks bucket placement, not stack identity. Two
consequences:

- **Sufficient for liveness** because liveness only needs "is this
  card accessible?", not "which stack is it in?". Existing `state_sig`
  + lineage machinery handles stack identity for dedup.
- **Conservative on GROWING**: cards in a growing 2-partial are
  treated as accessible partners. They can't actually be released by
  any BFS move (growing isn't an extract source), so this is a
  correctness-safe over-approximation: false-positive liveness, never
  false-negative. Plan quality is preserved on every gate run we've
  done.

## Next: profiling

Working code with some edge cases that are still expensive
(tantalizing-card hands, the 2C'/2S' worst cases). The cheap
analytical wins are exhausted — the next move is to run a profiler on
`baseline_board_2Sp` (the worst remaining hot case) and find where the
seconds actually go. Likely candidates: `state_sig` (sort-of-sorts per
child), descriptor allocations in `enumerate_moves`, focus filtering
overhead. We've earned the wall-time spend.

## Open structural items (not yet attempted)

- **H9 / H10**: push the focus filter into `enumerate_moves` so
  non-focus moves aren't generated at all (currently
  `enumerate_focused` post-filters); specialize per-absorber. Largest
  unlanded structural win on the table.
- **Carry `card_loc` as state**: patch the array incrementally per
  move rather than rebuilding. Saves O(50) per state in exchange for
  an O(104) copy. Re-evaluate after profiling tells us where time
  actually goes.
- **Targeted doom propagation on completion events**: when a group
  graduates, iterate the newly-sealed cards' `NEIGHBORS` rather than
  re-scanning all trouble singletons. Phase 3's gated check already
  bounds the cost; further refinement only matters if profiling shows
  this branch is hot.
