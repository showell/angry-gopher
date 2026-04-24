"""
test_gesture_synth.py — plain-Python assertions for the
synthetic gesture generator. Run directly:

    python3 games/lynrummy/python/test_gesture_synth.py
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
    meta = gesture_synth.synthesize((10, 20), (100, 200), samples=5)
    assert meta["pointer_type"] == "synthetic"
    assert meta["path_frame"] == "board", \
        f"expected board-frame; got {meta['path_frame']}"
    path = meta["path"]
    assert len(path) == 5, f"want 5 samples, got {len(path)}"
    assert path[0]["x"] == 10 and path[0]["y"] == 20
    assert path[-1]["x"] == 100 and path[-1]["y"] == 200
    for a, b in zip(path, path[1:]):
        assert b["t"] > a["t"], f"time not monotonic: {a['t']} -> {b['t']}"
    return "path well-formed (board frame)"


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


def test_move_stack_uses_board_frame_coords():
    # Board frame: origin at the board's top-left. Python emits
    # board-frame coords; Elm renders the floater as a child of
    # the board div so CSS handles board→viewport for free.
    # Path points are CURSOR positions — center of stack,
    # matching what the renderer will subtract grabOffset from.
    board = [_stack(100, 50, 4)]
    prim = {"action": "move_stack", "stack_index": 0,
            "new_loc": {"left": 400, "top": 200}}
    start, end = gesture_synth.drag_endpoints(prim, board)
    assert start[0] == 100 + 4 * CARD_PITCH // 2
    assert start[1] == 50 + CARD_HEIGHT // 2
    assert end[0] == 400 + 4 * CARD_PITCH // 2
    assert end[1] == 200 + CARD_HEIGHT // 2
    return f"move_stack drag {start} -> {end}"


def test_drag_endpoints_returns_none_for_non_drag():
    assert gesture_synth.drag_endpoints({"action": "complete_turn"}, []) is None
    assert gesture_synth.drag_endpoints({"action": "undo"}, []) is None
    return "non-drag primitives → None"


def test_merge_stack_endpoints():
    # Cursor-based endpoints. Start = source center. End =
    # cursor position such that the source floater lands flush
    # against the target (cursor = floater.top-left +
    # grabOffset). Plus a fixed 2-px realism jitter.
    board = [_stack(200, 20, 3), _stack(80, 320, 4)]
    prim = {"action": "merge_stack",
            "source_stack": 0, "target_stack": 1, "side": "right"}
    start, end = gesture_synth.drag_endpoints(prim, board)
    assert start[0] == 200 + 3 * CARD_PITCH // 2
    assert start[1] == 20 + CARD_HEIGHT // 2

    # Source (3-card) top-left lands at target's right edge
    # (80 + 4*CARD_PITCH). Cursor = floater.top-left +
    # src_half_width. Plus +2 jitter x, -2 jitter y.
    expected_right_x = 80 + 4 * CARD_PITCH + 3 * CARD_PITCH // 2 + 2
    expected_y = 320 + CARD_HEIGHT // 2 - 2
    assert end == (expected_right_x, expected_y), \
        f"right merge end: expected {(expected_right_x, expected_y)}, got {end}"

    prim_left = dict(prim, side="left")
    _, end_left = gesture_synth.drag_endpoints(prim_left, board)
    # Source top-left at (80 - 3*CARD_PITCH, 320). Cursor +=
    # src_half_width, jitter.
    expected_left_x = 80 - 3 * CARD_PITCH + 3 * CARD_PITCH // 2 + 2
    assert end_left == (expected_left_x, expected_y), \
        f"left merge end: expected {(expected_left_x, expected_y)}, got {end_left}"
    return f"merge_stack drag {start} -> {end}"


def test_ease_curve_is_not_linear():
    # 100 px straight-line path; a pure-linear curve would put
    # the midpoint sample at x≈50. Our cosine ease also has the
    # midpoint at 50 (by symmetry), so we check a non-mid
    # sample. At frac=0.25, linear would put x=25; cosine-ease
    # gives (1 - cos(π/4)) / 2 ≈ 0.146 → x≈15. That gap is the
    # proof the path accelerates rather than cruising.
    meta = gesture_synth.synthesize((0, 0), (100, 0), samples=5)
    path = meta["path"]
    quarter_x = path[1]["x"]  # frac = 1/4
    linear_quarter = 25
    assert quarter_x < linear_quarter, \
        f"quarter sample should lag linear: {quarter_x} vs {linear_quarter}"
    # Symmetric: three-quarter sample should LEAD linear.
    three_q_x = path[3]["x"]
    linear_three_q = 75
    assert three_q_x > linear_three_q, \
        f"three-quarter sample should lead linear: {three_q_x} vs {linear_three_q}"
    return f"quarter={quarter_x} (<25), three-quarter={three_q_x} (>75)"


TESTS = [
    test_path_shape,
    test_synthesize_duration_scales_with_distance,
    test_merge_hand_returns_none,
    test_move_stack_uses_board_frame_coords,
    test_merge_stack_endpoints,
    test_ease_curve_is_not_linear,
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
