# yank — leaf conformance.
#
# Yank drops a card from a run/rb at a position where ONE half is
# length-3+ and the OTHER is length 1 or 2 (non-empty). It covers
# the positions outside both peel (ends) and pluck (deep interior).
# Requires the kind to be run or rb (not set, not partials, not
# singleton).
#
# Format:
#   yank <cards>... @ <position> → <extracted> | <left_half> | <right_half>
#   yank <cards>... @ <position> → none

# --- length-4 pure run: positions 1 and 2 are yank territory ---
# at @1: left=length-1 (singleton), right=length-2 (pair_run) — both NON-empty
# but yank requires one half to be 3+. With length-4, one half is 1, other is 2.
# Neither is >=3, so YANK FAILS.
yank AC 2C 3C 4C @ 1 → none                          # both halves too short
yank AC 2C 3C 4C @ 2 → none

# --- length-5 pure run: positions 1 and 3 are yank territory ---
# @1: left=1, right=3. Right is 3+. Yank legal.
yank AC 2C 3C 4C 5C @ 1 → 2C | AC | 3C 4C 5C
# @3: left=3, right=1. Left is 3+. Yank legal.
yank AC 2C 3C 4C 5C @ 3 → 4C | AC 2C 3C | 5C
yank AC 2C 3C 4C 5C @ 0 → none                       # ends are peel territory
yank AC 2C 3C 4C 5C @ 4 → none                       # ends are peel territory
yank AC 2C 3C 4C 5C @ 2 → none                       # exact middle: 2 and 2, both too short

# --- length-6 pure run: positions 1 and 4 are yank territory ---
# @1: left=1, right=4 → yank
# @2: left=2, right=3 → yank (both halves "non-empty", one >=3)
# @3: left=3, right=2 → yank
# @4: left=4, right=1 → yank
yank AC 2C 3C 4C 5C 6C @ 1 → 2C | AC | 3C 4C 5C 6C
yank AC 2C 3C 4C 5C 6C @ 2 → 3C | AC 2C | 4C 5C 6C
yank AC 2C 3C 4C 5C 6C @ 3 → 4C | AC 2C 3C | 5C 6C
yank AC 2C 3C 4C 5C 6C @ 4 → 5C | AC 2C 3C 4C | 6C

# --- length-7 pure run: positions 1, 2, 4, 5 are yank; 3 is pluck ---
yank 2C 3C 4C 5C 6C 7C 8C @ 2 → 4C | 2C 3C | 5C 6C 7C 8C
yank 2C 3C 4C 5C 6C 7C 8C @ 5 → 7C | 2C 3C 4C 5C 6C | 8C
yank 2C 3C 4C 5C 6C 7C 8C @ 3 → none                 # this is pluck territory

# --- rb run: same position rules ---
yank AC 2D 3C 4D 5C @ 1 → 2D | AC | 3C 4D 5C
yank AC 2D 3C 4D 5C @ 3 → 4D | AC 2D 3C | 5C

# --- non-run/rb kinds: yank never legal ---
yank AC AD AH AS @ 1 → none                          # set
yank AC 2C 3C @ 1 → none                             # length-3 run (anywhere is steal/split_out)
yank AC AD @ 0 → none                                # pair_set
yank AC @ 0 → none                                   # singleton
