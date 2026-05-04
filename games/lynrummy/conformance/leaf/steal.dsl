# steal — leaf conformance.
#
# Steal extracts a card from a length-3 stack OR a length-2 partial:
#   - length-3 run or rb: only end positions; remnant is a length-2 partial.
#   - length-3 set: any position; remnant ATOMIZES into singletons
#     (BFS rule: stealing from a set destroys it, leaving the remaining
#     cards as independent trouble singletons rather than one pair_set).
#   - length-2 pair_run / pair_rb / pair_set: either position; remnant
#     is the other card as a singleton (the "AS trapped in a partial is
#     still donor-eligible" extension).
#
# Format:
#   steal <cards>... @ <pos> → <extracted> | <piece1> | <piece2> ...
#   steal <cards>... @ <pos> → none
#
# Output shape varies:
#   - run/rb len=3 @ end: 2 pieces (extracted, remaining pair).
#   - set len=3 @ any: 3 pieces (extracted, singleton, singleton).
#   - len=2 pair @ any: 2 pieces (extracted, other singleton).

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

# --- length-2 partials: steal yields extracted + the other card as a singleton ---
steal AC 2C @ 0 → AC | 2C                        # pair_run, extract left
steal AC 2C @ 1 → 2C | AC                        # pair_run, extract right
steal AC 2D @ 0 → AC | 2D                        # pair_rb, extract left
steal AC 2D @ 1 → 2D | AC                        # pair_rb, extract right
steal AC AD @ 0 → AC | AD                        # pair_set, extract left
steal AC AD @ 1 → AD | AC                        # pair_set, extract right

# --- singleton: too short ---
steal AC @ 0 → none                              # singleton
