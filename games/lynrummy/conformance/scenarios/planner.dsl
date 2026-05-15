# Each scenario specifies a 4-bucket state (helper / trouble /
# growing / complete) and asserts the BFS solver's
# `_enumerate_moves` yields at least one move of the named
# `type`. Stack locations are inert here — the planner doesn't
# consult geometry — but the DSL still requires `at (top, left)`
# anchors so the parser can reuse the existing stack grammar.

# --- extract_absorb (pull) -----------------------------------

scenario peel_left_edge_into_singleton_trouble
  desc: 5♥ peeled from a length-4 pure run absorbs onto trouble [4♥].
  op: enumerate_moves
  helper:
    at (0,0): 5♥ 6♥ 7♥ 8♥
  trouble:
    at (0,0): 4♥
  expect:
    yields: extract_absorb

# --- free_pull -----------------------------------------------

scenario free_pull_singleton_onto_run_growing
  desc: A loose [4♥] singleton in TROUBLE absorbs onto a 2-partial GROWING build.
  op: enumerate_moves
  helper:
  trouble:
    at (0,0): 4♥
    at (0,0): 5♥
  growing:
    at (0,0): 6♥ 7♥
  expect:
    yields: free_pull

# --- push (TROUBLE → HELPER) ---------------------------------

scenario push_partial_pair_onto_helper_run
  desc: TROUBLE 2-partial [Q♣ K♣] pushes onto a helper run that legalizes both halves.
  op: enumerate_moves
  helper:
    at (0,0): 9♣ T♣ J♣
  trouble:
    at (0,0): Q♣ K♣
  expect:
    yields: push

# --- engulf (b': GROWING → HELPER, graduate to COMPLETE) -----

scenario engulf_growing_2partial_into_legal_run
  desc: GROWING [A♣ 2♦] engulfs HELPER [3♠ 4♦ 5♣] → length-5 rb-run, graduates.
  op: enumerate_moves
  helper:
    at (0,0): 3♠ 4♦ 5♣
  growing:
    at (0,0): A♣ 2♦
  expect:
    yields: push

# --- splice --------------------------------------------------

scenario splice_dup_5d_into_pure_diamonds
  desc: A second-deck 5♦' splices into a length-6 pure-diamond run between 4♦ and 5♦.
  op: enumerate_moves
  helper:
    at (0,0): 3♦ 4♦ 5♦ 6♦ 7♦ 8♦
  trouble:
    at (0,0): 5♦'
  expect:
    yields: splice

# --- solve: futility detection -------------------------------

scenario solve_lone_singleton_no_plan
  desc: A single trouble card with no helpers cannot form any group; solve must return None fast.
  op: solve
  helper:
  trouble:
    at (0,0): 5♥
  expect: no_plan

scenario solve_disjoint_helper_no_plan
  desc: Trouble 5♥ plus a helper run J-Q-K-A spades that has no value-overlap with 5♥. No move fires.
  op: solve
  helper:
    at (0,0): J♠ Q♠ K♠ A♠
  trouble:
    at (0,0): 5♥
  expect: no_plan

scenario solve_set_partial_uncompletable
  desc: Trouble [A♥ A♠] needs a third Ace; board has no third A and no A-adjacent extracts.
  op: solve
  helper:
    at (0,0): J♠ Q♠ K♠
  trouble:
    at (0,0): A♥ A♠
  expect: no_plan

scenario solve_two_unrelated_singletons
  desc: Trouble [5♥] + [J♣] share no group; neither completable from any helper.
  op: solve
  helper:
  trouble:
    at (0,0): 5♥
    at (0,0): J♣
  expect: no_plan

scenario solve_run_partial_uncompletable
  desc: Trouble pair [5♥ 6♥] is a pure-run partial; needs 4♥ or 7♥, board has neither.
  op: solve
  helper:
    at (0,0): J♠ Q♠ K♠
  trouble:
    at (0,0): 5♥ 6♥
  expect: no_plan

scenario solve_partial_completable_but_stranded
  desc: Trouble [5♥] + helper [3♣ 4♣ 5♣ 6♣]. Peel 6♣ produces partial [5♥ 6♣] but no further extract leads to victory; an unrelated helper [J♠ Q♠ K♠ A♠] adds noise but no path.
  op: solve
  helper:
    at (0,0): 3♣ 4♣ 5♣ 6♣
    at (0,0): J♠ Q♠ K♠ A♠
  trouble:
    at (0,0): 5♥
  expect: no_plan

scenario solve_lonely_trouble_amid_rich_helpers
  desc: Trouble 5♥ surrounded by length-4 helpers whose end cards are not 5♥ neighbors. Helpers exist but no extract verb fires for 5♥.
  op: solve
  helper:
    at (0,0): A♠ 2♠ 3♠ 4♠
    at (0,0): J♣ Q♣ K♣ A♣
    at (0,0): 8♦ 9♦ T♦ J♦
  trouble:
    at (0,0): 5♥
  expect: no_plan

