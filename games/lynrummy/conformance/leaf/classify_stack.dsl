# classify_stack — leaf conformance.
#
# Each line is a single self-evident scenario:
#   classify <cards...> → <expected_kind>
#
# Card labels: rank+suit, deck-1 disambiguated as "AC:1".
# Expected kinds: run / rb / set / pair_run / pair_rb / pair_set
# / singleton / none. K→A wraps for runs; A→K does NOT wrap.
#
# `classify [] → none` is the explicit empty-list case.

# --- Trivia ---
classify [] → none                               # empty input
classify AC → singleton                          # any single card

# --- Length-2 pairs ---
classify AC 2C → pair_run                        # successive same suit
classify AC 2D → pair_rb                         # successive opposite color
classify AC AD → pair_set                        # same value, different suit
classify AC AS → pair_set                        # both black, but value match wins
classify AC AC → none                            # same card twice
classify AC 2S → none                            # successive but same color, different suit
classify AC 4C → none                            # disconnected (skipped 2,3)
classify KC AC → pair_run                        # K→A wrap: successor(K) = A
classify AC KC → none                            # A→K does NOT wrap

# --- Length-3 pure runs ---
classify AC 2C 3C → run                          # same suit, three consecutive
classify QC KC AC → run                          # K-to-A wrap inside a run
classify AC 2C 3D → none                         # third card changes suit

# --- Length-3 rb runs ---
classify AC 2D 3C → rb                           # alternating colors, successive
classify AC 2D 3D → none                         # two consecutive same color

# --- Length-3 sets ---
classify AC AD AH → set                          # three distinct suits
classify AC AD AC → none                         # duplicate suit (clubs twice)
classify AC AD 2H → none                         # mixed values

# --- Length-4 stacks ---
classify 5H 6H 7H 8H → run                       # length-4 pure run
classify AC 2D 3C 4H → rb                        # length-4 rb run
classify AC 2D 3C 4S → none                      # rb breaks: 4S same color as 3C
classify 7C 7D 7S 7H → set                       # all four suits, same value

# --- Length-5+ stacks ---
classify 9C TC JC QC KC → run                    # length-5 pure run
classify AC 2D 3C 4D 5C → rb                     # length-5 rb run

# --- Two-deck disambiguation ---
classify AC AD:1 AH → set                        # decks differ but suits distinct → ok
classify AC AC:1 AD → none                       # same suit across decks → invalid
