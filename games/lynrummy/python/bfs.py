"""
bfs.py — BFS puzzle solver: finds the shortest sequence of
moves that clears all TROUBLE stacks in a Lyn Rummy board.

The Python equivalent of `Game.Agent.Bfs.elm`.

## What the solver does

A Lyn Rummy board is partitioned into four buckets:

  HELPER   — stacks already in valid groups (kept as-is)
  TROUBLE  — stacks that don't belong anywhere yet
  GROWING  — partial groups being assembled
  COMPLETE — finished legal groups (victory condition)

Victory means TROUBLE and GROWING are both empty.  The
solver finds the shortest sequence of agent moves (peels,
plucks, yanks, steals, splits) that achieves this.

The algorithm is BFS by program length: it expands every
program of length N before considering any program of
length N+1, so the first victory found is always a
shortest solution under the current trouble cap.

## The trouble cap

`trouble_count` measures how much "out-of-place material"
is currently active (TROUBLE + GROWING stacks combined).
A cap prunes states whose trouble exceeds a threshold,
keeping the frontier tractable on hard positions.

The outer iterative loop (`solve_state_with_descs`) tries
caps 1, 2, … up to `max_trouble_outer`.  Low caps fail
fast when the puzzle genuinely needs more trouble-headroom;
once the cap reaches the puzzle's true peak, the search
succeeds quickly because the optimal path was never pruned.

## Entry points

  solve(board)                   — flat board → plan lines
  solve_state(initial)           — Buckets → plan lines
  solve_state_with_descs(initial)— Buckets → [(line, desc)]

`solve_state_with_descs` is the canonical entry point for
callers that need primitive-verb translations (e.g. the
Elm UI bridge).  `solve` and `solve_state` are thin wrappers
that classify the board and strip descriptors.

`bfs_with_cap` is the inner workhorse; call it directly
only when you need fine-grained diagnostics or a fixed cap.

## When to use this solver vs. others

- **Puzzles / hint generation**: use `solve_state_with_descs`
  with the default caps.  The iterative-cap strategy handles
  most curated puzzle boards in well under 10 000 state
  expansions.
- **Full-game agent play**: same entry point; the board is
  already partitioned by game state.
- **Runaway detection**: if `hit_max_states=True` comes back
  from `bfs_with_cap`, the frontier exploded before finding a
  plan.  The caller should either widen `max_states`, raise
  `max_trouble_outer`, or conclude the position is unsolvable
  within budget.
- **Not suitable for**: multi-player coordination or
  lookahead across opponent turns — the solver assumes a
  single agent acting on a static board.
"""

from buckets import (
    Buckets, FocusedState,
    is_victory, state_sig, trouble_count,
)
from rules import classify
from enumerator import enumerate_focused, initial_lineage
from move import describe


def bfs_with_cap(initial, max_trouble, max_states, *,
                 diagnostics=None, verbose=False):
    """Pure BFS by program length. Bounded by max_trouble:
    states whose total trouble exceeds the cap never enter
    the frontier. At each level we expand EVERY program of
    that length, generating all level+1 programs, before
    looking at any longer programs. First victory found at
    level N returns the (shortest-under-cap) plan as a list
    of (line, desc) pairs.

    `initial` is a `FocusedState` (Buckets + lineage).
    The lineage's head is the focus — each step must grow
    or consume it.

    Returns (plan_or_None, hit_max_states, expansions,
    seen_count). `hit_max_states=True` means the cap was hit
    by exhausting the state budget — the runaway signal.

    `diagnostics`, if provided, is a mutable dict populated
    with trouble_histogram / level_widths / sample_states.
    `verbose` prints level transitions + victory message.
    """
    b = initial.buckets
    if trouble_count(b.trouble, b.growing) > max_trouble:
        return None, False, 0, 0
    if is_victory(b.trouble, b.growing):
        return [], False, 0, 1
    seen = {(state_sig(*b), initial.lineage)}
    current_level = [(initial, [])]
    expansions = 0
    level = 0
    if diagnostics is not None:
        diagnostics.setdefault("trouble_histogram", {})
        diagnostics.setdefault("level_widths", [1])
        diagnostics.setdefault("sample_states", [])
    while current_level:
        level += 1
        # Sort within the level by trouble count of the
        # current state — iteration order within BFS-by-length
        # doesn't affect which plans are reachable, but
        # lowest-trouble-first means victory-bearing states
        # get expanded earliest and we exit on first hit.
        current_level.sort(
            key=lambda e: trouble_count(e[0].buckets.trouble,
                                        e[0].buckets.growing))
        if verbose:
            print(f"\n--- level {level}: expanding "
                  f"{len(current_level)} program(s) ---")
        next_level = []
        for state, program in current_level:
            expansions += 1
            for desc, new_state in enumerate_focused(state):
                nb = new_state.buckets
                if trouble_count(nb.trouble, nb.growing) > max_trouble:
                    continue
                sig = (state_sig(*nb), new_state.lineage)
                if sig in seen:
                    continue
                seen.add(sig)
                new_program = program + [(describe(desc), desc)]
                if diagnostics is not None:
                    tc = trouble_count(nb.trouble, nb.growing)
                    h = diagnostics["trouble_histogram"]
                    h[tc] = h.get(tc, 0) + 1
                if is_victory(nb.trouble, nb.growing):
                    if verbose:
                        print(f"  VICTORY at level {level}: "
                              f"{len(new_program)}-line plan, "
                              f"{expansions} expansions, "
                              f"{len(seen)} states")
                    return new_program, False, expansions, len(seen)
                next_level.append((new_state, new_program))
            if expansions >= max_states:
                if verbose:
                    print(f"  EXHAUSTED max_states={max_states}")
                if diagnostics is not None:
                    diagnostics["sample_states"] = [
                        (s, [line for line, _ in prog])
                        for s, prog in next_level[-5:]
                    ]
                return None, True, expansions, len(seen)
        if diagnostics is not None:
            diagnostics["level_widths"].append(len(next_level))
        if verbose:
            print(f"  level {level} → "
                  f"{len(next_level)} program(s) at level {level + 1}")
        current_level = next_level
    return None, False, expansions, len(seen)


