# absorb — leaf conformance for the absorb probes.
#
# right_absorb / left_absorb test what kind the merged stack
# would have if a card is absorbed on that edge of a target.
# Returns the result kind, or `none` if the absorb is illegal.
#
# Format:
#   right_absorb <target_cards>... + <card> → <expected_kind>
#   left_absorb  <target_cards>... + <card> → <expected_kind>
#
# (Per the no-side-parameter discipline, right and left are
# different operations, hence two separate verbs.)

# --- singleton targets (uncommitted: any of three modes possible) ---
right_absorb AC + 2C → pair_run                 # same suit, succ value
left_absorb AC + KC → pair_run                  # same suit, pred value (K-A wrap)
right_absorb AC + 2D → pair_rb                  # opp color, succ value
left_absorb AC + KD → pair_rb                   # opp color, pred value
right_absorb AC + AD → pair_set                 # same value, different suit
left_absorb AC + AD → pair_set                  # set is symmetric — same answer either side
right_absorb AC + AC → none                     # same card twice
right_absorb AC + 2S → none                     # successive value but same color + different suit
right_absorb AC + 4C → none                     # disconnected (skipped 2,3)
left_absorb AC + 2C → none                      # left needs pred value (K), got succ value (2)

# --- pair_run targets (committed to run-family direction) ---
right_absorb AC 2C + 3C → run                   # extends to length-3 run
left_absorb AC 2C + KC → run                    # extends left (K-A wrap)
right_absorb AC 2C + 3D → none                  # different suit, breaks pure run
right_absorb AC 2C + 4C → none                  # not the immediate successor
left_absorb AC 2C + 3C → none                   # left edge needs pred (K), not succ (3)

# --- pair_rb targets ---
right_absorb AC 2D + 3C → rb                    # alternating colors continue
left_absorb AC 2D + KH → rb                     # K-A wrap, opp color of A's clubs
right_absorb AC 2D + 3D → none                  # 3D same color as 2D, breaks alternation
right_absorb AC 2D + 3S → rb                    # 3S black, alternates with 2D red

# --- pair_set targets (committed to set, unordered) ---
right_absorb AC AD + AH → set                   # extends to length-3 set
left_absorb AC AD + AS → set                    # set is symmetric
right_absorb AC AD + AC → none                  # duplicate suit
right_absorb AC AD + 2H → none                  # different value, can't extend a set

# --- run targets (length-3+) ---
right_absorb AC 2C 3C + 4C → run                # extends right
left_absorb AC 2C 3C + KC → run                 # extends left (K-A wrap)
right_absorb AC 2C 3C + 4D → none               # different suit
right_absorb AC 2C 3C + 5C → none               # not the immediate successor
right_absorb AC 2C 3C + 4H → none               # neither pure-run nor rb-compatible

# --- rb targets (length-3+) ---
right_absorb AC 2D 3C + 4D → rb                 # continues alternation
right_absorb AC 2D 3C + 4H → rb                 # 4H red alternates with 3C black
left_absorb AC 2D 3C + KD → rb                  # K-A wrap, opp color
right_absorb AC 2D 3C + 4C → none               # 4C black, same color as 3C
right_absorb AC 2D 3C + 4S → none               # 4S black, same color as 3C

# --- set targets ---
right_absorb AC AD AH + AS → set                # length-4 set, all suits used
left_absorb AC AD AH + AS → set                 # symmetric
right_absorb AC AD AH + AC → none               # duplicate suit (clubs already there)
right_absorb AC AD AH AS + 2C → none            # already at max length 4

# --- two-deck disambiguation ---
right_absorb AC AD + AH:1 → set                 # decks differ but suits distinct → ok
right_absorb AC AD AH:1 + AS → set              # all four suits used (across decks)
right_absorb AC AD AH:1 + AC → none             # duplicate suit (clubs across decks)
