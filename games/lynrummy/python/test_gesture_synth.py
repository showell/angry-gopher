"""
test_gesture_synth.py — plain-Python assertions for the
synthetic gesture generator. Run directly:

    python3 games/lynrummy/python/test_gesture_synth.py
"""

import sys

import gesture_synth
from geometry import CARD_PITCH, CARD_HEIGHT, BOARD_VIEWPORT_LEFT, BOARD_VIEWPORT_TOP


def _stack(left, top, size):
    return {
        "loc": {"left": left, "top": top},
        "board_cards": [{"card": {"value": 1, "suit": 0, "origin_deck": 0},
                         "state": 0}] * size,
    }


def test_path_shape():
    # 100 pixels diagonal at 80ms/px (default) = 8000ms. We set
    # samples=5 to keep the test fast; duration is derived.
    meta = gesture_synth.synthesize((10, 20), (100, 200), samples=5)
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


def test_synthesize_duration_scales_with_distance():
    short = gesture_synth.synthesize((0, 0), (10, 0), samples=2)
    long = gesture_synth.synthesize((0, 0), (100, 0), samples=2)
    dt_short = short["path"][-1]["t"] - short["path"][0]["t"]
    dt_long = long["path"][-1]["t"] - long["path"][0]["t"]
    assert dt_long > dt_short, \
        f"longer drag should take longer: {dt_short} vs {dt_long}"
    return f"short={dt_short:.0f}ms long={dt_long:.0f}ms"


def test_merge_hand_returns_none():
    board = [_stack(40, 40, 3)]
    prim = {"action": "merge_hand", "target_stack": 0, "side": "right",
            "hand_card": {"value": 9, "suit": 1, "origin_deck": 1}}
    assert gesture_synth.drag_endpoints(prim, board) is None, \
        "merge_hand origin is unknowable to Python; must return None"
    return "hand-origin → None"


def test_move_stack_uses_viewport_coords():
    board = [_stack(100, 50, 4)]
    prim = {"action": "move_stack", "stack_index": 0,
            "new_loc": {"left": 400, "top": 200}}
    start, end = gesture_synth.drag_endpoints(prim, board)
    # Start = viewport offset + source loc center.
    assert start[0] == BOARD_VIEWPORT_LEFT + 100 + 4 * CARD_PITCH // 2
    assert start[1] == BOARD_VIEWPORT_TOP + 50 + CARD_HEIGHT // 2
    # End = viewport offset + new_loc center.
    assert end[0] == BOARD_VIEWPORT_LEFT + 400 + 4 * CARD_PITCH // 2
    assert end[1] == BOARD_VIEWPORT_TOP + 200 + CARD_HEIGHT // 2
    return f"move_stack drag {start} -> {end}"


def test_drag_endpoints_returns_none_for_non_drag():
    assert gesture_synth.drag_endpoints({"action": "complete_turn"}, []) is None
    assert gesture_synth.drag_endpoints({"action": "undo"}, []) is None
    return "non-drag primitives → None"


TESTS = [
    test_path_shape,
    test_synthesize_duration_scales_with_distance,
    test_merge_hand_returns_none,
    test_move_stack_uses_viewport_coords,
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
