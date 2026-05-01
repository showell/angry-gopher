# peel — leaf conformance.
#
# Peel drops one card from a stack. Legal at:
#   - Either end of a length-4+ run or rb run.
#   - Any position of a length-4+ set (sets are unordered).
#
# Format:
#   peel <cards>... @ <position> → <extracted> | <remnant>
#   peel <cards>... @ <position> → none           (predicate fails)
#
# Cards in the result are listed in order; the first piece is the
# extracted singleton, the second is the remnant stack.

# --- length-4 pure run: only end positions ---
peel AC 2C 3C 4C @ 0 → AC | 2C 3C 4C            # left edge
peel AC 2C 3C 4C @ 3 → 4C | AC 2C 3C            # right edge
peel AC 2C 3C 4C @ 1 → none                      # interior — pluck/yank territory
peel AC 2C 3C 4C @ 2 → none                      # interior

# --- length-4 rb run: only end positions ---
peel AC 2D 3C 4D @ 0 → AC | 2D 3C 4D            # left edge
peel AC 2D 3C 4D @ 3 → 4D | AC 2D 3C            # right edge
peel AC 2D 3C 4D @ 1 → none                      # interior

# --- length-3 stacks: peel is illegal (need n >= 4) ---
peel AC 2C 3C @ 0 → none                         # length 3 — too short
peel AC 2D 3C @ 0 → none                         # rb length 3 — too short
peel AC AD AH @ 0 → none                         # set length 3 — too short

# --- length-4 set: any position ---
peel AC AD AH AS @ 0 → AC | AD AH AS            # any-position peel works
peel AC AD AH AS @ 1 → AD | AC AH AS
peel AC AD AH AS @ 2 → AH | AC AD AS
peel AC AD AH AS @ 3 → AS | AC AD AH

# --- length-5 pure run ---
peel AC 2C 3C 4C 5C @ 0 → AC | 2C 3C 4C 5C      # left edge
peel AC 2C 3C 4C 5C @ 4 → 5C | AC 2C 3C 4C      # right edge
peel AC 2C 3C 4C 5C @ 2 → none                   # interior of length-5 run is yank/pluck

# --- pair_X stacks: peel illegal (need n >= 4) ---
peel AC 2C @ 0 → none                            # pair_run too short
peel AC AD @ 0 → none                            # pair_set too short

# --- singleton: nothing to peel ---
peel AC @ 0 → none
