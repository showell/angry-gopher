# splice_targets — leaf conformance for the BFS splice-candidate accelerator.
#
# `findSpliceCandidates(parent, card)` returns the list of splice
# positions that yield TWO LENGTH-3+ family-kind halves — the exact
# subset of splice moves the BFS uses. Each candidate is a guaranteed-
# valid splice; no probe call is needed.
#
# The function uses the SAME-VALUE-MATCH heuristic: scan the parent
# for a position m where parent[m] has the same value as the insert
# card. Every such match (when length-3+ on both sides) yields TWO
# candidates: left@m and right@(m+1). Length constraint: m ∈ [2, n-3].
#
# Format:
#   splice_targets <parent>... + <card> → <side>@<pos> <lkind>|<rkind>, ...
#   splice_targets <parent>... + <card> → none
#
# Candidates are ordered by ascending m, with `left@m` before
# `right@(m+1)` per match. Splice is run/rb-only; calling on a non-
# run/rb parent is a contract violation.

# === RB parents — the BFS-useful core ===

# --- length-5 rb: exactly one match position (m=2) admits ---
# Parent: [2D 3C 4D 5C 6D]
#  m=2: parent[2]=4D. Inserting a same-color same-value card (4H) yields
#  left@2 = [2D 3C 4H] (rb, len 3) | [4D 5C 6D] (rb, len 3)
#  right@3 = [2D 3C 4D] (rb, len 3) | [4H 5C 6D] (rb, len 3)
splice_targets 2D 3C 4D 5C 6D + 4H → left@2 rb|rb, right@3 rb|rb

# Mirror: parent [2C 3D 4C 5D 6C], insert 4S (black-black match).
splice_targets 2C 3D 4C 5D 6C + 4S → left@2 rb|rb, right@3 rb|rb

# Same parent + insert 4D (red but DIFFERENT color from black 4C at m=2):
# parent[2]=4C is black; 4D is red → color mismatch; no candidate.
splice_targets 2C 3D 4C 5D 6C + 4D → none

# Same parent + insert with NO value match: 8H (no 8 in parent at m∈[2,2]).
splice_targets 2D 3C 4D 5C 6D + 8H → none

# Value match but at boundary position m=0 (parent[0]=2D, insert 2S):
# m=0 fails the m≥2 length constraint → no candidate.
splice_targets 2D 3C 4D 5C 6D + 2S → none

# Value match but at boundary position m=4 (parent[4]=6D, insert 6S):
# m=4 > n-3 = 2 → no candidate.
splice_targets 2D 3C 4D 5C 6D + 6S → none

# Value match at m=1 (parent[1]=3C is black, insert 3S black, same value
# same color): m=1 < 2 → no candidate.
splice_targets 2D 3C 4D 5C 6D + 3S → none

# Value match at m=3 (parent[3]=5C is black, insert 5S black):
# m=3 > n-3 = 2 → no candidate.
splice_targets 2D 3C 4D 5C 6D + 5S → none

# --- length-6 rb: two match positions admit (m=2 and m=3) ---
# Parent: [AC 2D 3C 4D 5C 6D]; n=6 so m ∈ [2, 3].
# Insert 3S (black, matches 3C at m=2):
#   left@2 = [AC 2D 3S] | [3C 4D 5C 6D]
#   right@3 = [AC 2D 3C] | [3S 4D 5C 6D]
splice_targets AC 2D 3C 4D 5C 6D + 3S → left@2 rb|rb, right@3 rb|rb

# Insert 4H (red, matches 4D at m=3):
#   left@3 = [AC 2D 3C 4H] | [4D 5C 6D]
#   right@4 = [AC 2D 3C 4D] | [4H 5C 6D]
splice_targets AC 2D 3C 4D 5C 6D + 4H → left@3 rb|rb, right@4 rb|rb

# Insert 3D (red, matches 3C value but mismatched color → none).
splice_targets AC 2D 3C 4D 5C 6D + 3D → none

