"""
LynRummy Elm client — Python library + CLI for the
/gopher/lynrummy-elm/* endpoints.

Surface mirrors the Elm client's wire interactions. Each Elm
commit* function has a matching Python method.

Example:

    from client import Client
    c = Client()
    sid = c.new_session()
    print(c.get_state(sid))
    c.send_split(sid, stack_index=0, card_index=2)
    print(c.get_state(sid))
"""

import json
import sys
import urllib.request
import urllib.error


DEFAULT_BASE = "http://localhost:9000/gopher/lynrummy-elm"


class Client:
    """Thin HTTP wrapper for the LynRummy Elm wire endpoints."""

    def __init__(self, base=DEFAULT_BASE):
        self.base = base.rstrip("/")

    # --- Session lifecycle ---

    def new_session(self):
        """POST /new-session → returns integer session id."""
        resp = self._post(f"{self.base}/new-session", b"")
        return resp["session_id"]

    # --- Action submission (one method per WireAction constructor) ---

    def send_action(self, session_id, action):
        """POST /actions?session=<id> with the given WireAction body."""
        body = json.dumps(action).encode("utf-8")
        return self._post(
            f"{self.base}/actions?session={session_id}",
            body,
            content_type="application/json",
        )

    def send_split(self, session_id, *, stack_index, card_index):
        return self.send_action(
            session_id,
            {"action": "split", "stack_index": stack_index, "card_index": card_index},
        )

    def send_merge_stack(self, session_id, *, source_stack, target_stack, side):
        _check_side(side)
        return self.send_action(
            session_id,
            {
                "action": "merge_stack",
                "source_stack": source_stack,
                "target_stack": target_stack,
                "side": side,
            },
        )

    def send_merge_hand(self, session_id, *, hand_card, target_stack, side):
        _check_side(side)
        return self.send_action(
            session_id,
            {
                "action": "merge_hand",
                "hand_card": hand_card,
                "target_stack": target_stack,
                "side": side,
            },
        )

    def send_place_hand(self, session_id, *, hand_card, loc):
        return self.send_action(
            session_id,
            {"action": "place_hand", "hand_card": hand_card, "loc": loc},
        )

    def send_move_stack(self, session_id, *, stack_index, new_loc):
        return self.send_action(
            session_id,
            {"action": "move_stack", "stack_index": stack_index, "new_loc": new_loc},
        )

    def send_draw(self, session_id):
        return self.send_action(session_id, {"action": "draw"})

    def send_discard(self, session_id, *, hand_card):
        return self.send_action(
            session_id, {"action": "discard", "hand_card": hand_card}
        )

    def send_complete_turn(self, session_id):
        return self.send_action(session_id, {"action": "complete_turn"})

    def send_undo(self, session_id):
        return self.send_action(session_id, {"action": "undo"})

    def send_play_trick(self, session_id, *, trick_id, hand_cards):
        """Send a play_trick action.

        Server resolves it at submission time via the Go TrickBag
        (FindPlay + Apply) and persists the expanded TrickResult
        diff — so replay doesn't need to know about tricks.

        hand_cards is a list of Card dicts (use card() to build them).
        """
        return self.send_action(
            session_id,
            {"action": "play_trick", "trick_id": trick_id, "hand_cards": hand_cards},
        )

    # --- Queries ---

    def get_state(self, session_id):
        """GET /sessions/<id>/state → reconstructed board + hand."""
        return self._get(f"{self.base}/sessions/{session_id}/state")

    def get_score(self, session_id):
        """GET /sessions/<id>/score → board_score + hand_size + per_stack breakdown."""
        return self._get(f"{self.base}/sessions/{session_id}/score")

    def get_hints(self, session_id):
        """GET /sessions/<id>/hints → every legal merge available now.

        Returns {"base_score", "hand_merges":[Hint...], "stack_merges":[Hint...]}.
        Each Hint has kind, target_stack, side, result_score, trick_id,
        plus either hand_card (for hand_merges) or source_stack
        (for stack_merges).
        """
        return self._get(f"{self.base}/sessions/{session_id}/hints")

    def get_turn_log(self, session_id):
        """GET /sessions/<id>/turn-log → per-turn action history.

        Returns {"turns":[{turn_index, actions, score_before, score_after,
        cards_played, turn_bonus}, ...]}. Each action carries its seq,
        kind, score_after, and (for hand merges / place_hand) the
        detected trick_id. Uses raw log — undone moves still appear.
        """
        return self._get(f"{self.base}/sessions/{session_id}/turn-log")

    # --- HTTP helpers ---

    def _get(self, url):
        req = urllib.request.Request(url, method="GET")
        return _do(req)

    def _post(self, url, body, content_type=None):
        req = urllib.request.Request(url, data=body, method="POST")
        if content_type:
            req.add_header("Content-Type", content_type)
        return _do(req)


