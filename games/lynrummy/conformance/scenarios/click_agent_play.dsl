# click_agent_play — verify the immediate post-state of a
# "Let agent play" click. Each scenario builds a Play.Model
# from the given board, dispatches `ClickAgentPlay`, and
# asserts on the resulting model.
#
# Elm-only op. Python's not in this loop — there's no Python
# equivalent of Play.update.
#
# What the click contract guarantees:
#
#   1. On a solvable board (BFS finds a plan), the FIRST plan
#      line's primitives are appended to actionLog, replay is
#      started, agentProgram caches the rest of the plan.
#
#   2. On an unsolvable board (BFS finds nothing), the model
#      is unchanged structurally — log doesn't grow, replay
#      doesn't start, status surfaces "could not find a plan".
#
#   3. On a victory board (every stack already complete),
#      status notes "already clean" — no animation kicks.
#
# These cover the "happy path" and the two no-op modes that
# previously failed silently.


scenario click_agent_play_simple_peel
  desc: Peel TC from [TC JD QS KH] onto trouble [9D] is one merge_stack — one primitive appended, replay started, no remaining program.
  op: click_agent_play
  board:
    at (50, 50): TC JD QS KH
    at (100, 200): 9D
  expect:
    replay_started: true
    log_appended: 1
    agent_program_size: 0
    status_kind: inform
    status_contains: "Agent:"


scenario click_agent_play_unsolvable_board
  desc: Disjoint singleton trouble with no helpers → BFS returns nothing → no replay, no log growth, scold-style status surfaces the failure.
  op: click_agent_play
  board:
    at (50, 50): 5H
    at (100, 200): 9D
  expect:
    replay_started: false
    log_appended: 0
    agent_program_size: 0
    status_contains: "could not find a plan"


scenario click_agent_play_already_clean
  desc: Board with only complete sets/runs. BFS returns an empty plan → status notes "already clean", no replay.
  op: click_agent_play
  board:
    at (50, 50): AC AD AH
    at (100, 50): 2C 3D' 4C 5H 6S 7H
  expect:
    replay_started: false
    log_appended: 0
    status_contains: "already clean"
