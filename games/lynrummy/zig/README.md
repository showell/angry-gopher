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
lemmas, in its color-tightened form. Every rank-r card in a run sits in
one of three flavor-monochromatic 3-windows — TAIL (r−2, r−1, r), MID
(r−1, r, r+1), HEAD (r, r+1, r+2); your 678/789/89T — and distinct
r-cards claim card-disjoint windows, so max-disjoint-legal-windows (an
exact ≤8-item packing, most-constrained-first B&B, count-only bound as
budget fallback) caps how many r-cards can live in runs. Cards beyond
the cap are FORCED into sets. Legality only removes options and packing
only over-counts a cover, so every conclusion is sound. Three pre-search
weapons, all monotone: excess beyond the rank's set capacity is futility
with ZERO search (king scarcity is the degenerate case — and the 59c
probe10 monster that once burned days of CPU falls here), forced ranks
skip the sweep's no-set branch, and excess past one set's reach prunes
single-set carvings. A/B: −21% steps on the quick corpus, −26% on the
hard corpus's decided rows, 35 of the quick corpus's futile boards
proven with zero search, no board slower. The puzzle-78 exemplar (7
tens vs 3 nines + 3 queens force a ten set) is where the lemma was
mined — probes in claude-steve/random765.md.

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

**The board bridge (v1)** lifts the solve off the bare multiset and
onto the player's actual board. An arrangement is a list of stacks in
the solver's own output notation — glued tokens are stacks
(`3H>4S>5H`, `KH=KC=KS`), space-separated cards are singletons, `|`
stays cosmetic — so a plain board line is the degenerate
all-singletons arrangement and a formatted cover round-trips. Stacks
must be valid melds relaxed only in length (a 2-stack is one card
short; `AH 7C` can only ever be two singletons); anything else fails
loud. `solveArrangement` answers with the SAME verdict `solve` would
give the multiset — the bias is ordering-only — but the cover
converges toward the player: tier 0 prefers repair sets that keep the
player's set pairs together (co-membership, chain order irrelevant)
and breaks full-cycle 13-runs at the coldest boundary. The EDGES
metric is the ratified nearness score: `reportKept` counts kept links
(run links by realized (suit, rank) adjacency with honest counts, set
links by co-membership, global consumption so two stacks can't claim
one output suit) and grades each input stack intact / partial /
shattered. The SWEEP is warm too: chain continuations grab suits that
extend a player edge before considering closing or cold suits, a rank
the player holds warm sets at tries the carvings that keep them before
the no-set branch, and the cut guesses warm crossings first — every
reorder keyed strictly on warmth, so a cold board explores in the
historic order exactly. rb stacks warm the sweep (Warm.runs carries
all run flavors; tier 0 still reads only the pure diagonal). One
honesty seam: ordering shifts where the step budget trips, so a warm
`unknown` gets one cold retry — the verdict is never worse than
solve's. The acceptance fixture is Steve's real 59-card give-up
consolidation: cold, its cover keeps 16 of his 42 edges after 442,848
steps; the warm sweep's first cover keeps 32 in ~439 steps, because a
near-solution arrangement is also a search heuristic.

On top of that first cover sits ANYTIME MIN-BREAK: solveArrangement's
sweep doesn't stop at its first cover — the completion leaf scores
the cover (kept player edges), records the best, and keeps
enumerating under a budget. Warm ordering makes early candidates
near; ties keep the first; all of a player's edges kept ends the
search; and since every cover is reachable from any one cut, an
enumeration that COMPLETES under budget has found the true max-kept
cover. Memoization stays sound via a found counter — a state with
covers below it is never marked futile. The budget (200k steps) is
tuned strict on the fixture's curve: 32 → 37 of 42 by 67k steps
(13 of 17 stacks intact), flat from there to a 20M probe. Verdicts
stay honest: an empty-handed budget trip falls back to the standard
portfolio, cold-retrying a warm unknown. Still open: breakability
weights, donor-choice warmth in tier 0's repair.

The edge diff then distills into HUMAN MOVES (`moves.zig`): five
verbs — peel, steal, push, split, merge — with intact stacks silent.
In a full cover every card ends up melded, so every break-edge pairs
with that card's destination edge, and the pair IS the compound verb
("peel X from [S] onto [T]"). Step 0 re-dresses the cover's copy
labels (first-come dressing) to hug the player's physical stacks —
otherwise the diff describes surgery on the wrong twin. The distiller
builds the plan by SIMULATING it, and the final board must equal the
cover exactly (runs by sequence, sets by membership) or it fails loud:
the move list cannot lie about what it builds. It is a faithful build
recipe, not gesture-level choreography. The 59c give-up fixture pins
the whole plan: 8 moves off the min-break cover — the engine's blind
A* needed 6 verbs from the same state, one a compound shift worth two
of ours.

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
  are disjoint); rank/suit lookups are copy-blind across the 104 slots;
  `edgeFlavor`, the legal-meld-edge truth.
- `arrangement.zig` — the board as stacks: parsing + loud validation,
  the `Warm` counts the solve biases on, and `reportKept`, the
  kept-edges scorer.
- `moves.zig` — the edge diff distilled into the five human verbs,
  verified by construction.
- `hint.zig` — the game-hint orchestrator, BEGINNER-FIRST (Steve's
  objective): scan hand subsets in ascending size (singles, pairs,
  triples) under strict probe budgets, play the smallest workable one
  (ties: most kept edges, then hand order), lead the plan with its
  `place` line — the sixth verb. Nothing playable falls back
  honestly: consolidation plan / draw / "undo territory" / give-up.
- `wasm.zig` — the browser build (ops/build_lynrummy_wasm →
  solver.wasm): arrangement line in, move plan out — puzzleHint and
  gameHint exports. Serves both Hint buttons via
  zig-server/src/puzzles.zig + engine_glue.js.
- `sim.zig` — full-game agent self-play on the ts/full_game/ rules,
  deal bit-exact with ts/baseline_deal.ts (a seed names the same game
  in both engines). The agent plays STRONG, not beginner-shaped:
  greedy subset cascade, satisfaction probes (`solveArrangementSat`),
  the winning probe's cover lands as the board. Bake-off driver:
  `ops/bench_lynrummy_sim` (~100-300ms/game ReleaseFast vs the TS
  harness's 1.8-11s on the same deals).
- `cut_dump.zig` — dumps a game's CUT STATE (the board at the first
  solver give-up) for `ops/publish_lynrummy_cut`, which publishes it
  as a playable session via ts/publish_cut_game.ts.
- `pure_run.zig` — phase 1: per-suit cyclic arc cover + verifier. Kept
  as a stepping stone.
- `solver.zig` — phases 2+3: the rank-sweep solver (with the component
  prefilter), its independent strict verifier, and the solution
  formatter (`3H>4S>5H | 9C>TC>JC | KH=KC=KS`).

Gate: `ops/check_solver` (composed into `ops/check` and
`ops/check_lynrummy`). Tests are zig-native; fixtures are board lines in
the human notation, e.g. `"4D 5D 5D' 6D 6D' 7D"`.
