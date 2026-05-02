"""
tools/hint_demo.py — standalone hint-transcript demo.

Simulates 3 turns of a Lyn Rummy game offline, calling
agent_prelude.find_play each turn and printing a human-readable
transcript of what the hint would be at each step.

No server required. Runs directly from the python/ directory:

    python3 tools/hint_demo.py

Seed 42 is fixed so the output is deterministic. The hint
projection mechanics (search order, dirty-board constraint) are
documented in `python/SOLVER.md` § "Hint projection".
"""

import random
import sys
import os

# Allow running from tools/ subdirectory.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import dealer
import ts_solver
from rules import classify, card_label, is_partial_ok

# Keep the projection budget aligned with agent_prelude's default
# (5000 per projection — see SOLVER.md § "Hint projection").
_PROJECTION_MAX_STATES = 5000


def _try_projection(board, extra_stacks):
    """Append extra_stacks to board, run TS BFS, return plan or None.
    Mirrors what agent_prelude._try_projection did locally."""
    return ts_solver.solve_board(
        list(board) + list(extra_stacks),
        max_trouble_outer=10,
        max_states=_PROJECTION_MAX_STATES,
    )


def _format_hint_steps(result):
    """Mirror agent_prelude.format_hint: 'place [...] from hand' +
    plan lines. Returns [] when result is None."""
    if result is None:
        return []
    labels = " ".join(card_label(c) for c in result["placements"])
    steps = [f"place [{labels}] from hand"]
    steps.extend(result["plan"])
    return steps


def hint_scenario_dsl(name, hand, board, result):
    """Produce DSL text for one hint_for_hand conformance scenario."""
    hand_str = " ".join(card_label(c) for c in hand)
    board_block = "\n".join(
        "    - " + " ".join(card_label(c) for c in stack)
        for stack in board
    )
    steps = _format_hint_steps(result)
    if steps:
        steps_block = "  expect_steps:\n" + "\n".join(f"    - {s}" for s in steps)
    else:
        steps_block = "  expect_steps: []"
    return (
        f"scenario {name}\n"
        f"  op: hint_for_hand\n"
        f"  hand: {hand_str}\n"
        f"  board:\n{board_block}\n"
        f"{steps_block}\n"
    )


# --- Conversion helpers (dealer dicts → BFS tuple shape) ---

def board_to_tuples(board_list):
    """Convert dealer board (list of stack dicts) to list of
    card-tuple lists as expected by agent_prelude.find_play."""
    return [
        [
            (bc["card"]["value"], bc["card"]["suit"], bc["card"]["origin_deck"])
            for bc in stack["board_cards"]
        ]
        for stack in board_list
    ]


def hand_cards_to_tuples(hand_card_list):
    """Convert dealer hand_cards (list of hand-card dicts) to
    list of card tuples (value, suit, deck)."""
    return [
        (hc["card"]["value"], hc["card"]["suit"], hc["card"]["origin_deck"])
        for hc in hand_card_list
    ]


def deck_to_tuples(deck_list):
    """Convert dealer deck (list of card dicts) to card tuples."""
    return [
        (c["value"], c["suit"], c["origin_deck"])
        for c in deck_list
    ]


# --- Board stats helper ---

def board_stats(board):
    """Return (total, helper_count, trouble_count) for a tuple board."""
    helper = [s for s in board if classify(s) != "other"]
    trouble = [s for s in board if classify(s) == "other"]
    return len(board), len(helper), len(trouble)


# --- Main simulation ---

def main():
    state = dealer.deal(num_players=2, hand_size=7, rng=random.Random(42))

    board = board_to_tuples(state["board"])
    hand = hand_cards_to_tuples(state["hands"][0]["hand_cards"])
    deck = deck_to_tuples(state["deck"])
    deck_cursor = 0

    # Collect (turn_name, hand_snapshot, board_snapshot, result) for DSL output.
    dsl_records = []

    for turn in range(1, 4):
        total, n_helper, n_trouble = board_stats(board)
        hand_labels = "  ".join(card_label(c) for c in hand)
        print(f"=== Turn {turn} ===")
        print(f"Hand ({len(hand)}): {hand_labels}")
        print(f"Board: {total} stacks ({n_helper} helper, {n_trouble} trouble)")
        print()

        # Show which pairs / singletons are being tried.
        print("Projecting hand cards...")
        tried_as_singleton = set()

        # Pairs pass.
        for i, c1 in enumerate(hand):
            for c2 in hand[i + 1:]:
                if not is_partial_ok([c1, c2]):
                    continue
                tried_as_singleton.add(id(c1))
                tried_as_singleton.add(id(c2))
                pair_labels = f"{card_label(c1)}, {card_label(c2)}"
                plan = _try_projection(board, [[c1, c2]])
                if plan is not None:
                    print(f"  pair ({pair_labels}): plan found "
                          f"({len(plan)} step{'s' if len(plan) != 1 else ''})")
                else:
                    print(f"  pair ({pair_labels}): no plan")

        # Singleton pass.
        for c in hand:
            lbl = card_label(c)
            plan = _try_projection(board, [[c]])
            if plan is not None:
                print(f"  singleton {lbl}: plan found "
                      f"({len(plan)} step{'s' if len(plan) != 1 else ''})")
            else:
                print(f"  singleton {lbl}: no plan")

        print()

        # Capture snapshots BEFORE modifying hand/board.
        hand_snapshot = list(hand)
        board_snapshot = [list(s) for s in board]

        result = ts_solver.find_play(hand, board)

        # Record for DSL output.
        dsl_records.append((f"turn_{turn}_hint", hand_snapshot, board_snapshot, result))

        if result is not None:
            placements = result["placements"]
            placement_labels = " ".join(card_label(c) for c in placements)
            print(f"Hint: play [{placement_labels}]")
            for i, step in enumerate(_format_hint_steps(result), 1):
                print(f"  Step {i}: {step}")

            # Advance state: remove placed cards, append as new stack.
            for c in placements:
                hand.remove(c)
            board.append(list(placements))

            # Simulate draw: 2 cards from deck.
            drawn = deck[deck_cursor:deck_cursor + 2]
            deck_cursor += 2
            hand.extend(drawn)
            if drawn:
                drawn_labels = " ".join(card_label(c) for c in drawn)
                print(f"  (drew: {drawn_labels})")
        else:
            print("No hint — stuck.")

        print()

    # Write DSL file.
    # __file__ is .../python/tools/hint_demo.py; go up 4 levels to repo root.
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
    dsl_rel = "games/lynrummy/conformance/scenarios/hint_game_seed42.dsl"
    dsl_path = os.path.join(repo_root, dsl_rel)

    header = (
        "# hint_game_seed42.dsl — auto-generated by tools/hint_demo.py\n"
        "# Seed 42, 7-card hands. Regenerate by running:\n"
        "#   python3 tools/hint_demo.py\n"
    )
    scenario_blocks = [
        hint_scenario_dsl(name, hand_snap, board_snap, res)
        for name, hand_snap, board_snap, res in dsl_records
    ]
    dsl_text = header + "\n" + "\n".join(scenario_blocks)

    with open(dsl_path, "w") as f:
        f.write(dsl_text)

    print(f"DSL written to: {dsl_rel}")


if __name__ == "__main__":
    main()
