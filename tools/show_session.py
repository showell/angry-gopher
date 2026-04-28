#!/usr/bin/env python3
"""show_session — render a Lyn Rummy session's data in DSL form.

Cards display as DSL shorthand: rank+suit (e.g. `KS`, `7H`,
`AC`) with a trailing `'` for deck 2 (e.g. `8C'`). Stacks
display one per row. This is the format Steve uses when
debugging by ear; never display cards as JSON envelopes when
talking to him about gameplay.

Usage:
    python3 tools/show_session.py <session_id>

Example output:
    === session 9 === label='' created_at=1777394809
    initial_state:
      board:
        KS AS 2S 3S
        TD JD QD KD
        2H 3H 4H
        7S 7D 7C
        AC AD AH
        2C 3D 4C 5H 6S 7H
      hand[0] (15 cards): 8C' 9D KH ...
      deck: 51 cards remaining
      seq=1: merge_hand 8C' → [2C 3D 4C 5H 6S 7H] right
      seq=2: complete_turn
"""

import json
import sys
from pathlib import Path

REPO = Path("/home/steve/showell_repos/angry-gopher")
SESSIONS = REPO / "games/lynrummy/data/lynrummy-elm/sessions"

RANKS = "A23456789TJQK"
SUITS = "CDSH"


def card_dsl(c):
    """{"value": 8, "suit": 0, "origin_deck": 1} → "8C'"."""
    rank = RANKS[c["value"] - 1]
    suit = SUITS[c["suit"]]
    deck = "'" if c.get("origin_deck", 0) else ""
    return rank + suit + deck


def stack_dsl(stack):
    """A stack {board_cards: [...], loc: ...} → 'KS AS 2S 3S'."""
    return " ".join(card_dsl(bc["card"]) for bc in stack["board_cards"])


def show_initial_state(state, indent="  "):
    print(f"{indent}board:")
    for s in state.get("board", []):
        print(f"{indent}  {stack_dsl(s)}")
    for i, h in enumerate(state.get("hands", [])):
        cards = h.get("hand_cards", [])
        if cards:
            labels = " ".join(card_dsl(hc["card"]) for hc in cards)
            print(f"{indent}hand[{i}] ({len(cards)} cards): {labels}")
        else:
            print(f"{indent}hand[{i}] (empty)")
    deck = state.get("deck", [])
    if deck:
        print(f"{indent}deck: {len(deck)} cards remaining")


def render_action(env):
    """Render one action envelope as a DSL line."""
    a = env["action"]
    if isinstance(a, str):
        return a
    kind = a.get("action") or "?"
    if kind == "complete_turn":
        return "complete_turn"

    parts = [kind]
    if "hand_card" in a:
        parts.append(card_dsl(a["hand_card"]))
    if "source" in a:
        parts.append(f"src=[{stack_dsl(a['source'])}]")
    if "target" in a:
        parts.append(f"→ [{stack_dsl(a['target'])}]")
    if "stack" in a and "card_index" in a:
        parts.append(f"[{stack_dsl(a['stack'])}] @ {a['card_index']}")
    if "side" in a:
        parts.append(f"({a['side']})")
    return " ".join(parts)


def main():
    if len(sys.argv) != 2:
        print("usage: show_session.py <session_id>", file=sys.stderr)
        sys.exit(2)
    sid = sys.argv[1]
    sdir = SESSIONS / sid
    if not sdir.is_dir():
        print(f"no session dir: {sdir}", file=sys.stderr)
        sys.exit(1)

    meta_path = sdir / "meta.json"
    if meta_path.exists():
        meta = json.loads(meta_path.read_text())
        label = meta.get("label", "")
        print(f"=== session {sid} === label={label!r} "
              f"created_at={meta.get('created_at')}")
        if "puzzle_name" in meta:
            print(f"  puzzle_name: {meta['puzzle_name']}")
        if "initial_state" in meta:
            print("initial_state:")
            show_initial_state(meta["initial_state"])

    actions_dir = sdir / "actions"
    if actions_dir.is_dir():
        files = sorted(
            actions_dir.glob("*.json"),
            key=lambda p: int(p.stem) if p.stem.isdigit() else -1,
        )
        for f in files:
            seq = f.stem
            env = json.loads(f.read_text())
            puzzle = env.get("puzzle_name", "")
            tag = f"  [puzzle={puzzle}]" if puzzle else ""
            print(f"  seq={seq}: {render_action(env)}{tag}")


if __name__ == "__main__":
    main()
