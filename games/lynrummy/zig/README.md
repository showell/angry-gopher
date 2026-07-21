# Lyn Rummy — the zig solver (rethink in progress)

A fresh solver being built up in phases, replacing nothing yet — the TS
engine (`../ts/`) remains production. The framing: the 104-card double
deck has a static graph (runs = successor edges, sets = same-value
neighbors), and a clean board is a partition of the board's cards into
flavor-monochromatic paths of length 3+. Solvability depends only on the
card **multiset**; deriving human-facing moves from a solution is a
deliberately separate, later layer.

Phases:

1. **Pure runs only** (`pure_run.zig`) — DONE. Suits decompose; each suit
   is a tiny cyclic cover problem. Mostly here to drive out the
   administrative decisions (encoding, notation, FUTILE-as-an-answer,
   the test pattern).
2. **+ red-black runs** (`runs.zig`) — DONE. The quantum jump it was
   expected to be: a chain-growing DFS (grab-the-loneliest-neighbor)
   thrashed on dense random boards, and the fix was structural — every
   run edge steps rank+1, so the 13 ranks are a topological order and
   the solver is a **rank sweep**: one pass A→K with a bounded frontier
   of open chains, futile states memoized, and the K→A wrap handled by
   cutting at the scarcest rank and enumerating the small crossing
   matchings. Load-bearing lemma: any legal run splits into consecutive
   runs of length 3..5, so the sweep only ever builds short chains and
   loses nothing.
3. **+ sets** (`solver.zig`, evolved from phase 2's `runs.zig`) — DONE.
   Sets are rank-LOCAL (3–4 cards of one rank), so they slot into the
   sweep's per-rank step rather than changing its shape: the leftover
   cards at a rank may form sets before the rest start fresh chains. In
   the next-map a set is a chain of same-rank links, printed with `=`:
   `KH=KC=KS`.
4. **Two decks** (`solver.zig` + `suit_first.zig`) — DONE. The two
   copies of a (suit, rank) are indistinguishable to legality (a run
   can't repeat a value, a set can't repeat a suit), so the search stays
   at (suit, count) level: copy 0 is consumed before copy 1 (WLOG, never
   a choice point) and memo states carry no copy labels. The board is a
   canonical u128 multiset bitset; per-rank frontier grows to 8 open
   chains and up to two sets; the set distinct-SUIT constraint turns
   load-bearing (`7H 7C 7H'` is three cards at one rank and no set).
   Validated against a copy-blind oracle that treats all 104 slots as
   distinct cards — agreement on uniform-random AND meld-seeded boards.

Layered on the sweep: the **counting lemma**, the first of the scarcity
lemmas. A run containing rank r either has its r−1 directly before it
or starts at r and must run r, r+1, r+2 — so runs-containing-r ≤
#(r−1) + min(#(r+1), #(r+2)) (mirror bound too, ranks mod 13), and
cards beyond the bound are FORCED into sets. The bound ignores
suit/color legality, so it only over-counts run capacity and every
conclusion is sound. Costs 13 popcounts per solve, buys two things:
excess at a rank with < 3 distinct suits is futility with zero search
(king scarcity is the degenerate case), and the sweep skips the no-set
branch at forced ranks — a provably dead subtree, so the pruning is
monotone (A/B: −31.5% steps on the puzzle-78 exemplar where 7 tens vs
3 nines + 3 queens force a ten set; −8.5% across the quick corpus; no
board slower).

The solve is a **portfolio**, cheapest prior first:

0. **Suit-first** (`suit_first.zig`) — the human prior: pure runs as
   the bulk carrier, sets as patch material for orphans, no red-black
   at all. Answers most boards in microseconds with a human-shaped
   cover (it reproduced Steve's own solve of the probe's worst board,
   card for card; the full 104-card board comes back as eight parallel
   13-runs). At two decks the per-suit arc decomposition is an exact
   tiny DP — fewest orphan cards, then fewest arcs — because the naive
   level split loses to the staircase (`3 4 4' 5 5' 6` is two
   overlapping runs, no set); repair may build two sets per rank, and
   which copy a card is never enters the search. Allowed to pass —
   failure falls through to the sweep.
1. **Rank sweep, scarcest-rank cut**, under a 50k-step budget.
2. On a budget trip: **sweep from the fewest-matchings cut**, under the
   1M-step give-up line.

The answer is an **Outcome**: `solved` (verified next-map), `futile` (a
PROOF — completed search or component prefilter, never a guess), or
`unknown` (the give-up line tripped: no verdict, honestly labeled).
Steps are the deterministic work unit — every matching's sweep passes
through `step()`, and `steps_used` is public difficulty telemetry. The
1M line is tuned from a 20,400-board coverage sweep (99.77% answered,
no size below 98.5%, worst chase sub-second at the ~1.1M steps/s
memo-saturated grind rate); it scales UP only on evidence of a real
board solvable above it. `corpus_quick.txt` (149 ground-truth boards,
gate-enforced) and `corpus_hard.txt` (the over-the-line evidence pile:
answered-above-1M boards, unknown-at-50M boards, the named monsters)
carry the data.

Files:

- `card.zig` — the vocabulary: (rank, suit, deck), the ASCII notation
  (`7H`, `TC'`), board-line parsing, and the deck-blind `Counts` view
  the solver runs on.
- `graph.zig` — the comptime successor tables over the 52 distinct
  (suit, rank) cards (pure: 1 per card; rb: 2 per card; the two flavors
  are disjoint); rank/suit lookups are copy-blind across the 104 slots.
- `pure_run.zig` — phase 1: per-suit cyclic arc cover + verifier. Kept
  as a stepping stone.
- `solver.zig` — phases 2+3: the rank-sweep solver (with the component
  prefilter), its independent strict verifier, and the solution
  formatter (`3H>4S>5H | 9C>TC>JC | KH=KC=KS`).

Gate: `ops/check_solver` (composed into `ops/check` and
`ops/check_lynrummy`). Tests are zig-native; fixtures are board lines in
the human notation, e.g. `"4D 5D 5D' 6D 6D' 7D"`.
