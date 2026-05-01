# Card-tracker query accelerator

## Status: in production (Python only).

The accelerator is in production on the Python side. **Not yet
ported to TS** (`games/lynrummy/ts/`); correctness is unaffected
but TS perf on tantalizing-card scenarios will lag Python until
ported. The high-level shape:

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

## Tried-and-rejected (don't re-derive these)

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

