"""
tools/hint_demo.py — standalone hint-transcript demo.

Simulates 3 turns of a Lyn Rummy game offline, calling
agent_prelude.find_play each turn and printing a human-readable
transcript of what the hint would be at each step.

No server required. Runs directly from the python/ directory:

    python3 tools/hint_demo.py

Seed 42 is fixed so the output is deterministic and can be
cross-referenced against HINT_PROJECTION.md.
"""

import random
import sys
import os

# Allow running from tools/ subdirectory.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import dealer
import agent_prelude
from agent_prelude import hint_scenario_dsl
from rules import classify, card_label, is_partial_ok


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
                plan = agent_prelude._try_projection(board, [[c1, c2]])
                if plan is not None:
                    print(f"  pair ({pair_labels}): plan found "
                          f"({len(plan)} step{'s' if len(plan) != 1 else ''})")
                else:
                    print(f"  pair ({pair_labels}): no plan")

        # Singleton pass.
        for c in hand:
            lbl = card_label(c)
            plan = agent_prelude._try_projection(board, [[c]])
            if plan is not None:
                print(f"  singleton {lbl}: plan found "
                      f"({len(plan)} step{'s' if len(plan) != 1 else ''})")
            else:
                print(f"  singleton {lbl}: no plan")

        print()

        # Capture snapshots BEFORE modifying hand/board.
        hand_snapshot = list(hand)
        board_snapshot = [list(s) for s in board]

        result = agent_prelude.find_play(hand, board)

        # Record for DSL output.
        dsl_records.append((f"turn_{turn}_hint", hand_snapshot, board_snapshot, result))

        if result is not None:
            placements = result["placements"]
            placement_labels = " ".join(card_label(c) for c in placements)
            print(f"Hint: play [{placement_labels}]")
            for i, step in enumerate(agent_prelude.format_hint(result), 1):
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