# Insert 7S (no value match in parent → none).
splice_targets AC 2D 3C 4D 5C 6D + 7S → none

# --- length-7 rb: three match positions admit (m=2..4) ---
# Parent: [AC 2D 3C 4D 5C 6D 7C]; n=7 so m ∈ [2, 4].
# Insert 4H matches 4D at m=3:
#   left@3 | right@4
splice_targets AC 2D 3C 4D 5C 6D 7C + 4H → left@3 rb|rb, right@4 rb|rb

# Insert 3S matches 3C at m=2:
splice_targets AC 2D 3C 4D 5C 6D 7C + 3S → left@2 rb|rb, right@3 rb|rb

# Insert 5S matches 5C at m=4:
splice_targets AC 2D 3C 4D 5C 6D 7C + 5S → left@4 rb|rb, right@5 rb|rb

# Insert 2H matches 2D at m=1: outside [2,4] → none.
splice_targets AC 2D 3C 4D 5C 6D 7C + 2H → none

# Insert 6H matches 6D at m=5: outside [2,4] → none.
splice_targets AC 2D 3C 4D 5C 6D 7C + 6H → none

# === Length-4 rb parents: ALWAYS none (n<5) ===
splice_targets 2D 3C 4D 5C + 4H → none
splice_targets 2D 3C 4D 5C + 3S → none
splice_targets AC 2D 3C 4D + AS → none

# === Pure run parents — cross-deck splice case ===
#
# A pure run [2C 3C 4C 5C 6C] cannot be spliced into without breaking
# the same-suit invariant — UNLESS the inserted card has the same suit
# AND the same value as some parent[m]. That's only possible across
# decks (the same physical card from the second deck).

# --- length-5 pure run: cross-deck match at m=2 ---
# Parent: [2C 3C 4C 5C 6C]; insert 4C:1 (deck-1 copy of 4 of clubs).
# m=2: parent[2]=4C:0; 4C:1 has same (value=4, suit=C). The inserted
# card slots in adjacent to parent[2] without breaking the pure-suit
# run boundary.
splice_targets 2C 3C 4C 5C 6C + 4C:1 → left@2 run|run, right@3 run|run

# Same parent + 4D (mismatched suit) → no candidate (pure run requires
# same suit; 4D would break the same-suit invariant).
splice_targets 2C 3C 4C 5C 6C + 4D → none

# Same parent + 8C:1 (right suit but no value match in m∈[2,2]) → none.
splice_targets 2C 3C 4C 5C 6C + 8C:1 → none

# --- length-6 pure run: cross-deck match at m=2 and m=3 ---
# Parent: [AC 2C 3C 4C 5C 6C]; n=6 so m ∈ [2, 3].
# Insert 3C:1 matches at m=2:
splice_targets AC 2C 3C 4C 5C 6C + 3C:1 → left@2 run|run, right@3 run|run

# Insert 4C:1 matches at m=3:
splice_targets AC 2C 3C 4C 5C 6C + 4C:1 → left@3 run|run, right@4 run|run

# Mismatched-suit value match (4D) on a pure-club run → none.
splice_targets AC 2C 3C 4C 5C 6C + 4D → none

# --- length-7 pure run: cross-deck match at m=2, m=3, m=4 ---
# Parent: [AH 2H 3H 4H 5H 6H 7H] (hearts); n=7, m ∈ [2, 4].
splice_targets AH 2H 3H 4H 5H 6H 7H + 4H:1 → left@3 run|run, right@4 run|run
splice_targets AH 2H 3H 4H 5H 6H 7H + 3H:1 → left@2 run|run, right@3 run|run
splice_targets AH 2H 3H 4H 5H 6H 7H + 5H:1 → left@4 run|run, right@5 run|run

# Mismatched suit on pure-heart run (3D) → none, even though 3 has a
# value match.
splice_targets AH 2H 3H 4H 5H 6H 7H + 3D → none

# Length-4 pure run is always none.
splice_targets 2C 3C 4C 5C + 4C:1 → none