scenario solve_two_partial_troubles_no_paths
  desc: Two unsolvable trouble pairs (A♥ A♠ needs another A; 5♥ 6♥ needs 4♥ or 7♥). Helpers don't carry the missing values.
  op: solve
  helper:
    at (0,0): 8♦ 9♦ T♦
    at (0,0): 8♠ 9♠ T♠
  trouble:
    at (0,0): A♥ A♠
    at (0,0): 5♥ 6♥
  expect: no_plan

# --- solve: positive cases ----------------------------------

scenario solve_engulf_in_one_line
  desc: GROWING [A♣ 2♦] engulfs HELPER [3♠ 4♦ 5♣] for a 1-line plan.
  op: solve
  helper:
    at (0,0): 3♠ 4♦ 5♣
  growing:
    at (0,0): A♣ 2♦
  expect:
    plan_lines:
      - "push [A♣ 2♦] onto HELPER [3♠ 4♦ 5♣] → [A♣ 2♦ 3♠ 4♦ 5♣]"

scenario solve_simple_peel_in_one_line
  desc: Trouble [4♥] absorbs 5♥ peeled from a length-4 helper run for a 1-line plan.
  op: solve
  helper:
    at (0,0): 5♥ 6♥ 7♥ 8♥
  trouble:
    at (0,0): 4♥
  expect:
    plan_lines:
      - "push [4♥] onto HELPER [5♥ 6♥ 7♥ 8♥] → [4♥ 5♥ 6♥ 7♥ 8♥]"

# --- narrate / hint renderings ------------------------------
# Each layer has a different audience:
#   narrate(desc) — Steve-facing, evocative ("engulf [3♠ 4♦ 5♣]
#     into [A♣ 2♦]"). Used in Claude's verbose-mode log.
#   hint(desc) — player-facing, vague-but-useful ("You can
#     splice the 7♥ into a red-black run.")

scenario narrate_engulf_phrasing
  desc: An engulf push narrates as 'engulf … into …' (Steve sees the chunk-level intent).
  op: enumerate_moves
  helper:
    at (0,0): 3♠ 4♦ 5♣
  growing:
    at (0,0): A♣ 2♦
  expect:
    narrate_contains: engulf

scenario hint_splice_red_black_run
  desc: Player-facing splice hint names the verb + the run kind. (Steve's reference phrasing.)
  op: enumerate_moves
  helper:
    at (0,0): 5♥ 6♠ 7♥ 8♠ 9♥ T♠
  trouble:
    at (0,0): 7♥'
  expect:
    hint_contains: red-black run

scenario hint_pop_via_shift
  desc: Player-facing shift hint says you can pop a card via shifting. K♣ supplies a completion candidate so the merged partial isn't doomed.
  op: enumerate_moves
  helper:
    at (0,0): 9♣ T♣ J♣
    at (0,0): 8♦ 8♠ 8♥ 8♣
    at (0,0): K♣ A♣ 2♣
  trouble:
    at (0,0): Q♥
  expect:
    hint_contains: pop the J♣

# --- shift (8♣-pops-J♣ idiom) --------------------------------

scenario shift_eight_clubs_pops_jack_clubs
  desc: Length-3 run [9♣ T♣ J♣] steals J♣; donor [8♦ 8♠ 8♥ 8♣] supplies 8♣. K♣ is on the board so the resulting [Q♥ J♣] partial isn't doomed.
  op: enumerate_moves
  helper:
    at (0,0): 9♣ T♣ J♣
    at (0,0): 8♦ 8♠ 8♥ 8♣
    at (0,0): K♣ A♣ 2♣
  trouble:
    at (0,0): Q♥
  expect:
    yields: shift

scenario solve_shift_subproblem_capture_59
  desc: Tighter subproblem from xcheck capture #59 — state after place [5♠] + steal 4♥ + steal A♥. Board-only; tests that shift can deliver 3♠ to [4♥ 5♠] without stranding [A♠ 2♠]. [4♥ 5♠] is in trouble (not growing) so initialLineage puts it first as the focus; the trouble-vs-growing distinction is bookkeeping anyway.
  op: solve
  helper:
    at (0,0): 3♣ 4♣' 5♣'
    at (0,0): A♠ 2♠ 3♠
    at (0,0): 3♦ 4♣ 5♥ 6♠ 7♦'
    at (0,0): 7♠ 7♦ 7♣ 7♥
    at (0,0): K♥ A♣ 2♥'
    at (0,0): K♠ A♦' 2♣ 3♦'
    at (0,0): T♦ J♦ Q♦ K♦
  trouble:
    at (0,0): 4♥ 5♠
    at (0,0): A♣'
    at (0,0): A♦
  expect:
    plan_lines:
      - "steal 3♠ from HELPER [A♠ 2♠ 3♠], absorb onto [4♥ 5♠] → [3♠ 4♥ 5♠] [→COMPLETE] ; spawn [A♠ 2♠]"
      - "steal A♠ from HELPER [A♠ 2♠], absorb onto [A♣'] → [A♣' A♠] ; spawn [2♠]"
      - "pull A♦ onto [A♣' A♠] → [A♣' A♠ A♦] [→COMPLETE]"
      - "push [2♠] onto HELPER [3♦ 4♣ 5♥ 6♠ 7♦'] → [2♠ 3♦ 4♣ 5♥ 6♠ 7♦']"
