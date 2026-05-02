# TS port status — what's ported, what's deferred

Crosswalk between this TypeScript BFS engine and its Python reference
implementation at `games/lynrummy/python/`. Use this when reading the
TS code to know which divergences are deliberate (deferred features)
vs accidental (port drift to fix).

**Status 2026-05-02:** Python BFS slated for retirement. TS is becoming
the canonical engine; conformance fixtures pin the moment of handoff.

Behavioral parity is verified by 214/214 leaf conformance scenarios +
160/160 engine + hand-play cross-check (148 solve / 9 enumerate_moves
/ 3 hint_for_hand) PLUS 25 seeds × ~9 find_play calls (214 calls
total) of real-game cross-validation via `agent_game_xcheck.py`. Only
`find_open_loc` remains explicitly out of TS scope (UI placement
geometry, tested in Python + Elm).

## Cross-validation harness — `python/agent_game_xcheck.py`

Drives offline self-play through Python orchestration; calls
`agent_prelude.find_play` AND `ts_solver.find_play_steps` on every
turn; asserts step-list equivalence. Captures every call to JSONL
(`captures/*.jsonl`, gitignored — reproducible by re-running xcheck).

Surfaced one port-fidelity bug the conformance corpus didn't catch:
TS `rules/stack_type.ts:successor()` was missing the K→A wraparound,
so `isPartialOk([KH, AC:1])` returned false and TS skipped K-A-2
triple-in-hand plays Python found. Fixed in commit `651318f`. Lesson:
curated fixtures have coverage gaps; real-workload cross-validation
is what closes them. (See `memory/feedback_corpus_blind_spots.md`.)

## Bridge — TS engine callable from Python and Elm

`ts/bridge.ts` is the single CLI entry point: reads one JSON request
from stdin, dispatches to `findPlay` or `solveStateWithDescs`, writes
JSON to stdout. Python wrapper at `python/ts_solver.py` (subprocess
per call). Same wire format will eventually serve Elm via ports
(snake_case JSON throughout).

Worst-case engine wall (across 25 real games / 214 calls):

  Python BFS: 17.2s (seed 20 turn 7)
  TS engine:  8.1s (same input, ~2× faster)

Both well above the 200ms human-perceptible threshold on the slowest
inputs — that's a SOLVER_SPEED problem (not port-fidelity). TS is
consistently ~2× faster than Python on the worst 10 inputs across
the captured corpus.

## File map

| TS file | Ported from | Deferred features |
|---|---|---|
| `src/buckets.ts` | `python/buckets.py` | none |
| `src/classified_card_stack.ts` | `python/classified_card_stack.py` | splice executors (kept inline in `enumerator.ts` for v1; see below) |
| `src/enumerator.ts` | `python/enumerator.py` | none on the enumeration / focus / lineage paths |
| `src/bfs.ts` | `python/bfs.py` | card-tracker liveness pruning (see below) |
| `src/move.ts` | `python/move.py` | none |
| `src/hand_play.ts` | `python/agent_prelude.py` | none on the find_play / format_hint paths |
| `src/rules/card.ts` | `python/rules/card.py` | none |
| `src/rules/stack_type.ts` | `python/rules/stack_type.py` | only `isPartialOk` is ported (full module also has `classify`, `neighbors`, etc.; those live in `classified_card_stack.ts` in TS) |

## Deferred features

### Card-tracker liveness pruning (priority: before browser integration)

Python has two filters not yet ported:

- **`_all_trouble_singletons_live(b)`** — called once before the BFS
  loop in `solve_state_with_descs` (`bfs.py:323`). Short-circuits
  initial states with a provably-dead trouble singleton (no valid
  3-card group reachable using accessible cards).
- **`_any_trouble_singleton_newly_doomed(b)`** — called inside the
  BFS loop on states that just graduated a group
  (`bfs.py:160-162`). Prunes children where the completion sealed
  the singleton's last partner into COMPLETE.

Both are backed by the card-tracker accelerator: `card_loc` array
plus precomputed neighbor tables in `card_neighbors.py` (~180 LOC).

**Why deferred:** v1 conformance corpus is solvable boards; the
runaway-class boards aren't tested. TS BFS will work but bloat
`seen` and hit `maxStates` cap on hard puzzles Python solves
cheaply.

**When to port:** before the TS engine replaces the Elm BFS in the
browser. Bench against `python/corpus/` first to size the gap.

### Splice executors hoisted out of `enumerator.ts` (priority: opportunistic)

The probes (`right_splice_candidates`, `left_splice_candidates`)
landed in `classified_card_stack.ts` per the leaf module's domain.
The executors (`splice_left`, `splice_right`) currently live inline
in `enumerator.ts` because the v1 port task explicitly avoided
touching the leaf module.

**When to fix:** next time someone touches either file. Move the
executors next to the probes, drop the inline definitions in
`enumerator.ts`. No behavior change.

## Open design surfaces

These aren't deferred features — they're decisions that haven't been
made yet because they'll first matter at browser integration:

### Cross-language wire format for descriptors

The TS `Desc` discriminated union uses camelCase fields
(`extCard`, `targetBefore`, `pCard`). Python uses snake_case
(`ext_card`, `target_before`, `p_card`). Elm has its own. When the
TS engine eventually feeds the Elm UI via ports, three different
shapes will need to agree. **Pin the wire format before
integration.** Working assumption: snake_case JSON across the wire,
TS layer converts at one boundary.

This is tracked as `CROSS_LANG_WIRE_FORMAT` in `MINI_PROJECTS.md`.

### `isAlreadyClassified` shape-sniff vs typed boundary

`bfs.ts:179-191` inspects the first non-empty bucket's first stack
to decide whether to classify. Cleaner: take only `RawBuckets` at
the public entry point and classify always (idempotent at caller).
Worth pinning before browser integration since serialization
quirks could hit this surface silently.

## Naming convention

snake_case is fine in this TS port — see
`memory/feedback_snake_case_in_elm.md`. The port stays close to its
Python source, and that's the point. Don't flag snake_case as a
critique target.
