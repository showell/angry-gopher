"""
extract_longest_program.py — for a given runaway projection,
walk the BFS up to the cap and dump the LONGEST candidate
DSL-style program it generated before exhausting.

Useful for inspecting the chains the agent chases when it's
stuck. Each line is `describe(desc)` form.

Usage:
    python3 extract_longest_program.py /tmp/runaway_hunt.jsonl \
        --evil "10/0/0"   # value/suit/deck of the runaway card
        [--max-states N]  # cap (default 5000)
"""

import argparse
import json
import sys

sys.path.insert(0, ".")
import buckets
import cards
import enumerator
import move
from cards import classify


def _parse_card(s):
    parts = s.split("/")
    return (int(parts[0]), int(parts[1]), int(parts[2]))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("snapshots")
    ap.add_argument("--evil", required=True,
                    help="Evil card as value/suit/deck (e.g. 10/0/0)")
    ap.add_argument("--max-states", type=int, default=5000)
    args = ap.parse_args()

    evil = _parse_card(args.evil)

    with open(args.snapshots) as f:
        snaps = [json.loads(l) for l in f if l.strip()]

    # Find a snapshot containing this evil-card runaway.
    target_snap = None
    for snap in snaps:
        for proj in snap["projections"]:
            for ex in proj.get("exhaustions", []):
                if (ex.get("hit_max_states")
                        and tuple(proj["cards"][0]) == evil):
                    target_snap = snap
                    break

    if target_snap is None:
        sys.exit(f"no runaway found for evil card {evil}")

    board = [[tuple(c) for c in s] for s in target_snap["board"]]
    augmented = list(board) + [[evil]]
    helper = [s for s in augmented if classify(s) != "other"]
    trouble = [s for s in augmented if classify(s) == "other"]
    initial = (helper, trouble, [], [])

    print(f"Runaway projection for evil={evil}")
    print(f"  board: {len(board)} stacks")
    print(f"  initial helper count: {len(helper)}, "
          f"trouble count: {len(trouble)}")

    # Walk the BFS at the same cap range as production. Track
    # the program (sequence of descs) per state. Keep the
    # longest program seen overall.
    longest = []
    longest_state = None
    longest_cap = None
    for cap in range(1, 11):
        if buckets.trouble_count(initial[1], initial[2]) > cap:
            continue
        seen = {buckets.state_sig(*initial)}
        frontier = [(initial, [])]
        expansions = 0
        while frontier:
            next_frontier = []
            for state, program in frontier:
                expansions += 1
                for desc, ns in enumerator.enumerate_moves(state):
                    if buckets.trouble_count(ns[1], ns[2]) > cap:
                        continue
                    sig = buckets.state_sig(*ns)
                    if sig in seen:
                        continue
                    seen.add(sig)
                    new_program = program + [desc]
                    if buckets.is_victory(ns[1], ns[2]):
                        # Wouldn't be a runaway; bail.
                        return
                    if len(new_program) > len(longest):
                        longest = new_program
                        longest_state = ns
                        longest_cap = cap
                    next_frontier.append((ns, new_program))
                if expansions >= args.max_states:
                    break
            else:
                frontier = next_frontier
                continue
            break  # broke out of the for due to cap hit
        # Continue to next cap to see if a longer program emerges.

    if not longest:
        print("\nNo program found.")
        return

    print(f"\nLongest candidate program: {len(longest)} steps "
          f"(found at cap={longest_cap}).\n")
    for i, desc in enumerate(longest, 1):
        line = move.describe(desc)
        print(f"  {i:>2}. {line}")

    if longest_state is not None:
        helper2, trouble2, growing2, complete2 = longest_state
        print(f"\nFinal state at the end of this program:")
        print(f"  helper: {len(helper2)} stacks")
        for s in helper2:
            print(f"    {[cards.card_label(c) for c in s]}")
        print(f"  trouble: {[[cards.card_label(c) for c in s] for s in trouble2]}")
        print(f"  growing: {[[cards.card_label(c) for c in s] for s in growing2]}")
        print(f"  complete: {len(complete2)} stacks")


if __name__ == "__main__":
    main()
