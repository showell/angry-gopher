# extenders — leaf conformance for the absorber extends tables.
#
# `extends_tables(target)` returns three dicts in canonical reading
# order: (left_extenders, right_extenders, set_extenders). Each is
# a `(value, suit) → result_kind` map of cards that legally absorb
# in that mode.
#
# Each scenario is a multi-line block: one target stack (header
# line) plus one body line per bucket. The DSL is a COMPLETE SPEC
# of the function's output — every entry the DSL lists must appear
# in the function's output, and every entry the function returns
# must appear in the DSL. Missing OR extra entries fail.
#
# Format:
#   extenders <target_cards>
#     left:  <card>=<kind>, <card>=<kind>, ...
#     right: <card>=<kind>, ...
#     set:   <card>=<kind>, ...   (or `-` for an empty bucket)

# --- singleton: uncommitted, all three buckets populated ---
extenders 4C
  left:  3C=pair_run, 3D=pair_rb, 3H=pair_rb
  right: 5C=pair_run, 5D=pair_rb, 5H=pair_rb
  set:   4D=pair_set, 4S=pair_set, 4H=pair_set

# --- singleton at high value (K-A wrap on right) ---
extenders KC
  left:  QC=pair_run, QD=pair_rb, QH=pair_rb
  right: AC=pair_run, AD=pair_rb, AH=pair_rb
  set:   KD=pair_set, KS=pair_set, KH=pair_set

# --- pair_run: committed to run, only left/right populated ---
# Result kind is `run` because n_new = 3.
extenders AC 2C
  left:  KC=run
  right: 3C=run
  set:   -

# --- pair_rb: committed to rb, alternation rules drive bucket entries ---
# AC is black; left edge needs RED for pred-K → KD, KH.
# 2D is red; right edge needs BLACK for succ-3 → 3C, 3S.
extenders AC 2D
  left:  KD=rb, KH=rb
  right: 3C=rb, 3S=rb
  set:   -

# --- pair_set: committed to set (unordered), only set bucket populated ---
extenders AC AD
  left:  -
  right: -
  set:   AS=set, AH=set

# --- run (length-3): only one shape per side ---
extenders AC 2C 3C
  left:  KC=run
  right: 4C=run
  set:   -

# --- run (length-3, K-A wrap interior): pred=J, succ=2 ---
extenders QC KC AC
  left:  JC=run
  right: 2C=run
  set:   -

# --- rb (length-3): two shapes per side ---
# AC is black, left edge needs RED at pred-K → KD, KH.
# 3C is black, right edge needs RED at succ-4 → 4D, 4H.
extenders AC 2D 3C
  left:  KD=rb, KH=rb
  right: 4D=rb, 4H=rb
  set:   -

# --- length-5 rb: same shape, just longer parent ---
extenders AC 2D 3C 4D 5C
  left:  KD=rb, KH=rb
  right: 6D=rb, 6H=rb
  set:   -

# --- set (length-3): only one suit free ---
extenders AC AD AH
  left:  -
  right: -
  set:   AS=set

# --- set (length-4, max): no extenders ---
extenders AC AD AH AS
  left:  -
  right: -
  set:   -
