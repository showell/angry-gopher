# Hand-authored geometry-parity scenarios for
# `find_open_loc`. The 25 mined puzzles in `planner_mined.dsl`
# exercise this code path indirectly via MoveStack pre-flights,
# but the corner cases below (empty board, hard-against the
# preferred origin, near-edge placement) need explicit
# coverage so any drift between Python's `geometry.find_open_loc`
# and Elm's `Game.PlaceStack.findOpenLoc` shows up immediately.
#
# Oracle values come from running Python and pinning what it
# emits — Python is the source of truth; Elm asserts equality.
# Re-pin from Python on intentional algorithm changes:
#
#     python3 -c "import sys; sys.path.insert(0, \\
#         'games/lynrummy/python'); import geometry as g; \\
#         print(g.find_open_loc([{'loc': {'top': 0, 'left': 0}, \\
#         'board_cards': [{'card': {'value': 1, 'suit': 0, \\
#         'origin_deck': 0}, 'state': 0}] * 5}], 3))"


scenario find_open_loc_empty_board
  desc: Empty board → BOARD_START + ANTI_ALIGN = (24+2, 24+2).
  op: find_open_loc
  card_count: 3
  expect:
    loc: (26, 26)


scenario find_open_loc_one_stack_top_left
  desc: A single short stack at (0, 0). Preferred origin (50, 90) clears it; placer lands at (90+ANTI_ALIGN, 50+ANTI_ALIGN) = (92, 52).
  op: find_open_loc
  card_count: 3
  existing:
    at (0,0): AC AC AC AC AC
  expect:
    loc: (92, 52)


scenario find_open_loc_lots_of_top_row_stacks
  desc: A row of stacks across the top forces the placer to drop down inside the preferred column. Column-major scan finds first clear top-cell at left=52, top below the existing row.
  op: find_open_loc
  card_count: 3
  existing:
    at (0,0): AC AC AC AC AC
    at (0,200): AC AC AC AC AC
    at (0,400): AC AC AC AC AC
  expect:
    loc: (92, 52)


scenario find_open_loc_blocking_preferred_origin
  desc: Stack camped at the preferred origin (90, 50) forces the placer down. Python's column-major scan with packStep=15 + pack-gap=30 finds (167, 52) — three step-15 ticks below the blocker, plus anti-align.
  op: find_open_loc
  card_count: 3
  existing:
    at (0,0): AC AC AC AC AC
    at (90,50): AC AC AC AC AC
  expect:
    loc: (167, 52)


scenario find_open_loc_long_stack
  desc: Long stack still fits in the preferred column. 12 cards = 27 + 33*11 = 390px wide. Column-major scan picks (92, 52) — the long stack still clears at the preferred origin.
  op: find_open_loc
  card_count: 12
  existing:
    at (0,0): AC AC AC AC AC
  expect:
    loc: (92, 52)
