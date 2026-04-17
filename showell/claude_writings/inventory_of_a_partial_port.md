# Inventory of a Partial Port

*Written 2026-04-17. First step of finishing the LynRummy TS → Elm port (in progress since 2026-04-13). Identifies what's already done so the remainder is cleanly scoped, then proposes today's UI-layer scope.*

**← Prev:** [The Elm Study Rip](the_elm_study_rip.md)

---

Before touching any code today, one question has to be
answered: **what's already ported?** A partial port is not a
fresh port. The first move isn't "read the source, enumerate
impedance mismatches" — it's "inventory the target, subtract
from the source, and scope whatever's left." The remainder is
what gets ported today.

What follows is that inventory — TS canonical source surveyed,
Elm target enumerated, gaps identified by role. Followed by a
scope proposal for today's playable-UI-in-Elm goal, and a
short methodology note about whether "inventory-first"
deserves a spot in the porting cheat sheet for future partial
ports.

## The TS canonical source at a glance

`~/showell_repos/angry-cat/src/lyn_rummy/` has **94 `.ts`
files** across 7 subdirectories. Modules only (excluding
`_test.ts`), by directory:

| Dir | Modules | Role |
|---|---|---|
| `core/` | 6 | Data + rules foundation (Card, CardStack, StackType, BoardPhysics, Score, TestDeck) |
| `game/` | 14 | UI layer + game-state (plugin, drag_drop, game, referee, place_stack, player_turn, etc.) |
| `tricks/` | 12 | Hints / AI implementations (bag + 9 tricks + helpers + serialize + stats) |
| `strategy/` | 12 | Solver + board analysis (orphan, reduce, viability, threesomes, etc.) |
| `hints/` | 3 | High-level hint orchestration (edge_info, raid, reassemble_graph) |
| `tools/` | 11 | CLI tooling (auto_player, hunt_puzzle, benchmarks) |
| `puzzles/` | — | JSON fixtures (smoke puzzles + stuck-board snapshots) |

Not all 94 files are UI-critical. The game loop lives
primarily in `game/`; `core/` is the data-layer foundation;
`tricks/` supports hint display and AI; `strategy/`, `hints/`,
and `tools/` are advanced features (solver, puzzle-hunting,
CLI automation) that don't gate a playable UI.

## What's already ported — the Elm index

`games/lynrummy/elm-port-docs/src/LynRummy/` has **15 Elm
modules**. They cover the full data layer and most of the
trick library.

| Elm module | TS source | Notes |
|---|---|---|
| `Card.elm` | `core/card.ts` | Full. Two equality concepts (`==` and `isPairOfDups`). |
| `CardStack.elm` | `core/card_stack.ts` | Full. `stacksEqual` is deck-aware (test fixed today; 207/207 green). |
| `StackType.elm` | `core/stack_type.ts` | Full. Derived-on-demand rather than stored. |
| `BoardGeometry.elm` | `game/board_geometry.ts` (141 LOC) | Full. Geometry helpers. |
| `Referee.elm` | `game/referee.ts` (327 LOC) | Full. The canonical rule enforcer. |
| `Random.elm` | Excerpt from `core/card.ts` (`seeded_rand`) | Full. Cross-language seed-42 trace equivalence. |
| `Tricks/Trick.elm` | `tricks/trick.ts` | Full. Trick + Play types. |
| `Tricks/Helpers.elm` | `tricks/helpers.ts` | Full. |
| `Tricks/DirectPlay.elm` | `tricks/direct_play.ts` | Full. |
| `Tricks/HandStacks.elm` | `tricks/hand_stacks.ts` | Full. |
| `Tricks/LooseCardPlay.elm` | `tricks/loose_card_play.ts` | Full. |
| `Tricks/PairPeel.elm` | `tricks/pair_peel.ts` | Full. |
| `Tricks/PeelForRun.elm` | `tricks/peel_for_run.ts` | Full. |
| `Tricks/RbSwap.elm` | `tricks/rb_swap.ts` | Full. |
| `Tricks/SplitForSet.elm` | `tricks/split_for_set.ts` | Full. |

Plus **8 test files** at `tests/LynRummy/*Test.elm` totalling
207 tests, all green as of this afternoon. Seven are per-module
unit tests (Card, CardStack, StackType, BoardGeometry, Referee,
Random, Wire); one is cross-language conformance
(`DslConformanceTest.elm`) that consumes fixtures generated
from the shared `../conformance/` JSON.

**Confidence: very high.** The Elm port has byte-identical
fixture matches with the Go twin for every trick scenario.
Deck-aware equality now correctly mirrors TS. The port has
survived 2k+ LOC with exactly one bug caught today — a test
that had drifted from TS semantics, which we fixed rather than
silenced. This is the foundation the UI will sit on.

## What's NOT ported

Everything else. Grouped by what the UI port actually needs.

### Needed for MVP UI (estimate)

From `game/` — the modules that drive interaction, placement,
and the wire to Gopher:

| TS file | LOC | Role |
|---|---|---|
| `game/plugin.ts` | 298 | Plugin entry point (wires game into Angry Cat's shell) |
| `game/game.ts` | **3,046** | Top-level game state, event handlers, most of the UX logic |
| `game/drag_drop.ts` | 259 | Core drag + drop interaction |
| `game/board_actions.ts` | 119 | Action dispatch (what happens when a user places a stack) |
| `game/place_stack.ts` | 138 | Placement validation + commit |
| `game/player_turn.ts` | 87 | Turn orchestration |
| `game/wire_validation.ts` | 35 | Light wire-format check |
| `game/protocol_validation.ts` | 166 | Protocol correctness at the Gopher boundary |
| `game/gopher_game_helper.ts` | 250 | Gopher integration (auth, fetch, post) |

From `core/` — two small helpers `game.ts` leans on:

| TS file | LOC | Role |
|---|---|---|
| `core/board_physics.ts` | 70 | Legal-move helpers (`can_extract`, etc.). Called by drag_drop. |
| `core/score.ts` | 51 | Scoring display. |

**Approximate total: ~4,500 LOC of TS to port**, including
`game.ts`. The 3,046-line `game.ts` is the bulk; everything
else combined is ~1,500 lines. Scope depends heavily on what's
inside `game.ts` — a survey pass before any port is required.

### Deferred for a playable MVP

| TS file / dir | Why defer |
|---|---|
| `game/geometry_replay.ts` (70), `game/semantic_replay.ts` (69) | Replay viewer is already server-side at `views/games_replay.go` (657 LOC); that stays as-is. |
| `game/puzzle_layout.ts` (90) | Puzzle-authoring path; not core to live play. |
| `tricks/bag.ts`, `tricks/serialize.ts`, `tricks/stats.ts` | Hint-display infrastructure + stats logging; not blocking MVP. Port when we wire hint-display. |
| `core/test_deck.ts` (33) | Frozen shuffled deck for test determinism. Port only if Elm tests need it. |
| `hints/edge_info.ts`, `hints/raid.ts`, `hints/reassemble_graph.ts` | High-level hint orchestration — "recommended plays" display. Post-MVP. |
| `strategy/` (12 modules) | The solver: orphan detection, viability, threesomes, chain_length, etc. Powers auto-player and hint quality. Post-MVP. |
| `tools/` (11 modules) | CLI: auto_player, hunt_puzzle, benchmarks. Porting later, if at all — these run against TS today. |

That's ~60% of the file count being deferred. Expected: the
data layer and tricks (done) plus the UI layer (today) plus
the wire-format shims (today) is the playable-game subset.
Strategy / hints / tools are for a running AI, a puzzle bench,
a replay viewer — all of which either live elsewhere or don't
block the player sitting down at a table.

## Scope proposal for today

Default target:

- **In scope:** the 9 `game/` modules listed above plus
  `core/board_physics.ts` and `core/score.ts`. ~4,500 TS LOC →
  expected ~3,500 Elm LOC (typical compression ratio from the
  earlier model port).
- **Out of scope:** everything in the "defer" table above.
- **Known hard part:** `game.ts` at 3,046 lines. Survey will
  likely reveal it as several sub-concerns that want to become
  separate Elm modules (event handlers + drag state + render +
  dispatch). Estimate the decomposition during survey, don't
  commit yet.
- **Knobs proposal:** `durability=10, urgency=1, fidelity=7`.
  Fidelity below 10 because Elm's UI paradigm (Model + Msg +
  update + view) forces structural divergence from TS's
  class-and-closure shape. Model-layer fidelity was 10; UI-layer
  fidelity can't be.

**Open per-component question before we start:** is `game.ts`
idiomatic-TS or expedient-TS? The cheat sheet's "Is the source
idiomatic, or just expedient?" step says: if expedient and
still live, consider refactoring source first. A 3k-line file
is a strong signal of accumulated expedience. The survey pass
will expose whether there are clean seams or whether
everything's entangled.

## Meta-note: inventory-first as a sub-process

The porting cheat sheet's "Before you touch the code" and
"Survey phase" sections implicitly assume a fresh port. A
partial port has a preceding step we don't have documented:

**Step 0: Inventory the target.** For a port that's already
underway, enumerate what's already ported. For each
already-ported module: confirm the TS source path, confirm the
port's confidence level (tests? fixtures? cross-language
parity?), decide whether it's "trust" or "re-verify." The
output is an index like the table above.

This step answers the first practical question — *what's the
remainder?* — and its absence would produce a mess: redundant
ports of already-ported modules, gaps in understanding what
the durable layer covers, or worst case, mistakenly ripping
durable work (which nearly happened an hour ago when you asked
me to rip the study layer — the Layer 1 / Layer 2 clarifying
question was effectively a one-off version of this inventory
step).

The step is cheap. For LynRummy, it's a `find` of both trees,
a `wc -l` on the TS side, and a table pairing sources to
ports. Less than an hour of work for a 94-file source and a
15-file target. The cost scales with the target's size, not
the source's — which is a nice property because the target is
usually smaller than the source when the port is partial.

Worth an edit to the cheat sheet as a short "Partial ports
start with inventory" section — since partial is the common
case (most real ports stop and resume; they pick up abandoned
work). Fresh ports are the minority. I'll propose the cheat
sheet edit as a follow-up after today's survey pass, once we
have a second data point on whether the inventory step
generalizes beyond LynRummy.

A small code-style snippet makes the inventory-first posture
concrete. Instead of opening a session with:

```
# naive first step (fresh-port assumption)
read TS source
enumerate impedance mismatches
start writing Elm
```

a partial port opens with:

```
# inventory-first
for each source module:
    does a target module exist?
    if yes: confirm tests pass, record confidence, done
    if no:  record role, LOC, dependencies
produce remainder list
only then: scope + knobs + survey, on the remainder
```

The substantive content of the two openings is the same
(knobs, scope, survey); the difference is what the "source" in
those later steps refers to. The inventory step is what shrinks
"source" to mean "the unported remainder."

## What's next

With the inventory in hand, the concrete next move is the
survey pass on the 9 `game/` modules + 2 `core/` helpers. Read
tests before code; state-flow audit on `game.ts`; enumerate
the TS→Elm UI-layer impedance mismatches (Model/Msg/update/view
vs class-with-mutation); check whether `game.ts` is cleanly
decomposable or needs a pre-port refactor on the TS side.

Parked here pending your go-signal on the scope.

— C.
