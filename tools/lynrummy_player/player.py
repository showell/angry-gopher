#!/usr/bin/env python3
"""
LynRummy console player — talks to the Angry Gopher game host via HTTP.

Tracks board and hand state by polling game events. Can send moves
as any authenticated player. Used for spectating, advising, and
playing via the command line.

Usage:
    python3 player.py --game-id 1 --email EMAIL --api-key KEY [--host URL]
"""

import argparse
import base64
import json
import sys
import urllib.request

# --- Card types and display ---

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


def make_card(value, suit, origin_deck=0):
    """Build a card dict."""
    return {"value": value, "suit": suit, "origin_deck": origin_deck}


def cards_equal(a, b):
    """Card identity: value + suit + origin_deck."""
    return (a["value"] == b["value"] and
            a["suit"] == b["suit"] and
            a["origin_deck"] == b["origin_deck"])


def show_hand(name, hand):
    """Print a hand organized by suit (H, S, D, C order)."""
    print(f"{name}:")
    for suit in SUIT_ORDER:
        suit_cards = [c for c in hand if c["suit"] == suit]
        suit_cards.sort(key=lambda c: c["value"])
        if suit_cards:
            label = SUIT_NAMES[suit]
            cards = " ".join(card_str(c) for c in suit_cards)
            print(f"  {label}: {cards}")
    print()


def board_fingerprint(board):
    """Compact board string matching Angry Cat and Gopher format."""
    parts = []
    for stack in board:
        cards = " ".join(card_str(bc["card"]) for bc in stack["board_cards"])
        loc = stack["loc"]
        parts.append(f"({loc['left']},{loc['top']}) [{cards}]")
    return " | ".join(parts)


def show_board(board):
    """Print all stacks on the board."""
    if not board:
        print("Board: (empty)")
        return
    print(f"Board ({len(board)} stacks):")
    for i, stack in enumerate(board):
        cards = " ".join(card_str(bc["card"]) for bc in stack["board_cards"])
        loc = stack["loc"]
        print(f"  [{i}] ({loc['left']:.1f}, {loc['top']:.1f}) {cards}")
    print()


# --- Stack helpers ---

def make_board_card(card, state=0):
    """Wrap a card as a board card with a state."""
    return {"card": card, "state": state}


def make_stack(board_cards, loc):
    """Build a stack dict."""
    return {"board_cards": board_cards, "loc": loc}


def stack_cards(stack):
    """Extract the raw cards from a stack."""
    return [bc["card"] for bc in stack["board_cards"]]


def stacks_match(a, b):
    """Check if two stacks match (same cards in order, same location).

    Card state is ignored for matching — only value, suit, origin_deck
    and exact location matter. Locations are compared as-is (floats).
    """
    if len(a["board_cards"]) != len(b["board_cards"]):
        return False
    for ac, bc in zip(a["board_cards"], b["board_cards"]):
        if not cards_equal(ac["card"], bc["card"]):
            return False
    la, lb = a["loc"], b["loc"]
    return la["top"] == lb["top"] and la["left"] == lb["left"]


def find_board_stack(board, stack):
    """Find the index of a matching stack on the board, or -1."""
    for i, bs in enumerate(board):
        if stacks_match(bs, stack):
            return i
    return -1


def find_stack_by_cards(board, card_tuples):
    """Find a board stack whose cards match the given (value, suit, deck) tuples.

    Returns the stack dict, or None. This is safer than using board
    indices, which shift as moves are applied.
    """
    for stack in board:
        stack_cards = [(bc["card"]["value"], bc["card"]["suit"], bc["card"]["origin_deck"])
                       for bc in stack["board_cards"]]
        if stack_cards == card_tuples:
            return stack
    return None


# --- Dealer setup ---
#
# The dealer pulls initial board stacks from the deck (all deck 1),
# then deals 15 cards from the front to each player.

INITIAL_BOARD_SIGS = [
    "KS,AS,2S,3S",
    "TD,JD,QD,KD",
    "2H,3H,4H",
    "7S,7D,7C",
    "AC,AD,AH",
    "2C,3D,4C,5H,6S,7H",
]

LABEL_TO_CARD = {}
for v, vn in VALUE_NAMES.items():
    for s, sn in SUIT_NAMES.items():
        LABEL_TO_CARD[f"{vn}{sn}"] = {"value": v, "suit": s}


def board_location(row):
    """Compute initial board stack location from row index."""
    col = (row * 3 + 1) % 5
    return {"top": 20 + row * 60, "left": 40 + col * 30}


def pull_board_cards_from_deck(deck):
    """Remove initial board cards from deck.

    Returns (board_stacks, remaining_deck).
    """
    remaining = list(deck)
    board = []

    for row, sig in enumerate(INITIAL_BOARD_SIGS):
        board_cards = []
        for label in sig.split(","):
            proto = LABEL_TO_CARD[label]
            card = make_card(proto["value"], proto["suit"], origin_deck=0)
            # Search and remove from deck.
            for i, dc in enumerate(remaining):
                if cards_equal(dc, card):
                    remaining.pop(i)
                    break
            board_cards.append(make_board_card(card, state=0))

        board.append(make_stack(board_cards, board_location(row)))

    return board, remaining


