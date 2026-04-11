#!/usr/bin/env python3
"""
LynRummy console player — talks to the Angry Gopher game host via HTTP.

This is a spectating/playing tool, not a UI. It polls game events,
tracks board and hand state, and can send moves via curl-style HTTP.

Usage:
    python3 player.py --game-id 1 --email EMAIL --api-key KEY [--host URL]
"""

import argparse
import base64
import json
import sys
import urllib.request

# --- Card display ---

SUIT_NAMES = {0: "C", 1: "D", 2: "S", 3: "H"}
VALUE_NAMES = {
    1: "A", 2: "2", 3: "3", 4: "4", 5: "5", 6: "6", 7: "7",
    8: "8", 9: "9", 10: "T", 11: "J", 12: "Q", 13: "K",
}
SUIT_ORDER = [3, 2, 1, 0]  # H, S, D, C


def card_str(card):
    """Short label like 'AH:1' (Ace of Hearts, deck 1)."""
    v = VALUE_NAMES[card["value"]]
    s = SUIT_NAMES[card["suit"]]
    d = card["origin_deck"] + 1
    return f"{v}{s}:{d}"


def show_hand(name, hand):
    """Print a hand organized by suit."""
    print(f"{name}:")
    for suit in SUIT_ORDER:
        suit_cards = [c for c in hand if c["suit"] == suit]
        suit_cards.sort(key=lambda c: c["value"])
        if suit_cards:
            label = SUIT_NAMES[suit]
            cards = " ".join(card_str(c) for c in suit_cards)
            print(f"  {label}: {cards}")
    print()


def show_board(board):
    """Print all stacks on the board."""
    if not board:
        print("Board: (empty)")
        return
    print(f"Board ({len(board)} stacks):")
    for i, stack in enumerate(board):
        cards = " ".join(card_str(bc["card"]) for bc in stack["board_cards"])
        loc = stack["loc"]
        print(f"  [{i}] ({loc['left']:.0f}, {loc['top']:.0f}) {cards}")
    print()


# --- Initial board setup ---
# These cards are pulled from the deck (always deck 1) before dealing.

INITIAL_BOARD_SIGS = [
    ("KS,AS,2S,3S", 0),
    ("TD,JD,QD,KD", 1),
    ("2H,3H,4H", 2),
    ("7S,7D,7C", 3),
    ("AC,AD,AH", 4),
    ("2C,3D,4C,5H,6S,7H", 5),
]

LABEL_TO_CARD = {}
for v, vn in VALUE_NAMES.items():
    for s, sn in SUIT_NAMES.items():
        LABEL_TO_CARD[f"{vn}{sn}"] = {"value": v, "suit": s}


def parse_board_sig(sig):
    """Parse 'KS,AS,2S,3S' into a list of cards (all deck 1)."""
    cards = []
    for label in sig.split(","):
        c = dict(LABEL_TO_CARD[label])
        c["origin_deck"] = 0  # always deck 1
        cards.append(c)
    return cards


def board_location(row):
    """Compute initial board stack location from row index."""
    col = (row * 3 + 1) % 5
    return {"top": 20 + row * 60, "left": 40 + col * 30}


def pull_board_cards_from_deck(deck):
    """Remove initial board cards from deck, return (board_stacks, remaining_deck)."""
    remaining = list(deck)
    board = []

    for sig, row in INITIAL_BOARD_SIGS:
        cards = parse_board_sig(sig)
        board_cards = []
        for c in cards:
            # Search and remove from deck (matching value, suit, origin_deck)
            for i, dc in enumerate(remaining):
                if (dc["value"] == c["value"] and
                    dc["suit"] == c["suit"] and
                    dc["origin_deck"] == c["origin_deck"]):
                    remaining.pop(i)
                    break
            board_cards.append({"card": c, "state": 0})

        board.append({
            "board_cards": board_cards,
            "loc": board_location(row),
        })

    return board, remaining


def deal_hands(deck, hand_size=15):
    """Deal from the front of the deck."""
    p1_hand = deck[:hand_size]
    rest = deck[hand_size:]
    p2_hand = rest[:hand_size]
    rest = rest[hand_size:]
    return p1_hand, p2_hand, rest


# --- HTTP helpers ---

