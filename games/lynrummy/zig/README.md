# Lyn Rummy: the Zig solver

This solver runs both Hint buttons, the futility certificates and the Player
Two opponent, compiled to `solver.wasm`; the TS engine does the DSL and
geometry around it. It is parked.

**The framing.** The 104-card double deck has a static graph: runs are
successor edges, sets are same-value neighbours. A clean board is a
partition of its cards into single-flavour paths of length 3 or more.
Solvability depends only on the card **multiset**; turning a solution into
human moves is a separate layer.

## The search

The solver is four layers, each built on the last:

1. **Pure runs** (`pure_run.zig`). Suits decompose, and each suit is a small
   cyclic cover problem.
2. **Red-black runs** (`solver.zig`). Every run edge steps rank+1, so the 13
   ranks are a topological order and the solver is a **rank sweep**: one
   pass A→K with a bounded frontier of open chains, futile states memoized,
   and the K→A wrap handled by cutting at the scarcest rank and enumerating
   the small crossing matchings. Any legal run splits into consecutive runs
   of length 3 to 5, so the sweep builds only short chains and loses
   nothing.
3. **Sets** (`solver.zig`). Sets are local to a rank, so they fit the sweep's
   per-rank step: the leftover cards at a rank may form sets before the rest
   start fresh chains. A set prints with `=`: `KH=KC=KS`.
4. **Two decks** (`solver.zig`, `suit_first.zig`). The two copies of a card
   are interchangeable to legality, so the search runs on (suit, count):
   copy 0 is used before copy 1, and memo states carry counts alone. The
   board is a canonical u128 multiset bitset. The distinct-suit rule of sets
   matters here (`7H 7C 7H'` is three cards at one rank, and no set). A
   copy-blind oracle that treats all 104 slots as distinct agrees with it.

**The counting lemma** sits on the sweep. Every rank-r card in a run lies in
one of three single-flavour windows of three: TAIL (r−2, r−1, r), MID
(r−1, r, r+1) or HEAD (r, r+1, r+2). Distinct r-cards claim disjoint
windows, so an exact packing of the legal windows caps how many r-cards
runs can hold, and the rest are **forced into sets**. Every conclusion is
sound, since legality only removes options and packing only over-counts.
That gives three monotone checks before any search: excess past a rank's
set capacity is futility with zero search; forced ranks skip the sweep's
no-set branch; excess past one set's reach prunes single-set carvings.

**The solve is a portfolio**, cheapest first:

0. **Suit-first** (`suit_first.zig`), the human prior: pure runs carry the
   bulk and sets patch the orphans. It answers most boards in microseconds
   with a human-shaped cover. Per suit it runs an exact small DP (fewest
   orphans, then fewest arcs), because a naive split by level loses to the
   staircase (`3 4 4' 5 5' 6` is two overlapping runs). When it passes, the
   sweep takes over.
1. **The rank sweep**, cut at the scarcest rank, under a small step budget.
2. On a budget trip, **the sweep from the fewest-matchings cut**, under the
   give-up line (`GIVE_UP_STEPS` in `solver.zig`).

## The board bridge

The bridge solves the player's actual board, beyond the bare multiset. An
arrangement is a list of stacks in the solver's own notation: glued tokens
are stacks (`3H>4S>5H`, `KH=KC=KS`), space-separated cards are singletons,
and `|` is cosmetic. So a plain board line is the all-singletons
arrangement, and a formatted cover round-trips. Stacks must be valid melds,
relaxed only in length (a 2-stack is one card short); anything else fails
loudly.

`solveArrangement` judges the multiset as `solve` does; the player's board
changes only the order of the search, so the cover converges toward the
player. **Kept edges** measure nearness: `reportKept`
counts the player's links that survive and grades each input stack intact,
partial or shattered. The sweep tries warm choices first, those that extend
or keep the player's edges, so a cold board searches in the plain order.
Reordering moves where the budget trips, so a warm `unknown` gets one cold
retry, and the verdict is always at least as good as `solve`'s. A near-solution
arrangement is also a search heuristic: on the acceptance fixture, the warm
sweep keeps twice the edges in a tiny fraction of the steps.

**Local repair** (`repair.zig`) runs ahead of the sweep, in the player's own
geometry: bounded single-card edits of the arrangement (attach, wedge,
bring with mid-run pulls, seat swap), scored by true kept edges. Together
they are `solveArrangement`, **one pipeline for every surface**: repair
answers the common case, and the sweep is the oracle behind it for
satisfaction, futility proofs and certificates. Repair answers "solved"
alone; futility is the sweep's.

**Human moves** (`moves.zig`): the edge diff becomes five verbs (peel,
steal, push, split, merge), with intact stacks silent. In a full cover every
card ends melded, so each broken edge pairs with that card's destination
edge, and the pair is the verb ("peel X from [S] onto [T]"). First the
cover's copy labels are re-dressed to match the player's physical stacks.
The distiller builds the plan by **simulating it**, and the final board must
equal the cover exactly or it fails loudly, so the move list builds what it
says. It is a build recipe; the TS layer makes the gestures.

**The answer is an Outcome:** `solved` (a verified cover), `futile` (a proof,
from a completed search or a prefilter) or `unknown` (the give-up line
tripped). Steps are the deterministic unit of work, and `steps_used` is
public difficulty telemetry. The give-up line rises only on evidence of a
real board solvable above it. `corpus_quick.txt` (ground-truth boards, held
by the gate) and `corpus_hard.txt` (boards near and past the line) carry the
data.

## The code

`card.zig` is the vocabulary and `solver.zig` the core; read the code, each
file opens with what it does. Beyond the search:

- `hint.zig`, the game hint, **beginner-first**: it tries hand subsets in
  ascending size under strict probe budgets, plays the smallest that works
  and leads the plan with a `place` line, the sixth verb. When every
  subset fails, it offers a consolidation plan, a draw, "undo territory" or a
  give-up.
- `wasm.zig`, the browser build (`ops/build_lynrummy_wasm`): an arrangement
  line in, a move plan out, as the `puzzleHint`, `gameHint` and `agentStep`
  exports, reached through `zig-server/src/puzzles.zig` and
  `engine_glue.js`. `agentStep` runs `sim.agentPlan`, the strong policy;
  `ts/elm_api/zig_agent.ts` lifts its answer into geometry.
- `sim.zig`, full-game self-play on the `ts/full_game/` rules, dealing
  exactly as `ts/baseline_deal.ts` does, so a seed names the same game in
  both. Its agent plays strong: a greedy subset cascade with satisfaction
  probes. `ops/bench_lynrummy_sim` is the bake-off against the TS harness.
- `cut_dump.zig` writes a game's cut state (the board at the first solver
  give-up) for `ops/publish_lynrummy_cut`.
- `puzzle_mine.zig` and `seed_sweep.zig` mine puzzles
  (`ops/mine_lynrummy_puzzle`). A person adds a mined board to
  `../conformance/curated_sim_puzzles.dsl`, then bumps the count pin in
  `../puzzle_gate.zig`.
- `calib.zig` grades a human's line against the solver's, from the wire
  lines of `../ts/tools/replay_puzzle.ts`.

**The gate** is `ops/check_solver`, in `ops/check` and `ops/check_lynrummy`.
The tests are Zig-native; fixtures are board lines in the human notation,
such as `"4D 5D 5D' 6D 6D' 7D"`.

Where parked work would pick up is in [RESUME.md](RESUME.md).
