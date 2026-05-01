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

# Splice is run/rb-only. Set parents extend via the absorb operation
# (the set_extenders bucket on the absorber); attempting to "splice"
# a card into a set is the wrong vocabulary and never produces a
# BFS-useful move. The probe raises if called on a non-run/rb parent;
# the BFS hot path's `_eligible_splice_helpers` already filters to
# run/rb so it never hits that case.

# === Pattern: same-value match in an rb run ===
#
# A human looking for a splice scans the parent rb run for a card
# with the SAME VALUE as the insert card. If found, the splice goes
# adjacent to that match. The position-and-side are determined by
# the match position; the validity (color, length) is then a quick
# local check. All scenarios below exhibit the same shape: the
# inserted card has the same value as one specific parent card, and
# splices in next to it.
#
# These are the BFS-useful splices — both halves are length-3+ rb.

# --- length-5 rb parents ---
# Each has exactly one match position; one position per side admits.
right_splice 2D 3C 4D 5C 6D + 4H @ 3 → rb | rb       # 4H matches 4D (parent[2])
left_splice 2D 3C 4D 5C 6D + 4H @ 2 → rb | rb        # 4H matches 4D (parent[2])
right_splice 2C 3D 4C 5D 6C + 4S @ 3 → rb | rb       # mirror: 4S matches 4C
left_splice 2C 3D 4C 5D 6C + 4S @ 2 → rb | rb        # mirror

# --- length-6 rb parents — multiple positions admit splice ---
right_splice AC 2D 3C 4D 5C 6D + 3S @ 3 → rb | rb    # 3S matches 3C (parent[2])
left_splice AC 2D 3C 4D 5C 6D + 3S @ 2 → rb | rb     # 3S matches 3C (parent[2])
left_splice AC 2D 3C 4D 5C 6D + 4H @ 3 → rb | rb     # 4H matches 4D (parent[3])
right_splice AC 2D 3C 4D 5C 6D + 4H @ 4 → rb | rb    # 4H matches 4D (parent[3])

# --- length-7 rb parents — even more positions ---
left_splice AC 2D 3C 4D 5C 6D 7C + 4H @ 3 → rb | rb  # 4H matches 4D (parent[3])
right_splice AC 2D 3C 4D 5C 6D 7C + 4H @ 4 → rb | rb # 4H matches 4D (parent[3])
left_splice AC 2D 3C 4D 5C 6D 7C + 5S @ 4 → rb | rb  # 5S matches 5C (parent[4])

# --- value match present but length-2 with-card half (probe still classifies) ---
# Value-match exists at parent[0]=AC, but the resulting left half is
# length-2 (pair_set, since AC-AS share value). BFS would reject these
# because at least one half is length < 3, but the probe still returns
# non-None (so they're "successful" probe outputs even though they're
# not BFS-useful moves).
left_splice AC 2D 3C 4D + AS @ 1 → pair_set | rb
