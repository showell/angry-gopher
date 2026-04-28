"""
mine_puzzles.py — generate fresh Puzzles entries in
the 3-5-line difficulty band and write them to the
mined-seeds JSON file.

Pipeline:
  1. Run agent_game.py --offline in-process to capture
     gameplay snapshots (board + projection cards). Each
     snapshot is a real-world state the agent encountered.
  2. For each (board, projected hand cards), augment the
     board with the projection and run bfs.solve.
  3. Filter to plans of length 3-5. Dedup by board signature.
  4. Overwrite `games/lynrummy/conformance/mined_seeds.json`
     with the kept puzzles, keyed by `puzzle_name` like
     `mined_<value-suit-deck>_<seq>`.
  5. Print a summary so the Puzzles UI integration step knows
     what's available.

The puzzle-as-presented-to-the-player has the projected
cards back in the hand (not as a board singleton). Player
must place + plan; the agent_solution is the BFS plan over
the augmented board.

Usage:
    python3 tools/mine_puzzles.py [--target N]
        [--max-actions N] [--dry-run]
"""

import argparse
import json
import sys
from pathlib import Path

REPO = Path("/home/steve/showell_repos/angry-gopher")
sys.path.insert(0, str(REPO / "games/lynrummy/python"))

import bfs  # noqa: E402
import geometry  # noqa: E402

SEEDS_PATH = REPO / "games/lynrummy/conformance/mined_seeds.json"


def board_signature(board):
    """Stable canonicalization for dedup."""
    return json.dumps(sorted(sorted(stack) for stack in board))


def card_label(value, suit, deck):
    ranks = "A23456789TJQK"
    suits = "CDSH"
    return ranks[value - 1] + suits[suit] + (f":{deck}" if deck else "")


def collect_projections(num_games, max_actions):
    """Run agent_game.py --offline and capture projections.
    Returns list of (board, hand_cards, plan) where plan is
    None if BFS fails."""
    import agent_game  # noqa
    import json as _json
    import tempfile

    snapshots = []
    for game_idx in range(num_games):
        with tempfile.NamedTemporaryFile(
                mode="w", suffix=".jsonl", delete=False) as tmp:
            tmp_path = tmp.name
        # Use subprocess to avoid stateful agent_game globals.
        import subprocess
        subprocess.run(
            ["python3", str(REPO / "games/lynrummy/python/agent_game.py"),
             "--offline", "--max-actions", str(max_actions),
             "--capture", tmp_path,
             "--label", f"mine-puzzles game {game_idx + 1}"],
            cwd=str(REPO / "games/lynrummy/python"),
            check=False, capture_output=True)
        for line in Path(tmp_path).read_text().splitlines():
            if not line.strip():
                continue
            snapshots.append(_json.loads(line))
        Path(tmp_path).unlink()
        print(f"  game {game_idx + 1}/{num_games}: "
              f"{len(snapshots)} snapshots so far")
    return snapshots


def evaluate_projection(rec, proj):
    """Run BFS over the augmented board. Return
    (plan_lines, augmented_board, hand_card_tuples) or
    (None, ...) if no plan or wrong length."""
    board = [[tuple(c) for c in s] for s in rec["board"]]
    hand_card_tuples = [tuple(c) for c in proj["cards"]]
    augmented = board + [list(hand_card_tuples)]
    plan = bfs.solve(augmented, max_trouble_outer=10,
                     max_states=200000, verbose=False)
    return plan, board, hand_card_tuples


def _laid_out_stacks(stacks):
    """Assign each stack a non-overlapping loc via the canonical
    Python placer. Iterative: each call to `find_open_loc` sees
    only the stacks placed so far, so the layout is the same
    column-major pack a human-style auto-player would produce
    on an empty board.

    The captured-projection's source board already had locs from
    its original game, but those reflect mid-game packing of a
    larger position. For a puzzle we want a fresh, human-feel
    layout starting from an empty canvas — `find_open_loc`
    delivers that.
    """
    placed = []
    for stack in stacks:
        wire_stack = {
            "board_cards": [
                {"card": {"value": c[0], "suit": c[1],
                          "origin_deck": c[2]},
                 "state": 0}
                for c in stack
            ],
            "loc": geometry.find_open_loc(placed, len(stack)),
        }
        placed.append(wire_stack)
    return placed


