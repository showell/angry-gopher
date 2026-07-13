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
   cards at a rank may form at most one set (one deck) before the rest
   start fresh chains. In the next-map a set is a chain of same-rank
   links, printed with `=`: `KH=KC=KS`.

Next: two decks — per-rank multiplicity 4 → 8, and the set
distinct-card constraint turns load-bearing.

Cross-cutting strategy: completely solve the ONE-deck game with a strong
test foundation before leaning on duplicate cards — the two copies of a
(rank, suit) are where the game's true complexity lives.

Files:

- `card.zig` — the vocabulary: (rank, suit, deck), the ASCII notation
  (`7H`, `TC'`), board-line parsing, and the deck-blind `Counts` view
  the solver runs on.
- `graph.zig` — the comptime one-deck successor tables (pure: 1 per
  card; rb: 2 per card; the two flavors are disjoint).
- `pure_run.zig` — phase 1: per-suit cyclic arc cover + verifier. Kept
  as a stepping stone.
- `solver.zig` — phases 2+3: the rank-sweep solver (with the component
  prefilter), its independent strict verifier, and the solution
  formatter (`3H>4S>5H | 9C>TC>JC | KH=KC=KS`).

Gate: `ops/check_solver` (composed into `ops/check` and
`ops/check_lynrummy`). Tests are zig-native; fixtures are board lines in
the human notation, e.g. `"4D 5D 5D' 6D 6D' 7D"`.
