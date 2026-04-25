# LynRummy — Python agent subsystem

**Status:** `STILL_EVOLVING`. The planner half is in active
flux (pull/push DSL + IDDFS); the trick-engine half is being
phased out.

This subtree is the Python LynRummy agent — a complete player
without a presentation layer. It chooses legal moves with its
own planning logic, validates them against its own referee
equivalent, keeps its own action log, and posts events to the
server for later witness.

## Before reading the Python code

Start with [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — the
system-wide Lyn Rummy architecture document. The sections on
**each actor owns its own view**, **constraints must be real
not artificial**, **two coordinate frames** (board frame vs.
viewport), and **agents plan then execute** are all directly
load-bearing for why this subtree is shaped the way it is.

## Two strategic layers, one fading

The Python agent has two pieces of strategy code:

- **`beginner.py` — the planner**, current strategic brain.
  Trouble-driven search using PULL verbs (peel / pluck / yank
  / steal) and PUSH verbs (onto-set, onto-run-end). IDDFS
  returns shortest plans within a budget of trouble cards.
  Trouble-as-actor DSL: `5C 6C peel-pulls [4C] 5C 6C {-4C- 4D
  4S 4H}`. See `beginner.claude`.

- **`strategy.py` — the trick engine**, legacy. Per-trick
  emitters (`direct_play`, `pair_peel`, `split_for_set`, …)
  that produce primitive sequences for high-confidence
  patterns. Still wired into `auto_player.py` for now;
  abandonment plan is in flight (affects Elm too — its
  `Game.Strategy.*` modules and the conformance hint
  scenarios).

When both engines stall on the same board, that's the
"Steve-level puzzle" sweet spot the hunt drivers harvest.

## The Python agent's stance — plan, then execute

The agent mimics a human's small-scale spatial planning.
Before emitting a primitive sequence, it simulates the
final board and every intermediate state, and pre-plans
geometry corrections upstream — not after.
`strategy.py`'s `_plan_merge_hand` is the canonical
implementation of this discipline (still load-bearing for
trick output as long as `strategy.py` is alive).

Concrete examples of what this buys us:
- The replay shows a coherent sequence of human-plausible
  moves, not "ugly in the middle, fine at the end."
- Scope of planning stays shallow (2–3 logical board
  changes, up to 6–7 primitives) — well within what a
  human does in their head.
- `_fix_geometry` stays as a last-ditch safety net; it
  should rarely fire, and when it does it's a signal that
  the trick-specific emitter needs a plan upgrade.

## Then — read sidecars

Sidecar coverage is uneven right now. Most legacy modules
have a `.claude`; several recent additions (planner +
hunt drivers) don't yet. `tools/sidecar_audit` flags the
gap.

Ordered by "load-bearing first":

- `beginner.claude` — the planner. The current strategic
  brain. **Start here for any planner-side work.**
- `strategy.claude` — the trick engine. PLANNED-LEGACY but
  still wired. Per-trick emitters, primitive ordering
  discipline, plan-then-execute for `merge_hand`.
- `auto_player.claude` — the main loop: fetch state, pick a
  trick / planner suggestion, post primitives, repeat.
- `geometry.claude` — board-frame geometry primitives
  (find_open_loc, find_violation, pinned viewport
  constants).
- `gesture_synth.claude` — synthesizes intra-board
  floater-top-left paths where Python knows both endpoints.
- `client.claude` — thin HTTP wrapper around the Gopher
  endpoints.
- `board_lab_puzzles.py` — canonical puzzle catalog for
  BOARD_LAB. Single source of truth for the JSON Go serves.
- `agent_board_lab.py` — runs the strategy engine against
  every puzzle in the catalog; persists a session per
  puzzle (label `"agent: <title>"`).
- `study.py` — reads captured sessions for a named puzzle
  and prints divergence between human and agent attempts.
- `telemetry.claude` — read-side of the DB's gesture
  capture. Analysis, not gameplay.
- Repo-wide tooling at `../../../tools/sidecar_audit.{claude,py}`
  — drift + coverage check across all sidecars.

### Hunt drivers (no sidecars yet — TODO)

`complex_hunt.py`, `deep_hunt.py`, `one_card_hunt.py` —
drive `auto_player` on randomized deals until a stall, then
ask `beginner_plan` if it can rescue. Used to harvest
puzzles for the corpus.

### Corpus (no sidecar yet — TODO)

`beginner_corpus.py` — deterministic before/after harness
for `beginner.py` changes. Canonical 4/8 sweep + gap cases.
Pipe to file, `git diff` to compare runs.

### Legacy puzzle harness (queued for purge)

`puzzles.claude`, `puzzle_harness.claude`, `compare.claude`,
`dsl.claude` — pre-BOARD_LAB Python cluster. Confirmed
unreferenced from current BOARD_LAB modules during the
2026-04-24 audit. See MINI_PROJECTS / PURGE_LEGACY_PUZZLE_HARNESS.

## The DSL conformance bridge

Python + Elm both exercise the same hint / invariant /
build-suggestions scenarios, defined once in
`games/lynrummy/conformance/scenarios/*.dsl` and compiled by
`cmd/fixturegen` into Python JSON fixtures + Elm Elm-test
files. Central cross-language bridge per `BRIDGES.md`.
**Caveat:** the hint-scenarios half is coupled to the
trick engine and will change as that's phased out.

## TODO

- Sidecars for `beginner_corpus.py`, the three hunt
  drivers, `dealer.py`, `show_board.py`, `dsl_planner.py`,
  `dsl_player.py`, and the analysis scripts.
- Tag `strategy.claude` and friends PLANNED-LEGACY once the
  abandonment plan is concrete.
- Cross-link to the `BRIDGES.md` principle from the
  conformance-tooling entries.