def build_initial_state(board, hand_cards):
    """Build the wire-shape `lynrummy.State` for the puzzle.

    Steve's 2026-04-26 framing: a puzzle is purely board-as-
    problem. The "hand cards" from the captured projection
    are placed onto the board as a singleton (or pair) stack,
    so the player faces a board with trouble cards to clean
    up. The hand is empty.

    Stacks are laid out via `geometry.find_open_loc` so the
    persisted state ships with non-overlapping, human-feel
    locs. Without this every stack would land at (0,0).
    """
    augmented_board = list(board)
    if hand_cards:
        augmented_board.append(list(hand_cards))
    return {
        "board": _laid_out_stacks(augmented_board),
        "hands": [
            {"hand_cards": []},
            {"hand_cards": []},
        ],
        "deck": [],
        "discard": [],
        "active_player_index": 0,
        "scores": [0, 0],
        "victor_awarded": False,
        "turn_start_board_score": 0,
        "turn_index": 0,
        "cards_played_this_turn": 0,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--target", type=int, default=25,
                    help="number of puzzles to mine (default 25)")
    ap.add_argument("--num-games", type=int, default=8,
                    help="offline games to play to source snapshots")
    ap.add_argument("--max-actions", type=int, default=120,
                    help="actions per offline game")
    ap.add_argument("--min-depth", type=int, default=3)
    ap.add_argument("--max-depth", type=int, default=5)
    ap.add_argument("--out", default=str(SEEDS_PATH),
                    help="seeds JSON to overwrite")
    ap.add_argument("--dry-run", action="store_true",
                    help="don't write; just print what would be persisted")
    args = ap.parse_args()

    print(f"=== Mining puzzles (target {args.target}, "
          f"depth {args.min_depth}-{args.max_depth}) ===\n")
    print("Phase 1: capture offline snapshots...")
    snapshots = collect_projections(args.num_games, args.max_actions)
    print(f"  total snapshots: {len(snapshots)}\n")

    print("Phase 2: filter for 3-5 line plans, dedup boards...")
    seen_boards = set()
    kept = []
    for snap in snapshots:
        for proj in snap.get("projections", []):
            if not proj["found_plan"]:
                continue
            plan, board, hand = evaluate_projection(snap, proj)
            if plan is None:
                continue
            if not (args.min_depth <= len(plan) <= args.max_depth):
                continue
            sig = board_signature(board + [list(hand)])
            if sig in seen_boards:
                continue
            seen_boards.add(sig)
            kept.append((board, hand, plan))
            if len(kept) >= args.target:
                break
        if len(kept) >= args.target:
            break
    print(f"  kept: {len(kept)}\n")

    if not kept:
        print("No puzzles in target band. Try --num-games higher.")
        return

    print(f"Phase 3: write seeds to {args.out}...")
    seeds = []
    seq = 0
    for board, hand, plan in kept:
        seq += 1
        hand_label = "_".join(
            card_label(*c).replace(":", "p") for c in hand)
        puzzle_name = f"mined_{seq:03d}_{hand_label}"
        initial_state = build_initial_state(board, hand)
        seeds.append({
            "puzzle_name": puzzle_name,
            "initial_state": initial_state,
        })
        print(f"  {puzzle_name}: {len(plan)} lines, hand={hand_label}")

    if args.dry_run:
        print(f"\nDone. {len(kept)} puzzles planned (dry-run; "
              f"file not written).")
        return

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        json.dump({"seeds": seeds}, f, indent=2)
        f.write("\n")
    print(f"\nDone. wrote {len(seeds)} seeds to {out_path}.")


if __name__ == "__main__":
    main()
