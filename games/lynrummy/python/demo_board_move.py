"""
demo_board_move — create a fresh session, execute ONE
move_stack primitive with an exaggerated-pace eased path, and
print the replay URL.

Purpose: tight feedback loop for tuning board-to-board drag
physics. A full agent game produces 40+ actions and obscures
the one thing we're iterating on. This script does ONE clear
move from the top-left initial stack to a clearly empty
bottom-right location, so the drag is a long diagonal that
makes ease + pacing easy to eyeball.

Usage:
    python3 games/lynrummy/python/demo_board_move.py
    python3 games/lynrummy/python/demo_board_move.py --pace 10

`--pace N` overrides ms_per_pixel. Defaults to 12 (exaggerated
slowness so the ease is obvious). Production Python setting is
5 (see `DRAG_MS_PER_PIXEL` in gesture_synth.py).
"""

import argparse
import sys

from client import Client
import gesture_synth

# Stack 0 is the initial KS,AS,2S,3S spade run.
SOURCE_INDEX = 0

# Clearly-empty bottom-right corner of the 800×600 board. Well
# clear of the initial layout's 6 stacks (all near top-left /
# top / middle).
TARGET_LOC = {"left": 500, "top": 450}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pace", type=int, default=10,
                    help="ms per pixel (higher = slower / more exaggerated)")
    args = ap.parse_args()

    c = Client()
    sid = c.new_session()
    print(f"session {sid}")

    state = c.get_state(sid)
    source = state["state"]["board"][SOURCE_INDEX]
    src_loc = source["loc"]
    src_size = len(source["board_cards"])

    print(f"source stack: {src_size} cards at board-frame "
          f"({src_loc['left']}, {src_loc['top']})")
    print(f"target loc:   ({TARGET_LOC['left']}, {TARGET_LOC['top']})")

    prim = {
        "action": "move_stack",
        "stack_index": SOURCE_INDEX,
        "new_loc": TARGET_LOC,
    }
    endpoints = gesture_synth.drag_endpoints(prim, state["state"]["board"])
    if endpoints is None:
        print("error: drag_endpoints returned None", file=sys.stderr)
        return 1

    start, end = endpoints
    distance = ((end[0] - start[0]) ** 2 + (end[1] - start[1]) ** 2) ** 0.5
    print(f"drag:         ({start[0]}, {start[1]}) → ({end[0]}, {end[1]})  "
          f"= {distance:.0f}px")

    meta = gesture_synth.synthesize(start, end, ms_per_pixel=args.pace)
    duration = meta["path"][-1]["t"] - meta["path"][0]["t"]
    print(f"pace:         {args.pace}ms/px  →  duration {duration:.0f}ms")

    wire_action = {
        "action": "move_stack",
        "stack": source,
        "new_loc": TARGET_LOC,
    }
    c.send_action(sid, wire_action, gesture_metadata=meta)

    print()
    print(f"browse:  http://localhost:9000/gopher/lynrummy-elm/play/{sid}")
    print(f"         click Instant Replay to watch the drag.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
