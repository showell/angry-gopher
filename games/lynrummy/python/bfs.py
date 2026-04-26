"""
bfs.py — pure BFS by program length with iterative outer
cap on trouble_count.

The Python equivalent of `Game.Agent.Bfs.elm`. Lifted from
`bfs_solver.py` 2026-04-26 as the module split landed.
"""

from buckets import (
    Buckets, FocusedState,
    is_victory, state_sig, trouble_count,
)
from cards import classify
from enumerator import enumerate_focused, initial_lineage
from move import describe_move


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
                new_program = program + [(describe_move(desc), desc)]
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
    The desc dicts feed `verbs.step_to_primitives` for
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