def deal_hands(deck, hand_size=15):
    """Deal from the front of the deck."""
    p1_hand = deck[:hand_size]
    rest = deck[hand_size:]
    p2_hand = rest[:hand_size]
    rest = rest[hand_size:]
    return p1_hand, p2_hand, rest


# --- HTTP client ---

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
#
# These build the exact JSON payloads that Angry Cat expects.
# The addr field must be the sender's user ID as a string.

def make_event_row(addr, board_event, hand_cards=None):
    """Build the full EventRow payload."""
    hand_cards_to_release = []
    if hand_cards:
        for c in hand_cards:
            hand_cards_to_release.append(make_board_card(c, state=0))

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


def make_board_event(stacks_to_remove, stacks_to_add):
    """Build a board_event from remove/add lists."""
    return {
        "stacks_to_remove": stacks_to_remove,
        "stacks_to_add": stacks_to_add,
    }


# --- Move helpers ---
#
# High-level operations that build board_events for common plays.

def move_stack_event(stack, new_loc):
    """Move a stack to a new location (pure rearrangement)."""
    moved = make_stack(stack["board_cards"], new_loc)
    return make_board_event([stack], [moved])


def extend_stack_right_event(stack, hand_card):
    """Add a card from hand to the right end of a stack."""
    new_board_cards = list(stack["board_cards"])
    new_board_cards.append(make_board_card(hand_card, state=1))
    new_stack = make_stack(new_board_cards, stack["loc"])
    return make_board_event([stack], [new_stack])


def extend_stack_left_event(stack, hand_card):
    """Add a card from hand to the left end of a stack."""
    new_board_cards = [make_board_card(hand_card, state=1)]
    new_board_cards.extend(stack["board_cards"])
    new_stack = make_stack(new_board_cards, stack["loc"])
    return make_board_event([stack], [new_stack])


def place_new_stack_event(hand_cards, loc):
    """Place cards from hand as a new stack on the board."""
    board_cards = [make_board_card(c, state=1) for c in hand_cards]
    new_stack = make_stack(board_cards, loc)
    return make_board_event([], [new_stack])


def split_stack_event(stack, split_at, left_loc, right_loc):
    """Split a stack into two at the given card index."""
    left_cards = stack["board_cards"][:split_at]
    right_cards = stack["board_cards"][split_at:]
    left_stack = make_stack(left_cards, left_loc)
    right_stack = make_stack(right_cards, right_loc)
    return make_board_event([stack], [left_stack, right_stack])


# --- Game state tracker ---

class GameState:
    def __init__(self, setup_event):
        payload = setup_event["payload"]

        if "game_setup" in payload:
            # New format: the "photo" from the dealer.
            setup = payload["game_setup"]
            self.board = setup["board"]
            self.hands = [setup["hands"][0], setup["hands"][1]]
            self.remaining_deck = setup["deck"]
        elif "deck" in payload:
            # Legacy format: raw shuffled deck, dealer runs locally.
            raw_deck = payload["deck"]
            initial_board, remaining = pull_board_cards_from_deck(raw_deck)
            p1_hand, p2_hand, self.remaining_deck = deal_hands(remaining)
            self.board = initial_board
            self.hands = [p1_hand, p2_hand]
        else:
            raise ValueError("First event must be game_setup or deck")

        self.last_event_id = setup_event["id"]
        print(f"[board] python setup: {board_fingerprint(self.board)}")

    def apply_event(self, event):
        """Apply a game event to the board. Skips invalid moves."""
        self.last_event_id = event["id"]

        payload = event["payload"]
        if "json_game_event" not in payload:
            return

        ge = payload["json_game_event"]
        if ge["type"] != 2 or ge.get("player_action") is None:
            return

        be = ge["player_action"]["board_event"]
        to_remove = be["stacks_to_remove"]
        to_add = be["stacks_to_add"]

        # Validate all removes before applying.
        indices_to_remove = []
        for rem in to_remove:
            found = False
            for i, bs in enumerate(self.board):
                if i not in indices_to_remove and stacks_match(bs, rem):
                    indices_to_remove.append(i)
                    found = True
                    break
            if not found:
                return  # invalid move — skip

        for i in sorted(indices_to_remove, reverse=True):
            self.board.pop(i)

        for add in to_add:
            self.board.append(add)

    def show(self, player_index):
        show_board(self.board)
        show_hand("Player 1 hand", self.hands[0])
        show_hand("Player 2 hand", self.hands[1])
        print(f"Deck: {len(self.remaining_deck)} cards remaining")

    def send_move(self, client, game_id, addr, board_event, hand_cards=None):
        """Send a move to the host and apply it locally."""
        print(f"[board] python before move: {board_fingerprint(self.board)}")
        payload = make_event_row(addr, board_event, hand_cards)
        result = client.post_event(game_id, payload)
        event_id = result.get("event_id")
        if event_id:
            print(f"Sent event {event_id}")
            # Apply locally by constructing a fake event.
            fake_event = {
                "id": event_id,
                "payload": payload,
            }
            self.apply_event(fake_event)
        return result


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
    player_index = args.player - 1

    result = client.get_events(args.game_id)
    events = result.get("events", [])

    if not events:
        print("No events yet — waiting for game to start.")
        return

    state = GameState(events[0])
    for event in events[1:]:
        state.apply_event(event)

    state.show(player_index)


if __name__ == "__main__":
    main()
