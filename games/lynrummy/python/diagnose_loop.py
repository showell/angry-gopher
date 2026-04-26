"""
diagnose_loop.py — single-path skeleton-revisit detector.

The fear: a single BFS path generates its own descendants
that wear different state-sigs but represent the SAME
strategic position. state_sig wouldn't catch it because the
exact card identities differ; the program would keep
extending on top of a state it's effectively visited before.

This script:
  1. Runs find_play on a captured (hand, board) snapshot.
  2. Captures the DEEPEST sample state from the runaway
     projection, plus its program prefix (desc chain).
  3. Replays from initial state, emitting one state per
     move.
  4. Computes a "skeleton" per state — coarser than
     state_sig, ignoring suit/deck identity, focusing on
     bucket + value-multiset shape.
  5. Reports any skeleton COLLISION between two distinct
     steps in the path. Each collision = a single program
     looping through equivalent strategic positions.

Usage:
    python3 diagnose_loop.py /tmp/perf_snapshots.jsonl

By default examines the slowest captured runaway case.
"""

import argparse
import json
import sys
from collections import Counter

sys.path.insert(0, ".")
import bfs_solver as bs


# --- skeleton definition --------------------------------------

def _stack_value_multiset(stack):
    """Sorted tuple of values, ignoring suit/deck."""
    return tuple(sorted(c[0] for c in stack))


def _bucket_multiset(stacks):
    """Multiset of value-multiset shapes in this bucket. Two
    buckets with the same multiset have the same value-shape
    layout, regardless of which suits or decks are where."""
    return tuple(sorted(_stack_value_multiset(s) for s in stacks))


def skeleton(state):
    helper, trouble, growing, complete = state
    return (
        _bucket_multiset(helper),
        _bucket_multiset(trouble),
        _bucket_multiset(growing),
        _bucket_multiset(complete),
    )



# --- replay ---------------------------------------------------

def replay_program(initial, descs):
    """Given an initial state and a sequence of descs, return
    [state0=initial, state1, ..., state_n]. Re-derives by
    finding the matching desc in enumerate_moves(prev) at
    each step."""
    chain = [initial]
    state = initial
    for i, desc in enumerate(descs):
        match = None
        for d, ns in bs.enumerate_moves(state):
            if _descs_equivalent(d, desc):
                match = ns
                break
        if match is None:
            raise RuntimeError(
                f"cannot find desc match at step {i}: {desc}")
        chain.append(match)
        state = match
    return chain


def _descs_equivalent(a, b):
    """Two descs are 'the same move' if they produce the
    same observable record. The desc dicts include all
    relevant fields (type, ext_card / loose / source /
    target_before / side / etc), so equality is sufficient."""
    if a.get("type") != b.get("type"):
        return False
    # Compare structural fields per type. A direct dict
    # equality check works for most cases since spawned and
    # source are lists with stable contents.
    return a == b



# --- runner ---------------------------------------------------

def _to_tuple_card(c):
    return (c[0], c[1], c[2])


def _to_tuple_stack(s):
    return [_to_tuple_card(c) for c in s]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("snapshots")
    ap.add_argument("--max-states", type=int, default=2000)
    args = ap.parse_args()

    with open(args.snapshots) as f:
        snaps = [json.loads(l) for l in f if l.strip()]
    snaps = [s for s in snaps if s["total_wall"] < 30]
    snaps.sort(key=lambda s: s["total_wall"], reverse=True)
    rec = snaps[0]

    print(f"Examining the slowest snap (captured "
          f"{rec['total_wall']:.2f}s, hand={len(rec['hand'])}, "
          f"board={len(rec['board'])}).")

    hand = [_to_tuple_card(c) for c in rec["hand"]]
    board = [_to_tuple_stack(s) for s in rec["board"]]

    # We want the runaway projection's deepest sample. Re-run
    # find_play with a low budget + diagnostics.
    import agent_prelude
    stats = {}
    agent_prelude.find_play_with_budget(
        hand, board, max_states=args.max_states, stats=stats)

    runaways = []
    for proj in stats.get("projections", []):
        for ex in proj.get("exhaustions", []):
            if ex["hit_max_states"]:
                runaways.append((proj, ex))

    if not runaways:
        print("No runaway projection found at this budget. "
              "Try lowering --max-states.")
        return

    # Pick the runaway with the deepest sample state.
    proj, ex = runaways[0]
    diags = ex.get("diagnostics", {})
    samples = diags.get("sample_states", [])
    if not samples:
        print("Runaway has no sample_states captured.")
        return

    # Reconstruct the initial state for the projection.
    from beginner import classify
    augmented = list(board) + [list(map(tuple, proj["cards"]))]
    helper = [s for s in augmented if classify(s) != "other"]
    trouble = [s for s in augmented if classify(s) == "other"]
    initial = (helper, trouble, [], [])

    print(f"\nRunaway projection: kind={proj['kind']!r} "
          f"cards={proj['cards']} cap={ex['cap']}")
    print(f"Captured {len(samples)} sample states from the "
          f"frontier at cap-exhaustion.")

    any_collision = False
    for s_idx, (sample_state, sample_lines) in enumerate(samples):
        print(f"\n--- sample {s_idx + 1} (program length "
              f"{len(sample_lines)}) ---")
        descs = _find_desc_chain_to(initial, sample_state,
                                     max_trouble=ex["cap"],
                                     max_states=args.max_states)
        if descs is None:
            print("  desc chain unrecoverable")
            continue
        chain = replay_program(initial, descs)
        skels = [skeleton(s) for s in chain]
        seen_at = {}
        collisions = []
        for i, sk in enumerate(skels):
            if sk in seen_at:
                collisions.append((seen_at[sk], i))
            seen_at[sk] = i
        if not collisions:
            print(f"  no skeleton revisits along this "
                  f"{len(chain)}-step path")
            continue
        any_collision = True
        print(f"  ⚠ {len(collisions)} skeleton revisit(s):")
        for earlier, later in collisions:
            print(f"    step {earlier} ↔ step {later} "
                  f"({later - earlier} moves between)")
            print(f"      skeleton: {skels[earlier]}")

    if not any_collision:
        print("\nNo single-path loops found across all samples. "
              "The runaway is branching, not looping.")


def _find_desc_chain_to(initial, target_state, *,
                        max_trouble, max_states):
    """BFS the path: find a desc-chain from `initial` to
    `target_state` (matched by state_sig)."""
    target_sig = bs.state_sig(*target_state)
    if bs.state_sig(*initial) == target_sig:
        return []
    seen = {bs.state_sig(*initial)}
    frontier = [(initial, [])]
    expansions = 0
    while frontier:
        next_frontier = []
        for state, descs in frontier:
            expansions += 1
            for d, ns in bs.enumerate_moves(state):
                if bs.trouble_count(ns[1], ns[2]) > max_trouble:
                    continue
                sig = bs.state_sig(*ns)
                if sig in seen:
                    continue
                seen.add(sig)
                new_descs = descs + [d]
                if sig == target_sig:
                    return new_descs
                next_frontier.append((ns, new_descs))
            if expansions >= max_states:
                return None
        frontier = next_frontier
    return None


if __name__ == "__main__":
    main()
