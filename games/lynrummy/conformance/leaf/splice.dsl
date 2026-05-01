# splice — leaf conformance for the splice probes.
#
# right_splice / left_splice ask: "if you splice <card> into the
# <target> at position <pos>, what would the two halves classify
# as?" The two splice variants differ in which half receives the
# inserted card:
#
#   right_splice: left = target[:pos]; right = (card,) + target[pos:]
#   left_splice:  left = target[:pos] + (card,); right = target[pos:]
#
# Format:
#   right_splice <target>... + <card> @ <pos> → <left_kind> | <right_kind>
#   left_splice  <target>... + <card> @ <pos> → <left_kind> | <right_kind>
#   (or `→ none` when either half doesn't classify.)
#
# Per the no-side-parameter discipline these are two separate verbs.

# --- length-5 pure run [AC 2C 3C 4C 5C], splice at various positions ---
# A pure run is the strictest target — almost every splice fails because
# the inserted card breaks the same-suit constraint. The only ways to
# succeed: insert a same-suit card that maintains the run (e.g., reorder),
# but the parent already covers all those cards.
right_splice AC 2C 3C 4C 5C + 3D @ 2 → none      # 3D breaks pure run
left_splice AC 2C 3C 4C 5C + 3D @ 2 → none

# --- length-5 rb run [AC 2D 3C 4D 5C], splice at @2 ---
# right_splice @ 2 with card 2H:
#   left  = (AC, 2D)                           → pair_rb
#   right = (2H, 3C, 4D, 5C)                   → rb (alternating)
right_splice AC 2D 3C 4D 5C + 2H @ 2 → pair_rb | rb

# left_splice @ 2 with card 3D:
#   left  = (AC, 2D, 3D)                       → 2D-3D same color, NOT rb → none
left_splice AC 2D 3C 4D 5C + 3D @ 2 → none

# left_splice @ 2 with card 2S (replacement that succeeds):
#   left  = (AC, 2D, 2S)                       → 2D-2S same value diff suit, but
#                                                  AC-2D was alt-color pair_rb;
#                                                  combining: AC-2D-2S not a run.
#                                                  → none.
left_splice AC 2D 3C 4D 5C + 2S @ 2 → none

# --- length-6 rb run [AC 2D 3C 4D 5C 6D], several splice possibilities ---
# right_splice @ 3 with card 3H:
#   left  = (AC, 2D, 3C)                       → rb
#   right = (3H, 4D, 5C, 6D)                   → 3H red, 4D red — same color → none
right_splice AC 2D 3C 4D 5C 6D + 3H @ 3 → none

# right_splice @ 3 with card 3S:
#   left  = (AC, 2D, 3C)                       → rb
#   right = (3S, 4D, 5C, 6D)                   → 3S black, 4D red — alt; 4D-5C alt;
#                                                  5C-6D alt → rb
right_splice AC 2D 3C 4D 5C 6D + 3S @ 3 → rb | rb

# --- empty halves return none ---
# right_splice @ 0: left = empty → none
right_splice AC 2C 3C 4C + 5C @ 0 → none
# left_splice @ 5 (= n): right = empty → none
left_splice AC 2C 3C 4C 5C + 6C @ 5 → none

# --- non-run/rb parent kinds: probe routes through rigorous classifier ---
# For sets / pair_X / singletons, the splice probe falls back to the
# rigorous classifier. Cover representative cases.
right_splice AC AD AH + AS @ 2 → pair_set | pair_set    # set splice — rare path
right_splice AC AD AH + 2C @ 0 → none                   # set splice with mismatched value