class GopherClient:
    def __init__(self, host, email, api_key):
        self.host = host.rstrip("/")
        creds = f"{email}:{api_key}"
        self.auth = "Basic " + base64.b64encode(creds.encode()).decode()

    def _request(self, method, path, data=None):
        url = f"{self.host}/gopher/{path}"
        body = json.dumps(data).encode() if data else None
        headers = {"Authorization": self.auth}
        if body:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())

    def get_events(self, game_id, after=0):
        return self._request("GET", f"games/{game_id}/events?after={after}")

    def post_event(self, game_id, payload):
        return self._request("POST", f"games/{game_id}/events", payload)

    def list_games(self):
        return self._request("GET", "games")

    def join_game(self, game_id):
        return self._request("POST", f"games/{game_id}/join")


# --- Move construction ---

def make_event_row(addr, board_event, hand_cards=None):
    """Build the full event payload that Angry Cat expects."""
    hand_cards_to_release = []
    if hand_cards:
        for c in hand_cards:
            hand_cards_to_release.append({"card": c, "state": 0})

    return {
        "json_game_event": {
            "type": 2,  # PLAYER_ACTION
            "player_action": {
                "board_event": board_event,
                "hand_cards_to_release": hand_cards_to_release,
            },
        },
        "addr": str(addr),
    }


def make_move_stack(stacks_to_remove, stacks_to_add):
    """Build a board_event from remove/add lists."""
    return {
        "stacks_to_remove": stacks_to_remove,
        "stacks_to_add": stacks_to_add,
    }


def move_stack(stack, new_loc):
    """Create a board_event that moves a stack to a new location."""
    moved = dict(stack)
    moved["loc"] = new_loc
    return make_move_stack([stack], [moved])


# --- Game state tracker ---

class GameState:
    def __init__(self, deck_event):
        raw_deck = deck_event["payload"]["deck"]
        self.initial_board, remaining = pull_board_cards_from_deck(raw_deck)
        p1_hand, p2_hand, self.deck = deal_hands(remaining)
        self.hands = [p1_hand, p2_hand]
        # Board tracks current state — starts with initial stacks.
        self.board = [dict(s) for s in self.initial_board]

    def apply_event(self, event):
        payload = event["payload"]
        if "json_game_event" not in payload:
            return  # deck event or other non-game event

        ge = payload["json_game_event"]
        if ge["type"] != 2:  # not a player action
            return
        if ge.get("player_action") is None:
            return

        be = ge["player_action"]["board_event"]
        to_remove = be["stacks_to_remove"]
        to_add = be["stacks_to_add"]

        # Remove matching stacks. If any remove doesn't match,
        # the whole move is invalid (same as the referee).
        indices_to_remove = []
        valid = True
        for rem in to_remove:
            found = False
            for i, bs in enumerate(self.board):
                if i not in indices_to_remove and stacks_match(bs, rem):
                    indices_to_remove.append(i)
                    found = True
                    break
            if not found:
                valid = False
                break

        if not valid:
            return  # skip this event — referee would reject it

        # Remove in reverse order to preserve indices.
        for i in sorted(indices_to_remove, reverse=True):
            self.board.pop(i)

        # Add new stacks.
        for add in to_add:
            self.board.append(add)

    def show(self, my_player_index):
        show_board(self.board)
        show_hand("My hand", self.hands[my_player_index])


def stacks_match(a, b):
    """Check if two stacks match (same cards in order, same location)."""
    if len(a["board_cards"]) != len(b["board_cards"]):
        return False
    for ac, bc in zip(a["board_cards"], b["board_cards"]):
        ca, cb = ac["card"], bc["card"]
        if (ca["value"] != cb["value"] or
            ca["suit"] != cb["suit"] or
            ca["origin_deck"] != cb["origin_deck"]):
            return False
    # Location must match exactly (floats from UI).
    la, lb = a["loc"], b["loc"]
    if la["top"] != lb["top"] or la["left"] != lb["left"]:
        return False
    return True


# --- Main ---

def main():
    parser = argparse.ArgumentParser(description="LynRummy console player")
    parser.add_argument("--game-id", type=int, required=True)
    parser.add_argument("--email", required=True)
    parser.add_argument("--api-key", required=True)
    parser.add_argument("--host", default="http://localhost:9000")
    parser.add_argument("--player", type=int, default=2, help="1 or 2")
    args = parser.parse_args()

    client = GopherClient(args.host, args.email, args.api_key)
    player_index = args.player - 1  # 0-based

    # Fetch all events.
    result = client.get_events(args.game_id)
    events = result.get("events", [])

    if not events:
        print("No events yet — waiting for game to start.")
        return

    # First event should be the deck.
    state = GameState(events[0])

    # Apply all subsequent events.
    for event in events[1:]:
        state.apply_event(event)

    state.show(player_index)


if __name__ == "__main__":
    main()
