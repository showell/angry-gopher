# LynRummy — Python subsystem

**Status:** Legacy / utility. Tests still pass; the agent's
strategic brain has migrated to TypeScript at `../ts/`. New
solver work goes there.
**As of:** 2026-05-04.

This subtree was the original LynRummy agent — a complete
player without a presentation layer plus the experimentation
surface for solver work. As of the TS migration, the
canonical agent is at `../ts/` (see `../ts/README.md`).
Python remains for:

- **The dealer** (`dealer.py`) — used by tooling that needs
  to construct an initial state.
- **Puzzle catalog** (`puzzle_catalog.py`) — reads
  `../conformance/mined_seeds.json`, writes the JSON the
  Elm Puzzles gallery loads.
- **Tests** (`test_*.py`) — the Python solver is still
  exercised by `check.sh`. They serve as a parallel
  implementation sanity check; not actively extended.
- **Studies / one-offs** (`puzzle_from_snapshot.py`,
  `runaway_puzzles.py`, `analyze_trick_coverage.py`) —
  ad-hoc tools that haven't been retired.

## Running tests

```
bash check.sh
```

Every `test_*.py` runs. As of 2026-05-04: 11/11 test files
pass.

## Don't extend the solver here

Solver-touching work belongs in `../ts/`. The Python solver
modules (`bfs.py`, `enumerator.py`, `classified_card_stack.py`,
`move.py`, `buckets.py`, `verbs.py`, `geometry_plan.py`,
`agent_prelude.py`, `agent_game.py`) still build and pass
their tests, but they're a frozen parallel implementation —
fixing a bug here without porting to `../ts/` introduces
drift. If you find a Python-side bug worth fixing, fix the
TS sibling first; backport only if the test value is real.

## Pointers

- [`../ts/README.md`](../ts/README.md) — the canonical
  agent.
- [`../ARCHITECTURE.md`](../ARCHITECTURE.md) — system-wide
  context.
- [`SOLVER.md`](SOLVER.md) — design principles for the
  solver. Still valid as design background, but the active
  implementation is in TS now.
