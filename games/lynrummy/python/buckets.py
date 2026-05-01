"""
buckets.py — 4-bucket BFS state shape + state_sig.

The Python equivalent of `Game.Agent.Buckets.elm`. Holds
the type aliases for the BFS state and the bucket-level
operations (`state_sig`, `trouble_count`, `is_victory`).
"""

from typing import Literal, NamedTuple

from classified_card_stack import classify_stack


# --- Type aliases (parallel to Elm's `Game.Agent.*` typedefs) ---
# Pure documentation: they don't constrain anything, but they
# make signatures self-explanatory and match the Elm port's
# vocabulary. Per Steve's preference, lists stay lists —
# these aliases preserve `list` semantics.

Card = tuple[int, int, int]                  # (value, suit, deck)
Stack = list[Card]                           # an agent-side stack
Bucket = list[Stack]                         # one of helper / trouble / growing / complete
ShapeKey = tuple[int, int]                   # (value, suit) — doomed-third + extractable index key
Lineage = tuple[Stack, ...]                  # focus queue; lineage[0] is the focus
BucketName = Literal["trouble", "growing"]   # the two absorber-source buckets
Verb = Literal["peel", "pluck", "yank", "steal", "split_out"]
Side = Literal["left", "right"]
MoveType = Literal["extract_absorb", "free_pull", "push", "splice", "shift"]


# --- State records ---
# Mirrors Elm's `Game.Agent.Buckets` + the `FocusedState`
# alias inside `Enumerator.elm`. NamedTuple gives both
# named access (`state.helper`) and positional unpacking
# (`h, t, g, c = state`), so it's drop-in compatible with
# the legacy 4-tuple shape while reading more like the Elm
# record on the new sites.


class Buckets(NamedTuple):
    helper: Bucket
    trouble: Bucket
    growing: Bucket
    complete: Bucket


class FocusedState(NamedTuple):
    buckets: Buckets
    lineage: Lineage


# --- State-level operations ---

def state_sig(helper, trouble, growing, complete):
    """Memoization key. Bucket order matters (HELPER vs
    COMPLETE differ in role) but stack order within a bucket
    doesn't. Stacks must be `ClassifiedCardStack` (the data
    shape inside BFS); access goes through `.cards`."""
    def s(stacks):
        return tuple(sorted(tuple(sorted(st.cards)) for st in stacks))
    return (s(helper), s(trouble), s(growing), s(complete))


def trouble_count(trouble, growing):
    n = 0
    for s in trouble:
        n += s.n
    for s in growing:
        n += s.n
    return n


def is_victory(trouble, growing):
    if trouble:
        return False
    for g in growing:
        if g.n < 3:
            return False
    return True


# --- Boundary conversion ---------------------------------------------------

def classify_buckets(buckets):
    """Convert a raw `Buckets` (lists of lists of cards) into a `Buckets`
    of lists of `ClassifiedCardStack`. Raises `ValueError` on any stack
    that fails to classify — those are caller bugs, not BFS bugs.

    This is the boundary helper. Call it once at every entry point
    (`solve_state_with_descs`, agent_prelude, mining tools, tests). Inside
    BFS the invariant holds: every stack is already a CCS with one of the
    7 valid kinds. No `KIND_OTHER`."""
    return Buckets(
        helper=_classify_bucket(buckets.helper, "helper"),
        trouble=_classify_bucket(buckets.trouble, "trouble"),
        growing=_classify_bucket(buckets.growing, "growing"),
        complete=_classify_bucket(buckets.complete, "complete"),
    )


def _classify_bucket(stacks, bucket_name):
    out = []
    for i, st in enumerate(stacks):
        ccs = classify_stack(st)
        if ccs is None:
            raise ValueError(
                f"invalid stack in {bucket_name}[{i}]: {tuple(st)!r} "
                "did not classify as run/rb/set/pair_*/singleton"
            )
        out.append(ccs)
    return out
