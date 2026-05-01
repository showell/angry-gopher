# pluck — leaf conformance.
#
# Pluck drops an interior card of a run/rb such that BOTH halves
# remain length-3+ runs of the same family. Requires n >= 7 with
# the position in [3, n-4].
#
# Format:
#   pluck <cards>... @ <position> → <extracted> | <left_half> | <right_half>
#   pluck <cards>... @ <position> → none

# --- length-7 pure run: only position 3 (the exact middle) ---
pluck 2C 3C 4C 5C 6C 7C 8C @ 3 → 5C | 2C 3C 4C | 6C 7C 8C
pluck 2C 3C 4C 5C 6C 7C 8C @ 0 → none                # left edge — peel territory
pluck 2C 3C 4C 5C 6C 7C 8C @ 6 → none                # right edge — peel territory
pluck 2C 3C 4C 5C 6C 7C 8C @ 1 → none                # too shallow — yank territory
pluck 2C 3C 4C 5C 6C 7C 8C @ 2 → none                # too shallow — yank territory
pluck 2C 3C 4C 5C 6C 7C 8C @ 4 → none                # too shallow on right — yank territory

# --- length-7 rb run ---
pluck AC 2D 3C 4D 5C 6D 7C @ 3 → 4D | AC 2D 3C | 5C 6D 7C

# --- length-8 pure run: positions 3 and 4 are the legal pluck range ---
pluck 2C 3C 4C 5C 6C 7C 8C 9C @ 3 → 5C | 2C 3C 4C | 6C 7C 8C 9C
pluck 2C 3C 4C 5C 6C 7C 8C 9C @ 4 → 6C | 2C 3C 4C 5C | 7C 8C 9C
pluck 2C 3C 4C 5C 6C 7C 8C 9C @ 5 → none             # right of pluck range

# --- length-3, length-4, length-5, length-6: too short for pluck ---
pluck AC 2C 3C @ 1 → none                            # length-3 run
pluck AC 2C 3C 4C @ 1 → none                         # length-4 run
pluck AC 2C 3C 4C @ 2 → none
pluck AC 2C 3C 4C 5C @ 2 → none                      # length-5
pluck AC 2C 3C 4C 5C 6C @ 2 → none                   # length-6
pluck AC 2C 3C 4C 5C 6C @ 3 → none                   # length-6

# --- non-run/rb kinds: pluck never legal ---
pluck AC AD AH AS @ 1 → none                         # set
pluck AC 2C @ 0 → none                               # pair_run
pluck AC AD @ 0 → none                               # pair_set
pluck AC @ 0 → none                                  # singleton
