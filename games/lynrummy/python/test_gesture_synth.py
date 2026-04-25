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
    # Path samples are floater top-left positions in board
    # frame (same convention Elm uses for captured paths).
    # Start = stack.loc; end = new_loc.
    board = [_stack(100, 50, 4)]
    prim = {"action": "move_stack", "stack_index": 0,
            "new_loc": {"left": 400, "top": 200}}
    start, end = gesture_synth.drag_endpoints(prim, board)
    assert start == (100, 50), f"start (stack top-left): {start}"
    assert end == (400, 200), f"end (new_loc top-left): {end}"
    return f"move_stack drag {start} -> {end}"


def test_drag_endpoints_returns_none_for_non_drag():
    assert gesture_synth.drag_endpoints({"action": "complete_turn"}, []) is None
    assert gesture_synth.drag_endpoints({"action": "undo"}, []) is None
    return "non-drag primitives → None"


def test_merge_stack_endpoints():
    # Floater top-left endpoints. Start = source.loc; end is
    # where the source's top-left lands flush against the
    # target (+2 / -2 jitter for realism).
    board = [_stack(200, 20, 3), _stack(80, 320, 4)]
    prim = {"action": "merge_stack",
            "source_stack": 0, "target_stack": 1, "side": "right"}
    start, end = gesture_synth.drag_endpoints(prim, board)
    assert start == (200, 20), f"start (source top-left): {start}"

    # Right-merge: source lands at target's right edge.
    expected_right = (80 + 4 * CARD_PITCH + 2, 320 - 2)
    assert end == expected_right, \
        f"right merge end: expected {expected_right}, got {end}"

    prim_left = dict(prim, side="left")
    _, end_left = gesture_synth.drag_endpoints(prim_left, board)
    # Left-merge: source lands at target.left − source.width.
    expected_left = (80 - 3 * CARD_PITCH + 2, 320 - 2)
    assert end_left == expected_left, \
        f"left merge end: expected {expected_left}, got {end_left}"
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
