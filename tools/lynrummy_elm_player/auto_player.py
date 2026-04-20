"""
auto_player.py — drive an Elm-backed LynRummy session by
repeatedly taking the FIRST suggestion /hint returns, then
calling complete_turn when no hints remain.

Mirrors a human playing the most obvious trick, not an optimizer.
The /hint endpoint returns trick suggestions in priority order
(simplest first); we just take suggestions[0], POST its action,
repeat.

Usage:
    python3 tools/lynrummy_elm_player/auto_player.py [--session N] [--max-actions N]

If --session is omitted, creates a new session.
"""

import argparse
import datetime
import sys

from client import Client
from geometry import find_open_loc, find_violation, loc_clears_others


# Game termination: deck running out, not a turn_result variant.
# LynRummy doesn't end on "victory" — humans keep playing past
# hand-emptied events; the middle game is the fun part. Real end
# is when the deck is nearly exhausted. See
# project_lynrummy_game_end_condition.md.
DECK_LOW_WATER = 10

# `failure` is the one turn_result that still stops the loop —
# means the server refused a dirty-board complete_turn, which is
# a bug state, not normal play.
TERMINAL_RESULTS = {"failure"}

# Cap per-action settle iterations defensively. In practice one
# violation triggers at most a handful of move_stack actions; a
# runaway loop means a bug, not legitimate work.
MAX_SETTLE_STEPS = 20


def plan_trick_result_locs(c, session_id, action, *, verbose=True):
    """Mutate a trick_result action in place so each new stack in
    stacks_to_add carries a pre-planned location instead of
    dummyLoc. The human algorithm: plan where the new stack will
    sit BEFORE executing; execute with location already decided.

    Without this, stacks land at (0, 0) and the settle pass has
    to clean up, which replay faithfully renders as a robotic
    teleport-then-walk. With this, the trick places once, in the
    right spot.

    Planning is done against the board-after-removals so the new
    stack doesn't conflict with something that's about to vanish.
    Multiple sibling new stacks pack against each other, not
    against dummyLoc collisions.

    No-op for non-trick_result actions.
    """
    if action.get("action") != "trick_result":
        return

    stacks_to_add = action.get("stacks_to_add") or []
    if not stacks_to_add:
        return

    state = c.get_state(session_id)
    board = state["state"]["board"]

    stacks_to_remove = action.get("stacks_to_remove") or []
    planning_board = _board_after_removals(board, stacks_to_remove)
    placed = list(planning_board)

    for i, stack in enumerate(stacks_to_add):
        card_count = len(stack.get("board_cards", []))
        if card_count == 0:
            continue
        loc = find_open_loc(placed, card_count)
        stack["loc"] = loc
        # Include this placement so sibling new stacks pack
        # against it.
        placed.append(
            {"loc": loc, "board_cards": stack["board_cards"]}
        )
        if verbose:
            print(
                f"    pre-plan: new stack ({card_count}c) "
                f"→ ({loc['left']},{loc['top']})"
            )


def _board_after_removals(board, stacks_to_remove):
    """Simulate the board state after a trick's stacks_to_remove
    are applied. Match by (loc + cards) — the referee's
    stacks_equal rule. First match wins for each target.
    """
    to_remove = set()
    for target in stacks_to_remove:
        for i, b in enumerate(board):
            if i in to_remove:
                continue
            if _stacks_equal(b, target):
                to_remove.add(i)
                break
    return [s for i, s in enumerate(board) if i not in to_remove]


def _stacks_equal(a, b):
    """Mirror Go referee's StacksEqual: same loc + pairwise card
    identity (value + suit + origin_deck). BoardCard.state is
    ignored — it's recency, not identity.
    """
    if a.get("loc") != b.get("loc"):
        return False
    a_cards = a.get("board_cards") or []
    b_cards = b.get("board_cards") or []
    if len(a_cards) != len(b_cards):
        return False
    for ac, bc in zip(a_cards, b_cards):
        if ac.get("card") != bc.get("card"):
            return False
    return True


def pre_settle_merge(c, session_id, action, *, verbose=True):
    """If the merge action's target cannot fit the merged result
    at its current loc, pre-move the target to a fresh spot — the
    human algorithm.

    For merge_stack: tries the source stack's current loc first
    (narratively: "the small stack stays where it is, the big one
    comes over"). For merge_hand (or merge_stack where the source
    loc won't fit either), falls back to find_open_loc.

    No-op when the action isn't a merge, or when the current loc
    already accommodates the growth.
    """
    kind = action["action"]
    if kind not in ("merge_hand", "merge_stack"):
        return

    state = c.get_state(session_id)
    board = state["state"]["board"]

    target_idx = action["target_stack"]
    target = board[target_idx]
    target_size = len(target["board_cards"])

    if kind == "merge_hand":
        merged_size = target_size + 1
        source_idx = None
        source_loc = None
        exclude = {target_idx}
    else:
        source_idx = action["source_stack"]
        source = board[source_idx]
        merged_size = target_size + len(source["board_cards"])
        source_loc = source["loc"]
        exclude = {target_idx, source_idx}

    # Option A: current target loc accommodates the merged size.
    if loc_clears_others(target["loc"], merged_size, board, exclude):
        return

    # Option B (merge_stack only): land the merged stack at the
    # source's old loc. The source itself vanishes in the merge,
    # so its footprint is free once the action lands.
    if source_loc is not None and loc_clears_others(
            source_loc, merged_size, board, exclude):
        c.send_move_stack(session_id, stack_index=target_idx,
                          new_loc=source_loc)
        if verbose:
            print(f"    pre-settle: merge target stack[{target_idx}] "
                  f"→ source loc ({source_loc['left']},{source_loc['top']})")
        return

    # Option C: fresh loc via find_open_loc.
    others = [s for i, s in enumerate(board) if i not in exclude]
    fresh = find_open_loc(others, merged_size)
    c.send_move_stack(session_id, stack_index=target_idx, new_loc=fresh)
    if verbose:
        print(f"    pre-settle: merge target stack[{target_idx}] "
              f"→ fresh loc ({fresh['left']},{fresh['top']})")


