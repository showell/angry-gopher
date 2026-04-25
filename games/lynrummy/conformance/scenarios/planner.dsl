# Planner conformance scenarios.
#
# Each scenario specifies a 4-bucket state (helper / trouble /
# growing / complete) and asserts the BFS solver's
# `_enumerate_moves` yields at least one move of the named
# `type`. Stack locations are inert here — the planner doesn't
# consult geometry — but the DSL still requires `at (top, left)`
# anchors so the parser can reuse the existing stack grammar.
#
# These scenarios are the durable successors to the
# trick-invariant scenarios in `tricks.dsl`. As trick code
# retires, the planner-side asserts here become the live
# conformance contract for Python and (post-port) Elm.

# --- extract_absorb (pull) -----------------------------------

scenario peel_left_edge_into_singleton_trouble
  desc: 5H peeled from a length-4 pure run absorbs onto trouble [4H].
  op: enumerate_moves
  helper:
    at (0,0): 5H 6H 7H 8H
  trouble:
    at (0,0): 4H
  expect:
    yields: extract_absorb

# --- free_pull -----------------------------------------------

scenario free_pull_singleton_onto_run_growing
  desc: A loose [4H] singleton in TROUBLE absorbs onto a 2-partial GROWING build.
  op: enumerate_moves
  helper:
  trouble:
    at (0,0): 4H
    at (0,0): 5H
  growing:
    at (0,0): 6H 7H
  expect:
    yields: free_pull

# --- push (TROUBLE → HELPER) ---------------------------------

scenario push_partial_pair_onto_helper_run
  desc: TROUBLE 2-partial [QC KC] pushes onto a helper run that legalizes both halves.
  op: enumerate_moves
  helper:
    at (0,0): 9C TC JC
  trouble:
    at (0,0): QC KC
  expect:
    yields: push

# --- engulf (b': GROWING → HELPER, graduate to COMPLETE) -----

scenario engulf_growing_2partial_into_legal_run
  desc: GROWING [AC 2D] engulfs HELPER [3S 4D 5C] → length-5 rb-run, graduates.
  op: enumerate_moves
  helper:
    at (0,0): 3S 4D 5C
  growing:
    at (0,0): AC 2D
  expect:
    yields: push

# --- splice --------------------------------------------------

scenario splice_dup_5d_into_pure_diamonds
  desc: A second-deck 5D' splices into a length-6 pure-diamond run between 4D and 5D.
  op: enumerate_moves
  helper:
    at (0,0): 3D 4D 5D 6D 7D 8D
  trouble:
    at (0,0): 5D'
  expect:
    yields: splice

# --- shift (8C-pops-JC idiom) --------------------------------

scenario shift_eight_clubs_pops_jack_clubs
  desc: Length-3 run [9C TC JC] steals JC; donor [8D 8S 8H 8C] supplies 8C as replacement.
  op: enumerate_moves
  helper:
    at (0,0): 9C TC JC
    at (0,0): 8D 8S 8H 8C
  trouble:
    at (0,0): QH
  expect:
    yields: shift
