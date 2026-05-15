# Hand-authored corner cases for `find_open_loc`: empty
# board, hard-against the preferred origin, near-edge
# placement.


scenario find_open_loc_empty_board
  desc: Empty board → BOARD_START + ANTI_ALIGN = (24+2, 24+2).
  op: find_open_loc
  card_count: 3
  expect:
    loc: (26, 26)


scenario find_open_loc_one_stack_top_left
  desc: A single short stack at (0,0). Preferred origin (50, 90) clears it; placer lands at (90+ANTI_ALIGN, 50+ANTI_ALIGN) = (92, 52).
  op: find_open_loc
  card_count: 3
  existing:
    at (0,0): A♣ A♣ A♣ A♣ A♣
  expect:
    loc: (92, 52)


scenario find_open_loc_lots_of_top_row_stacks
  desc: A row of stacks across the top forces the placer to drop down inside the preferred column. Column-major scan finds first clear top-cell at left=52, top below the existing row.
  op: find_open_loc
  card_count: 3
  existing:
    at (0,0): A♣ A♣ A♣ A♣ A♣
    at (200,0): A♣ A♣ A♣ A♣ A♣
    at (400,0): A♣ A♣ A♣ A♣ A♣
  expect:
    loc: (92, 52)


scenario find_open_loc_blocking_preferred_origin
  desc: Stack camped at the preferred origin (90, 50) forces the placer down. Column-major scan with packStep=15 + pack-gap=30 finds (167, 52) — three step-15 ticks below the blocker, plus anti-align.
  op: find_open_loc
  card_count: 3
  existing:
    at (0,0): A♣ A♣ A♣ A♣ A♣
    at (50,90): A♣ A♣ A♣ A♣ A♣
  expect:
    loc: (167, 52)


scenario find_open_loc_long_stack
  desc: Long stack still fits in the preferred column. 12 cards = 27 + 33*11 = 390px wide. Column-major scan picks (92, 52) — the long stack still clears at the preferred origin.
  op: find_open_loc
  card_count: 12
  existing:
    at (0,0): A♣ A♣ A♣ A♣ A♣
  expect:
    loc: (92, 52)
