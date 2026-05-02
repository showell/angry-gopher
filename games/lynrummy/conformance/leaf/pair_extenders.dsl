# pair_extenders — leaf conformance for the per-pair-kind extender
# table used by the futility check.
#
# `pair_extenders(pair)` returns the set of `(value, suit)` keys
# that, if present in the donor pool, would extend the pair to a
# legal length-3 group. Deck is dropped — either deck satisfies.
#
# Format (single-line):
#   pair_extenders <pair_cards> → <key1> <key2> ...
#
# Keys are card labels (rank+suit), sorted lexicographically for
# canonical comparison. The DSL is a COMPLETE SPEC: every key the
# DSL lists must appear in the function's output, and vice versa.
#
# Pair kinds (recap):
#   pair_run  — same suit, consecutive values
#   pair_rb   — alternating color, consecutive values
#   pair_set  — same value, distinct suits
#
# Successor wraps: K → A. Predecessor wraps: A → K.

# --- pair_run, no wraparound ---
pair_extenders 5H 6H → 4H 7H              # interior, both edges live
pair_extenders 2C 3C → 4C AC              # left edge wraps to A
pair_extenders QS KS → AS JS              # right edge wraps to A

# --- pair_run, wraparound across K/A boundary ---
pair_extenders KS AS → 2S QS              # the canonical K→A pair_run
pair_extenders KH AH → 2H QH              # same shape, hearts

# --- pair_rb, no wraparound ---
# 5H is red, 6S is black. Pair is red→black (consecutive).
# Left predecessor must be opposite color of 5H (red), so black: 4C, 4S.
# Right successor must be opposite color of 6S (black), so red: 7H, 7D.
pair_extenders 5H 6S → 4C 4S 7D 7H

# 7C is black, 8D is red. Pair is black→red.
# Left pred must be opposite color of 7C (black), so red: 6H, 6D.
# Right succ must be opposite color of 8D (red), so black: 9C, 9S.
pair_extenders 7C 8D → 6D 6H 9C 9S

# --- pair_rb, wraparound across K/A boundary ---
# KH is red, AC is black. Pair is red→black, K→A wrap.
# Left pred of K must be opposite of K (red), so black: QC, QS.
# Right succ of A must be opposite of A (black), so red: 2D, 2H.
pair_extenders KH AC → 2D 2H QC QS

# KS is black, AD is red. Pair is black→red, K→A wrap.
# Left pred of K must be opposite of K (black), so red: QD, QH.
# Right succ of A must be opposite of A (red), so black: 2C, 2S.
pair_extenders KS AD → 2C 2S QD QH

# --- pair_rb, low edge wraparound (A→2 is the pair, predecessor wraps to K) ---
# AH is red, 2C is black.
# Left pred of A wraps to K, must be opposite of AH (red), so black: KC, KS.
# Right succ of 2 must be opposite of 2C (black), so red: 3D, 3H.
pair_extenders AH 2C → 3D 3H KC KS

# --- pair_set, no value-adjacency dependency ---
# Pair has two of four suits at value V; alive extenders are the
# other two suits at V. Wraparound doesn't apply.
pair_extenders 5H 5C → 5D 5S            # red+black; alive = the other red and black
pair_extenders AC AD → AH AS            # at the low value
pair_extenders KS KH → KC KD            # at the high value
pair_extenders 8C 8S → 8D 8H            # both black; alive = both reds
pair_extenders 2D 2H → 2C 2S            # both red; alive = both blacks
