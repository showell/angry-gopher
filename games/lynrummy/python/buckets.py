"""
buckets.py — 4-bucket BFS state shape + state_sig.

The Python equivalent of `Game.Agent.Buckets.elm`. Holds
the type aliases for the BFS state and the bucket-level
operations (`state_sig`, `trouble_count`, `is_victory`).

Lifted from `bfs_solver.py` 2026-04-26 as the module split
landed (per ALIGNMENT_REPORT.md).
"""

from typing import Literal, NamedTuple


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
    doesn't."""
    def s(stacks):
        return tuple(sorted(tuple(sorted(st)) for st in stacks))
    return (s(helper), s(trouble), s(growing), s(complete))


def trouble_count(trouble, growing):
    return sum(len(s) for s in trouble) + sum(len(s) for s in growing)


def is_victory(trouble, growing):
    return not trouble and all(len(s) >= 3 for s in growing)
