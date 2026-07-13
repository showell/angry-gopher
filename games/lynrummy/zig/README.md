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
2. **+ red-black runs** — the real quantum jump: suits couple through
   color alternation, and the precomputed card graph earns its entry.
3. **+ sets** — the full game.

Cross-cutting strategy: completely solve the ONE-deck game with a strong
test foundation before leaning on duplicate cards — the two copies of a
(rank, suit) are where the game's true complexity lives.

Files:

- `card.zig` — the vocabulary: (rank, suit, deck), the ASCII notation
  (`7H`, `TC'`), board-line parsing, and the deck-blind `Counts` view
  the solver runs on.
- `pure_run.zig` — phase 1: per-suit cyclic arc cover + verifier.

Gate: `ops/check_solver` (composed into `ops/check` and
`ops/check_lynrummy`). Tests are zig-native; fixtures are board lines in
the human notation, e.g. `"4D 5D 5D' 6D 6D' 7D"`.
