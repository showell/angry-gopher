# Card-tracker query accelerator — design sketch

## Status

**Phase 1 (hoisting) — landed.** Commits `fa5d4f4`, `b759682` (2026-05-01).
Lifted redundant per-state work from `bfs.py` / `enumerator.py`
(`classify`, `neighbors`, splice/shift eligibility, push-trouble filter,
frontier `tc` cache) and fixed a 3-of-6 ordering bug in
`_singleton_is_live`. The hoisted call sites (`helper_kinds`,
`splice_helpers`, `shift_helpers`, `absorber_shapes`) shaped the
accelerator's input contract.

**Phase 2 (accelerator) — landed.** Commit `31d3801` (2026-05-01).
`card_neighbors.py` exposes `card_id`, `NEIGHBORS`, `build_card_loc`,
and `is_live`. `_all_trouble_singletons_live` in `bfs.py` now uses the
accelerator; the standalone `_singleton_is_live` helper is gone. 19%
speedup on `bench_outer_shell` full (6280ms → 5114ms); plan quality
unchanged.

**Phase 3 (gated dynamic doomed-singleton prune) — landed.** Commit
`6b1b27b` (2026-05-01). `_any_trouble_singleton_newly_doomed` runs
inside `bfs_with_cap`'s child loop, gated on
`len(nb.complete) > parent_complete_count`. The gate matters: the
ungated version was net-negative (+11–17% on `bench_outer_shell`)
because the per-state `build_card_loc` cost dominated on the larger
population of non-graduating states. Restricting the check to states
that just completed a group — the only way a partner can move out of
the accessible pool — makes the work track its actual cause.

5-run means after Phase 3:
- `baseline_board_2Cp`: 504 → 435ms (−14%)
- `baseline_board_2Sp`: 624 → 517ms (−17%)
- `bench_outer_shell` singleton-only: 6581 → 5428ms (−18%)
- `bench_outer_shell` full: 5684 → 4479ms (−21%)

The earlier sections describe the design as implemented.

## The core structure

104 entries, one per card (value 1–13, suit 0–3, deck 0–1 → id = (value−1)×8 + suit×2 + deck).
Each entry holds a bucket tag: `helper | trouble | growing | complete | absent`.

```python
card_loc = [ABSENT] * 104   # filled from a Buckets state
```

Building it from a `Buckets` namedtuple is O(total board cards) ≈ O(50) in practice.
Reading it is a single array index.

---

## The neighbor table

Precomputed once at module load, never changes.

For each card `c`, `NEIGHBORS[c]` is the list of all pairs `(c1, c2)` such that
`{c, c1, c2}` forms a valid group — either a set or a run.

**Sets**: same value, any two of the other seven same-value cards (across both decks).
For a card with 7 same-value companions, that's C(7,2) = 21 pairs.

**Runs**: alternating-color triples that include `c`. Cards at positions c−2, c−1, c+1, c+2
(within value bounds), subject to the red/black alternation constraint. The triple can
place `c` at any of the three slots. Rough count: maybe 8–12 valid run pairs per card,
fewer near the value boundaries.

Total neighbor pairs per card: somewhere in the 20–30 range. A flat list — tiny and
cache-friendly.

---

## What the liveness check looks like

Current `_singleton_is_live(c, pool)`: iterates all unordered pairs from `pool`, tries
6 orderings for each — O(|pool|²).

With the accelerator:

```python
def _singleton_is_live_fast(c, card_loc):
    for c1, c2 in NEIGHBORS[c]:
        loc1 = card_loc[card_id(c1)]
        loc2 = card_loc[card_id(c2)]
        if loc1 in ACCESSIBLE and loc2 in ACCESSIBLE:
            return True
    return False
```

O(k) where k ≈ 25. No classification call, no triple construction, no list iteration.
For a pool of 40 accessible cards, the speedup is roughly 40² / 25 ≈ 64×.

`ACCESSIBLE = {HELPER, TROUBLE, GROWING}` — the three non-sealed buckets.

---

## The sync question: derived vs. carried

Two options:

**Derive on demand**: `build_card_loc(buckets)` whenever the liveness check fires.
No persistent state, no sync bugs. Cost: O(50) to build, then O(k) to query.
For the dynamic doomed-singleton check (which only fires when `b.complete` is
non-empty), this is probably sufficient.

**Carry as part of BFS state**: each `FocusedState` holds a `card_loc` array alongside
`buckets` and `lineage`. Each BFS step copies and patches only the moved cards
(O(moved cards) ≈ O(3–5) per step). The copy itself is O(104) — cheap enough that
it likely pays off if the accelerator is used frequently within a step.

For now, "derive on demand" is the right starting point. The carried version becomes
attractive only if profiling shows repeated rebuilding is the bottleneck.

---

## What group membership the accelerator skips

The accelerator doesn't encode which cards share a stack. It just answers "which bucket
is this card in?" That's sufficient for liveness: liveness only needs to know whether a
card is accessible (any of helper/trouble/growing) or sealed (complete/absent).

The existing `state_sig` + dedup machinery already handles group identity through the
`Buckets` stacks. The accelerator doesn't need to replicate that — it's a read-only
query layer, not a state-transition layer.

The one place group membership matters for liveness that this misses: a card in a
**growing** partial can only be "separated out" via specific BFS moves. The accelerator
conservatively treats growing cards as accessible, which may keep some doomed singletons
alive in the liveness check when they shouldn't be. Whether that causes false negatives
(failed pruning) in practice is an empirical question.

---

## What else the accelerator might enable

- **Fast "is c already complete?"**: one array read instead of iterating `b.complete`.
- **Targeted doom propagation**: when a group completes, iterate the newly sealed cards'
  `NEIGHBORS` to find which trouble singletons lost their last valid partner — instead of
  rechecking all trouble singletons from scratch.
- **Speculative liveness during enumeration**: before generating a move, quickly check
  whether it would doom any singleton — prune before even constructing the new state.

The targeted doom propagation is potentially the most valuable: instead of O(|trouble| × k)
after each group completes, only recalculate for singletons whose neighbor sets overlap the
newly sealed cards. In practice that's 0–2 singletons per completion event.

---

## Open questions

1. **Run partner encoding**: Lyn Rummy runs can grow beyond 3. Does `NEIGHBORS[c]` need
   to encode "c1 and c2 adjacent to c" only, or also non-adjacent pairs like (c−2, c+1)?
   For liveness (3-card group), only minimal triples matter — pairs that bracket or flank c.

2. **Two-deck identity**: cards are `(value, suit, deck)` tuples. The neighbor table must
   treat deck-0 and deck-1 copies as distinct cards with overlapping group memberships —
   both copies of 3H are valid run members but count separately. The table handles this
   naturally since each of the 104 slots is a distinct card.
