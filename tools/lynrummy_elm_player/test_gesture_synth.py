"""
test_gesture_synth.py — plain-Python assertions for the
synthetic gesture generator. Run directly:

    python3 tools/lynrummy_elm_player/test_gesture_synth.py
"""

import sys

import gesture_synth
from geometry import CARD_PITCH, CARD_HEIGHT


def _stack(left, top, size):
    return {
        "loc": {"left": left, "top": top},
        "board_cards": [{"card": {"value": 1, "suit": 0, "origin_deck": 0},
                         "state": 0}] * size,
    }


def test_path_shape():
    meta = gesture_synth.synthesize((10, 20), (100, 200), samples=5, duration_ms=100)
    assert meta["pointer_type"] == "synthetic"
    assert meta["device_pixel_ratio"] == 1.0
    path = meta["path"]
    assert len(path) == 5, f"want 5 samples, got {len(path)}"
    assert path[0]["x"] == 10 and path[0]["y"] == 20
    assert path[-1]["x"] == 100 and path[-1]["y"] == 200
    # Monotonic time.
    for a, b in zip(path, path[1:]):
        assert b["t"] > a["t"], f"time not monotonic: {a['t']} -> {b['t']}"
    return "path well-formed"


def test_merge_hand_right_endpoint():
    board = [_stack(40, 40, 3)]
    prim = {"action": "merge_hand", "target_stack": 0, "side": "right",
            "hand_card": {"value": 9, "suit": 1, "origin_deck": 1}}
    start, end = gesture_synth.drag_endpoints(prim, board)
    # Right-side drop lands at the target's right edge:
    # target's left + target_size * CARD_PITCH.
    expected_x = 40 + 3 * CARD_PITCH
    expected_y = 40 + CARD_HEIGHT // 2
    assert end == (expected_x, expected_y), f"end={end}, want {(expected_x, expected_y)}"
    # Start should be near hand area (y below the board).
    assert start[1] > 40, f"hand origin should be below board row: {start}"
    return f"right-merge end at {end}"


def test_merge_hand_left_endpoint():
    board = [_stack(40, 40, 3)]
    prim = {"action": "merge_hand", "target_stack": 0, "side": "left",
            "hand_card": {"value": 9, "suit": 1, "origin_deck": 1}}
    _, end = gesture_synth.drag_endpoints(prim, board)
    # Left-side drop lands at the target's left edge.
    assert end[0] == 40, f"left-merge end.x = {end[0]}, want 40"
    return f"left-merge end at {end}"


def test_move_stack_endpoints():
    board = [_stack(100, 50, 4)]
    prim = {"action": "move_stack", "stack_index": 0,
            "new_loc": {"left": 400, "top": 200}}
    start, end = gesture_synth.drag_endpoints(prim, board)
    # Drag from stack center to new-loc center.
    assert start[0] == 100 + 4 * CARD_PITCH // 2
    assert end[0] == 400 + 4 * CARD_PITCH // 2
    return f"move_stack drag {start} -> {end}"


def test_drag_endpoints_returns_none_for_non_drag():
    # complete_turn, undo etc.
    assert gesture_synth.drag_endpoints({"action": "complete_turn"}, []) is None
    assert gesture_synth.drag_endpoints({"action": "undo"}, []) is None
    return "non-drag primitives → None"


TESTS = [
    test_path_shape,
    test_merge_hand_right_endpoint,
    test_merge_hand_left_endpoint,
    test_move_stack_endpoints,
    test_drag_endpoints_returns_none_for_non_drag,
]


def main():
    passed = failed = 0
    for fn in TESTS:
        try:
            msg = fn()
            print(f"PASS  {fn.__name__:<45}  {msg}")
            passed += 1
        except AssertionError as e:
            print(f"FAIL  {fn.__name__:<45}  {e}")
            failed += 1
        except Exception as e:
            print(f"FAIL  {fn.__name__:<45}  {type(e).__name__}: {e}")
            failed += 1
    print()
    print(f"{passed}/{passed + failed} passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