def _do(req):
    try:
        with urllib.request.urlopen(req) as resp:
            data = resp.read()
            if not data:
                return {}
            return json.loads(data)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{req.method} {req.full_url} → {e.code}: {body}") from e


def _check_side(side):
    if side not in ("left", "right"):
        raise ValueError(f"side must be 'left' or 'right', got {side!r}")


# --- Card-label convenience ---

_VALUES = {
    "A": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7,
    "8": 8, "9": 9, "T": 10, "J": 11, "Q": 12, "K": 13,
}
_SUITS = {"C": 0, "D": 1, "S": 2, "H": 3}


def card(label, deck=0):
    """Build a WireAction-shaped Card dict from a 2-char label.

    card("7H") → {"value": 7, "suit": 3, "origin_deck": 0}
    """
    if len(label) != 2:
        raise ValueError(f"expected 2-char label, got {label!r}")
    v, s = label[0].upper(), label[1].upper()
    return {"value": _VALUES[v], "suit": _SUITS[s], "origin_deck": deck}


def find_stack_containing(state, label, deck=0):
    """Return the index of the stack containing the given card, or
    None if absent. Wire indices are positional within the board
    list, which shifts as stacks get split/merged/removed — scripted
    players should re-query state before each action instead of
    assuming stale indices.
    """
    target = card(label, deck)
    for i, stack in enumerate(state["state"]["board"]):
        for bc in stack["board_cards"]:
            if bc["card"] == target:
                return i
    return None


# --- Demo ---


def demo():
    """Prints a short end-to-end trace for sanity-checking the pipeline.

    Note on indices: wire actions carry positional stack indices
    relative to the board list at the moment they're emitted. After
    a mutation (split / merge / place / move), indices shift. A
    scripted player should re-query state and re-find stacks by
    content between actions — see find_stack_containing.
    """
    c = Client()
    sid = c.new_session()
    print(f"new session: {sid}")

    state = c.get_state(sid)
    score = c.get_score(sid)
    print(f"initial: {len(state['state']['board'])} stacks, "
          f"{len(state['state']['hand']['hand_cards'])} hand cards, "
          f"score={score['board_score']}")

    # Merge 7H from the hand onto the 7S,7D,7C set. Find the 7S stack
    # by content. Hand cards use DeckTwo (deck=1) to avoid collision
    # with board cards in DeckOne.
    seven_set_idx = find_stack_containing(state, "7S")
    print(f"7-set is at stack index {seven_set_idx}")
    c.send_merge_hand(
        sid, hand_card=card("7H", deck=1), target_stack=seven_set_idx, side="right"
    )
    state = c.get_state(sid)
    score = c.get_score(sid)
    print(f"after merge_hand 7H: {len(state['state']['board'])} stacks, "
          f"{len(state['state']['hand']['hand_cards'])} hand cards, "
          f"score={score['board_score']}, seq={state['seq']}")

    # Now split the first spade run (KS,AS,2S,3S). Index may have
    # shifted from the merge — re-find it.
    state = c.get_state(sid)
    spade_run_idx = find_stack_containing(state, "KS")
    print(f"spade run is at stack index {spade_run_idx}")
    c.send_split(sid, stack_index=spade_run_idx, card_index=2)
    state = c.get_state(sid)
    score = c.get_score(sid)
    print(f"after split: {len(state['state']['board'])} stacks, "
          f"score={score['board_score']}, seq={state['seq']}")

    print(f"browse: http://localhost:9000/gopher/lynrummy-elm/sessions/{sid}")


if __name__ == "__main__":
    try:
        demo()
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