def solve(board, *, max_trouble_outer=8, max_states=10000,
          verbose=True):
    """Outer iterative-deepening on max_trouble. Takes a flat
    board (list of stacks) and partitions into HELPER /
    TROUBLE before running the inner BFS. Returns a list of
    plan lines (no descs). For descs, see
    `solve_state_with_descs`."""
    helper = [s for s in board if classify(s) != "other"]
    trouble = [s for s in board if classify(s) == "other"]
    initial = Buckets(helper, trouble, [], [])
    return solve_state(initial,
                       max_trouble_outer=max_trouble_outer,
                       max_states=max_states,
                       verbose=verbose)


def solve_state(initial, *, max_trouble_outer=8, max_states=10000,
                verbose=True):
    """Inner BFS driver returning a list of plan lines.
    Iterates the outer cap from 1 upward; first cap to find a
    plan returns. The hope: caps below the puzzle's true peak
    trouble fail FAST (frontier dies quickly because most
    moves exceed the cap)."""
    plan = solve_state_with_descs(
        initial, max_trouble_outer=max_trouble_outer,
        max_states=max_states, verbose=verbose)
    if plan is None:
        return None
    return [line for line, _desc in plan]


def solve_state_with_descs(initial, *, max_trouble_outer=8,
                           max_states=10000,
                           on_cap_exhausted=None,
                           verbose=False):
    """Same as solve_state but returns [(line, desc), ...].
    The desc dicts feed `verbs.move_to_primitives` for
    primitive translation. Returns None if no plan within the
    outer cap.

    `on_cap_exhausted` (optional callable) fires once per cap
    that completes without finding a plan, with kwargs
    {cap, expansions, seen_count, hit_max_states, diagnostics}.
    `hit_max_states=True` means the search aborted on the
    state budget (BAD — possible runaway). False means the
    frontier emptied naturally (GOOD termination).
    """
    # Accept either a Buckets NamedTuple or a bare 4-tuple
    # (legacy callers + tests still pass tuples). Promote to
    # Buckets if needed.
    if not isinstance(initial, Buckets):
        initial = Buckets(*initial)
    if trouble_count(initial.trouble, initial.growing) > max_trouble_outer:
        return None
    if is_victory(initial.trouble, initial.growing):
        return []
    # Wrap the Buckets into a FocusedState by attaching the
    # initial lineage (the trouble entries in board order).
    initial5 = FocusedState(
        buckets=initial,
        lineage=initial_lineage(initial.trouble, initial.growing),
    )
    for cap in range(1, max_trouble_outer + 1):
        if verbose:
            print(f"\n========== outer pass: max_trouble={cap} "
                  f"==========")
        diags = {} if on_cap_exhausted is not None else None
        result, exhausted, expansions, seen_n = bfs_with_cap(
            initial5, cap, max_states,
            diagnostics=diags, verbose=verbose)
        if result is not None:
            if verbose:
                print(f"\nVICTORY at cap={cap} in {len(result)} "
                      f"lines.")
            return result
        if verbose:
            print(f"  → cap={cap} exhausted "
                  f"({expansions} expansions, {seen_n} states)")
        if on_cap_exhausted is not None:
            on_cap_exhausted(cap=cap, expansions=expansions,
                             seen_count=seen_n,
                             hit_max_states=exhausted,
                             diagnostics=diags)
    return None
