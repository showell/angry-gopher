"""
mine_doomed_growing.py — search the BFS frontier of a slow
case for states where a growing 2-partial is doomed in the
CURRENT-state inventory (helper + trouble singletons).

The doomed-third filter prunes at MERGE time (the partial is
doomed AT ADMISSION). It doesn't re-check existing growing
partials. If the BFS later consumes the only completion
candidate for an already-admitted partial, that partial
becomes doomed mid-search and the whole state is dead.

This script walks the BFS for a chosen snapshot, inspecting
every reached state. It reports any state with at least one
doomed-in-current-state growing 2-partial.

Usage:
    python3 mine_doomed_growing.py /tmp/perf_snapshots.jsonl
"""

import argparse
import json
import sys

sys.path.insert(0, ".")
import buckets
import enumerator


def _doomed_growing_partials(state):
    """Return list of growing 2-partials that have NO
    completion candidate in this state's helper + trouble
    singletons."""
    helper, trouble, growing, _ = state
    inv = enumerator.completion_inventory(helper, trouble)
    out = []
    for g in growing:
        if len(g) == 2:
            shapes = enumerator.completion_shapes(g)
            if not (shapes & inv):
                out.append(g)
    return out


def _walk_bfs(initial, max_trouble, max_states):
    """Walk the BFS up to max_states, yielding each state
    reached."""
    if buckets.trouble_count(initial[1], initial[2]) > max_trouble:
        return
    seen = {buckets.state_sig(*initial)}
    yield initial
    frontier = [initial]
    expansions = 0
    while frontier:
        next_frontier = []
        for state in frontier:
            expansions += 1
            for desc, ns in enumerator.enumerate_moves(state):
                if buckets.trouble_count(ns[1], ns[2]) > max_trouble:
                    continue
                sig = buckets.state_sig(*ns)
                if sig in seen:
                    continue
                seen.add(sig)
                yield ns
                next_frontier.append(ns)
            if expansions >= max_states:
                return
        frontier = next_frontier


def _stack_str(stack):
    return "[" + " ".join(
        f"{c[0]}/{'CDSH'[c[1]]}{c[2] if c[2] else ''}"
        for c in stack
    ) + "]"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("snapshots")
    ap.add_argument("--max-trouble", type=int, default=10)
    ap.add_argument("--max-states", type=int, default=10000)
    ap.add_argument("--rank", type=int, default=1,
                    help="1 = slowest snapshot, 2 = next, ...")
    args = ap.parse_args()

    with open(args.snapshots) as f:
        snaps = [json.loads(l) for l in f if l.strip()]
    snaps = [s for s in snaps if s["total_wall"] < 30]
    snaps.sort(key=lambda s: s["total_wall"], reverse=True)
    rec = snaps[args.rank - 1]

    board = [[tuple(c) for c in s] for s in rec["board"]]
    print(f"Mining snapshot rank #{args.rank}: hand={len(rec['hand'])}, "
          f"board={len(board)}.")

    # Try each projection's initial state.
    from rules import classify
    found_total = 0
    for proj in rec["projections"]:
        extra = [list(map(tuple, proj["cards"]))]
        augmented = list(board) + extra
        helper = [s for s in augmented if classify(s) != "other"]
        trouble = [s for s in augmented if classify(s) == "other"]
        initial = (helper, trouble, [], [])

        n_states = 0
        n_doomed = 0
        first_doomed = None
        for state in _walk_bfs(initial, args.max_trouble,
                                args.max_states):
            n_states += 1
            doomed = _doomed_growing_partials(state)
            if doomed:
                n_doomed += 1
                if first_doomed is None:
                    first_doomed = (state, doomed)

        print(f"\nprojection {proj['kind']} cards={proj['cards']}:")
        print(f"  {n_states} states walked, "
              f"{n_doomed} had doomed growing partials.")
        if first_doomed is not None:
            state, doomed = first_doomed
            helper, trouble, growing, complete = state
            print(f"  first doomed-growing state:")
            print(f"    helper ({len(helper)} stacks):")
            for s in helper:
                print(f"      {_stack_str(s)}")
            print(f"    trouble: {[_stack_str(s) for s in trouble]}")
            print(f"    growing: {[_stack_str(s) for s in growing]}")
            print(f"    DOOMED partials: "
                  f"{[_stack_str(s) for s in doomed]}")
        found_total += n_doomed

    if found_total == 0:
        print("\nNo doomed-growing states found. Either the "
              "scenario doesn't reach them or they're rarer "
              "than expected.")


if __name__ == "__main__":
    main()
