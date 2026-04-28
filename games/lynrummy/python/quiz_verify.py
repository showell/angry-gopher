#!/usr/bin/env python3
"""quiz_verify — structural check for the agent-orientation quiz.

Verifies that a JSON game produced per QUIZ_AGENT_ORIENTATION.md
is a well-formed Lyn Rummy initial_state. Does NOT pin to a seed —
any valid shuffle passes.

Usage: python3 quiz_verify.py /tmp/quiz_lynrummy_game.json

Exits 0 on success, 1 with a diagnostic on failure.
"""

import json
import sys


EXPECTED_BOARD = [
    [(13, 2, 0), (1, 2, 0), (2, 2, 0), (3, 2, 0)],          # KS AS 2S 3S
    [(10, 1, 0), (11, 1, 0), (12, 1, 0), (13, 1, 0)],        # TD JD QD KD
    [(2, 3, 0), (3, 3, 0), (4, 3, 0)],                       # 2H 3H 4H
    [(7, 2, 0), (7, 1, 0), (7, 0, 0)],                       # 7S 7D 7C
    [(1, 0, 0), (1, 1, 0), (1, 3, 0)],                       # AC AD AH
    [(2, 0, 0), (3, 1, 0), (4, 0, 0), (5, 3, 0),             # 2C 3D 4C 5H
     (6, 2, 0), (7, 3, 0)],                                  # 6S 7H
]


def fail(msg):
    print(f"FAIL: {msg}")
    sys.exit(1)


def card_key(c):
    return (c["value"], c["suit"], c["origin_deck"])


def check_card_shape(c, where):
    for k in ("value", "suit", "origin_deck"):
        if k not in c:
            fail(f"{where}: card missing key {k!r}: {c}")
    if not (1 <= c["value"] <= 13):
        fail(f"{where}: bad value {c['value']}")
    if c["suit"] not in (0, 1, 2, 3):
        fail(f"{where}: bad suit {c['suit']}")
    if c["origin_deck"] not in (0, 1):
        fail(f"{where}: bad origin_deck {c['origin_deck']}")


def main():
    if len(sys.argv) != 2:
        fail("usage: quiz_verify.py <path-to-game.json>")
    path = sys.argv[1]
    try:
        with open(path) as f:
            state = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        fail(f"could not load {path}: {e}")

    for k in ("board", "hands", "deck", "discard", "active_player_index"):
        if k not in state:
            fail(f"top-level key missing: {k!r}")

    # Board: shape matches canonical opening.
    board = state["board"]
    if len(board) != 6:
        fail(f"board has {len(board)} stacks, expected 6")
    for i, (stack, expected) in enumerate(zip(board, EXPECTED_BOARD)):
        cards = stack.get("board_cards") or []
        if len(cards) != len(expected):
            fail(f"board stack {i}: {len(cards)} cards, expected {len(expected)}")
        for j, (bc, exp) in enumerate(zip(cards, expected)):
            c = bc.get("card") or {}
            check_card_shape(c, f"board[{i}][{j}]")
            if card_key(c) != exp:
                fail(f"board[{i}][{j}]: {card_key(c)} != expected {exp}")

    # Hands: 2 × 15.
    hands = state["hands"]
    if len(hands) != 2:
        fail(f"{len(hands)} hands, expected 2")
    for hi, hand in enumerate(hands):
        hc = hand.get("hand_cards") or []
        if len(hc) != 15:
            fail(f"hand {hi}: {len(hc)} cards, expected 15")
        for j, hc_entry in enumerate(hc):
            check_card_shape(hc_entry.get("card") or {}, f"hands[{hi}][{j}]")

    # Deck.
    deck = state["deck"]
    if not isinstance(deck, list):
        fail("deck is not a list")
    for j, c in enumerate(deck):
        check_card_shape(c, f"deck[{j}]")

    # Discard (allowed empty).
    discard = state["discard"]
    if not isinstance(discard, list):
        fail("discard is not a list")
    for j, c in enumerate(discard):
        check_card_shape(c, f"discard[{j}]")

    # Total = 104, no dupes by (value, suit, origin_deck).
    all_cards = []
    for stack in board:
        for bc in stack["board_cards"]:
            all_cards.append(bc["card"])
    for hand in hands:
        for hc in hand["hand_cards"]:
            all_cards.append(hc["card"])
    all_cards.extend(deck)
    all_cards.extend(discard)

    if len(all_cards) != 104:
        fail(f"total cards = {len(all_cards)}, expected 104")
    keys = [card_key(c) for c in all_cards]
    if len(set(keys)) != 104:
        from collections import Counter
        dupes = [k for k, n in Counter(keys).items() if n > 1]
        fail(f"duplicate cards: {dupes[:5]}{'...' if len(dupes) > 5 else ''}")

    if state["active_player_index"] not in (0, 1):
        fail(f"active_player_index = {state['active_player_index']}")

    print("OK: well-formed Lyn Rummy initial_state "
          f"(deck={len(deck)}, discard={len(discard)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