def settle(c, session_id, *, verbose=True):
    """Issue move_stack actions until the board satisfies the rule
    (in bounds, no overlap). The auto_player's tidying style.

    Returns the number of move_stack actions emitted.
    """
    steps = 0
    while steps < MAX_SETTLE_STEPS:
        state = c.get_state(session_id)
        board = state["state"]["board"]
        idx = find_violation(board)
        if idx is None:
            return steps

        offending = board[idx]
        # Compute the new loc against the board MINUS the offending
        # stack — otherwise the sweep treats the stack's current
        # (bad) position as an obstacle to itself.
        others = [s for i, s in enumerate(board) if i != idx]
        new_loc = find_open_loc(others, len(offending["board_cards"]))
        c.send_move_stack(session_id, stack_index=idx, new_loc=new_loc)
        if verbose:
            print(f"    settle: move stack[{idx}] "
                  f"({offending['loc']['left']:.0f},{offending['loc']['top']:.0f}) "
                  f"→ ({new_loc['left']},{new_loc['top']})")
        steps += 1

    raise RuntimeError(f"settle did not converge after {MAX_SETTLE_STEPS} steps")


def play_session(c, session_id, *, max_actions=200, verbose=True):
    """Play until the game ends or max_actions is hit.

    Returns a summary dict.
    """
    actions = 0
    turns = 0
    last_result = None

    while actions < max_actions:
        hint_resp = c.get_hint(session_id)
        suggestions = hint_resp.get("suggestions") or []

        if suggestions:
            first = suggestions[0]
            # Plan first, execute second — the human algorithm.
            # Plan A: merge target needs a fresh home? Pre-move it.
            # Plan B: trick produces new stacks? Pre-assign locs.
            pre_settle_merge(c, session_id, first["action"], verbose=verbose)
            plan_trick_result_locs(c, session_id, first["action"], verbose=verbose)
            c.send_action(session_id, first["action"])
            actions += 1
            if verbose:
                print(f"  act {actions}: {first['trick_id']} — "
                      f"{first['description']}")
            # Settle stays as a defensive backstop — should no
            # longer fire in the common case now that placements
            # are planned.
            settle(c, session_id, verbose=verbose)
            continue

        # No hints: end the turn. Server validates board + classifies.
        resp = c.send_complete_turn(session_id)
        turns += 1
        result = resp.get("turn_result")
        last_result = result
        if verbose:
            print(f"  turn {turns}: complete_turn → {result} "
                  f"(banked {resp.get('turn_score', 0)}, "
                  f"drew {resp.get('cards_drawn', 0)})")

        # Hard stop only on referee rejection (dirty-board bug).
        if result in TERMINAL_RESULTS:
            break

        # Normal termination: deck ran low. LynRummy isn't won
        # by emptying a hand — the game continues past victory
        # events, scores accumulate, and it finishes when the
        # deck is almost gone.
        state_resp = c.get_state(session_id)
        deck_size = len(state_resp.get("state", state_resp).get("deck", []))
        if verbose:
            print(f"    deck remaining: {deck_size}")
        if deck_size <= DECK_LOW_WATER:
            if verbose:
                print(f"  deck at low water ({deck_size} ≤ "
                      f"{DECK_LOW_WATER}); ending game.")
            break

    return {"actions": actions, "turns": turns,
            "final_turn_result": last_result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", type=int, default=None,
                        help="Session id. Omitted → creates a new one.")
    parser.add_argument("--max-actions", type=int, default=300)
    parser.add_argument(
        "--label", default=None,
        help="Session label. Omitted → 'claude autoplay <timestamp>'.",
    )
    parser.add_argument("--base",
                        default="http://localhost:9000/gopher/lynrummy-elm")
    args = parser.parse_args()

    c = Client(base=args.base)
    if args.session is not None:
        sid = args.session
    else:
        # Timestamped label so Steve can spot the agent's game
        # in the sessions list without guessing ids.
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        label = args.label or f"claude autoplay {stamp}"
        sid = c.new_session(label=label)

    initial = c.get_score(sid)
    print(f"session {sid}: initial board_score {initial['board_score']}")

    summary = play_session(c, sid, max_actions=args.max_actions)

    final = c.get_score(sid)
    print()
    print(f"actions played: {summary['actions']}")
    print(f"turns completed: {summary['turns']}")
    print(f"final turn_result: {summary['final_turn_result']}")
    print(f"final board_score: {final['board_score']}")
    print(f"browse: http://localhost:9000/gopher/lynrummy-elm/sessions/{sid}")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
