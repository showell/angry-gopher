# split_out — leaf conformance.
#
# Split-out extracts the MIDDLE card of a length-3 run or rb. Both
# halves are singletons. This is the only verb that fires for the
# interior position of a length-3 run/rb (where steal handles the
# ends and pluck/yank don't apply at length 3).
#
# Format:
#   split_out <cards>... @ <pos> → <extracted> | <left_singleton> | <right_singleton>
#   split_out <cards>... @ <pos> → none

# --- length-3 pure run: only @ 1 ---
split_out AC 2C 3C @ 1 → 2C | AC | 3C
split_out AC 2C 3C @ 0 → none                    # ends are steal territory
split_out AC 2C 3C @ 2 → none

# --- length-3 rb run: only @ 1 ---
split_out AC 2D 3C @ 1 → 2D | AC | 3C

# --- length-3 set: never legal (split_out is run/rb-only) ---
split_out AC AD AH @ 1 → none

# --- length-4+ run/rb: split_out only fires at length 3 ---
split_out AC 2C 3C 4C @ 1 → none
split_out AC 2C 3C 4C @ 2 → none

# --- pair_X / singleton: too short ---
split_out AC 2C @ 0 → none                       # pair_run
split_out AC @ 0 → none                          # singleton
