#!/usr/bin/env python3
"""show_session — render a Lyn Rummy session's data in DSL form.

Cards display as DSL shorthand: rank+suit (e.g. `KS`, `7H`,
`AC`) with a trailing `'` for deck 2 (e.g. `8C'`). Stacks
display one per row. This is the format Steve uses when
debugging by ear; never display cards as JSON envelopes when
talking to him about gameplay.

Usage:
    python3 tools/show_session.py <session_id>           # full-game
    python3 tools/show_session.py puzzle <session_id>    # puzzle gallery

Full-game sessions live under
games/lynrummy/data/lynrummy-elm/sessions/. Puzzle gallery
sessions live in a separate namespace under
games/lynrummy/data/lynrummy-elm/puzzle-sessions/, with each
puzzle's actions in its own subdir.

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
PUZZLE_SESSIONS = REPO / "games/lynrummy/data/lynrummy-elm/puzzle-sessions"

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


def show_full_game(sid):
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
            print(f"  seq={seq}: {render_action(env)}")


def show_puzzle(sid):
    sdir = PUZZLE_SESSIONS / sid
    if not sdir.is_dir():
        print(f"no puzzle session dir: {sdir}", file=sys.stderr)
        sys.exit(1)

    meta_path = sdir / "meta.json"
    if meta_path.exists():
        meta = json.loads(meta_path.read_text())
        label = meta.get("label", "")
        print(f"=== puzzle session {sid} === label={label!r} "
              f"created_at={meta.get('created_at')}")

    # Per-puzzle subdirs each hold actions/ and annotations/.
    puzzle_dirs = sorted(d for d in sdir.iterdir() if d.is_dir())
    for pdir in puzzle_dirs:
        actions_dir = pdir / "actions"
        annotations_dir = pdir / "annotations"
        n_actions = (
            sum(1 for _ in actions_dir.glob("*.json"))
            if actions_dir.is_dir() else 0
        )
        n_annotations = (
            sum(1 for _ in annotations_dir.glob("*.json"))
            if annotations_dir.is_dir() else 0
        )
        if n_actions == 0 and n_annotations == 0:
            continue
        print(f"  puzzle: {pdir.name}  "
              f"({n_actions} actions, {n_annotations} annotations)")
        if actions_dir.is_dir():
            files = sorted(
                actions_dir.glob("*.json"),
                key=lambda p: int(p.stem) if p.stem.isdigit() else -1,
            )
            for f in files:
                seq = f.stem
                env = json.loads(f.read_text())
                print(f"    seq={seq}: {render_action(env)}")


def main():
    args = sys.argv[1:]
    if len(args) == 1:
        show_full_game(args[0])
    elif len(args) == 2 and args[0] == "puzzle":
        show_puzzle(args[1])
    else:
        print(
            "usage: show_session.py <session_id>\n"
            "       show_session.py puzzle <session_id>",
            file=sys.stderr,
        )
        sys.exit(2)


if __name__ == "__main__":
    main()
