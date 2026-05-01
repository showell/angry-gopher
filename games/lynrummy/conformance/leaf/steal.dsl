# steal — leaf conformance.
#
# Steal extracts a card from a length-3 stack:
#   - run or rb: only end positions; remnant is a length-2 partial.
#   - set: any position; remnant ATOMIZES into singletons (BFS rule:
#     stealing from a set destroys it, leaving the remaining cards
#     as independent trouble singletons rather than one pair_set).
#
# Format:
#   steal <cards>... @ <pos> → <extracted> | <piece1> | <piece2> ...
#   steal <cards>... @ <pos> → none
#
# Output shape varies:
#   - run/rb @ end: 2 pieces (extracted, remaining pair).
#   - set @ any: 3 pieces (extracted, singleton, singleton).

# --- length-3 pure run: only end positions ---
steal AC 2C 3C @ 0 → AC | 2C 3C                  # left edge: pair_run remnant
steal AC 2C 3C @ 2 → 3C | AC 2C                  # right edge: pair_run remnant
steal AC 2C 3C @ 1 → none                        # interior — split_out territory

# --- length-3 rb run: same end-only rule ---
steal AC 2D 3C @ 0 → AC | 2D 3C
steal AC 2D 3C @ 2 → 3C | AC 2D
steal AC 2D 3C @ 1 → none

# --- length-3 set: any position; output atomizes to singletons ---
steal AC AD AH @ 0 → AC | AD | AH
steal AC AD AH @ 1 → AD | AC | AH
steal AC AD AH @ 2 → AH | AC | AD

# --- length-4+ stacks: steal not legal (need exactly 3) ---
steal AC 2C 3C 4C @ 0 → none                     # length-4 run
steal AC 2C 3C 4C @ 3 → none
steal AC AD AH AS @ 0 → none                     # length-4 set

# --- pair_X / singleton: too short ---
steal AC 2C @ 0 → none                           # pair_run
steal AC AD @ 0 → none                           # pair_set
steal AC @ 0 → none                              # singleton
