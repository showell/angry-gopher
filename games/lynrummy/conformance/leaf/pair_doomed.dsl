# pair_doomed — leaf conformance for the futility predicate.
#
# `is_pair_doomed(pair, donor_cards)` returns true iff none of the
# donor cards is a live extender for the pair. Glue code that
# assembles donor_cards from BFS buckets is NOT tested here — that
# integration is covered by the engine conformance scenarios. This
# DSL pins the pure helper.
#
# Format (single-line):
#   pair_doomed <pair_cards> | <donor_cards> → alive | doomed
#
# Donor cards are space-separated; deck markers (e.g. "AC:1") are
# allowed but ignored — deck doesn't affect doomedness, only
# value+suit do.
#
# An empty donor list is allowed (everything left of the arrow):
#   pair_doomed AC 2C | → doomed

# --- pair_run, simple alive/doomed ---
pair_doomed 5H 6H | 4H 7H               → alive    # both edges present
pair_doomed 5H 6H | 4H                  → alive    # left edge alone is enough
pair_doomed 5H 6H | 7H                  → alive    # right edge alone is enough
pair_doomed 5H 6H | 4C 4D 4S            → doomed   # right value, wrong suit
pair_doomed 5H 6H | 7C 7D 7S            → doomed   # right value (succ), wrong suit
pair_doomed 5H 6H | 5C 6C 5D 6S         → doomed   # only the pair's own values
pair_doomed 5H 6H |                     → doomed   # empty donor pool

# --- pair_run, K↔A wraparound (the canonical case) ---
pair_doomed KS AS | QS                  → alive    # left wraps Q → live
pair_doomed KS AS | 2S                  → alive    # right wraps to 2 → live
pair_doomed KS AS | QS 2S 3S            → alive    # both edges live
pair_doomed KS AS | 2C 2D 2H            → doomed   # right value (2), wrong suit
pair_doomed KS AS | QC QD QH            → doomed   # right value (Q), wrong suit
pair_doomed KS AS | KC KD KH AC AD AH   → doomed   # only K's and A's of other suits
pair_doomed KH AH | QH                  → alive    # same shape, hearts
pair_doomed KH AH | 2H                  → alive
pair_doomed KH AH | 5C 6C 7C            → doomed

# --- pair_run, low-edge wraparound (predecessor of A wraps to K) ---
pair_doomed AC 2C | KC                  → alive    # left wraps to K
pair_doomed AC 2C | 3C                  → alive    # right is 3
pair_doomed AC 2C | KC 3C               → alive
pair_doomed AC 2C | KD KH KS            → doomed   # right value (K), wrong suit
pair_doomed AC 2C | 5C 6C 7C            → doomed   # only mid-range clubs

# --- pair_rb, color-direction matters ---
# 5H red, 6S black. Left needs black (pred 4 in C/S), right needs red (succ 7 in D/H).
pair_doomed 5H 6S | 4C                  → alive
pair_doomed 5H 6S | 4S                  → alive
pair_doomed 5H 6S | 7D                  → alive
pair_doomed 5H 6S | 7H                  → alive
pair_doomed 5H 6S | 4D 4H               → doomed   # right value (4), wrong color
pair_doomed 5H 6S | 7C 7S               → doomed   # right value (7), wrong color
pair_doomed 5H 6S | 5C 6H 5D 6D         → doomed   # pair's own values, wrong shapes

# --- pair_rb, K↔A wraparound ---
# KH red, AC black. Left pred of K must be opposite of K (red), so black Q (QC, QS).
# Right succ of A must be opposite of A (black), so red 2 (2D, 2H).
pair_doomed KH AC | QC                  → alive
pair_doomed KH AC | QS                  → alive
pair_doomed KH AC | 2D                  → alive
pair_doomed KH AC | 2H                  → alive
pair_doomed KH AC | QD QH               → doomed   # Q, but wrong color (red, needs black)
pair_doomed KH AC | 2C 2S               → doomed   # 2, but wrong color (black, needs red)

# --- pair_rb, low-edge wraparound ---
# AH red, 2C black. Left pred of A wraps to K, opposite of A (red) = black: KC, KS.
# Right succ of 2 must be opposite of 2C (black) = red: 3D, 3H.
pair_doomed AH 2C | KC                  → alive
pair_doomed AH 2C | KS                  → alive
pair_doomed AH 2C | 3D                  → alive
pair_doomed AH 2C | 3H                  → alive
pair_doomed AH 2C | KD KH               → doomed   # K, wrong color
pair_doomed AH 2C | 3C 3S               → doomed   # 3, wrong color

# --- pair_set, alive iff a missing-suit at the same value is present ---
# 5H + 5C: missing suits are D and S. Alive iff 5D or 5S in donors.
pair_doomed 5H 5C | 5D                  → alive
pair_doomed 5H 5C | 5S                  → alive
pair_doomed 5H 5C | 5D 5S               → alive
pair_doomed 5H 5C | 5H                  → doomed   # already-in-pair suit
pair_doomed 5H 5C | 4S 5C 6D            → doomed   # no fresh suit at 5
pair_doomed 5H 5C |                     → doomed

# --- pair_set, low value (no wraparound; sets don't depend on adjacency) ---
pair_doomed AC AD | AH                  → alive
pair_doomed AC AD | AS                  → alive
pair_doomed AC AD | AC AD               → doomed   # only the pair itself
pair_doomed AC AD | 2H 2S 2D            → doomed   # wrong value entirely

# --- pair_set, high value ---
pair_doomed KS KH | KC                  → alive
pair_doomed KS KH | KD                  → alive
pair_doomed KS KH | QH JH               → doomed

# --- Deck markers ignored (deck doesn't affect doomedness) ---
pair_doomed AC 2C | KC:1                → alive    # deck-1 K of clubs still extends
pair_doomed AC 2C | 3C:1                → alive
pair_doomed 5H 5C | 5D:1                → alive
