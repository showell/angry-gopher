"""
cards.py — verb-eligibility predicates for the BFS planner.

The Python parallel of Elm's `Game.Agent.Cards`: the
predicates that decide whether a given (kind, n, ci) shape
admits each extract verb. These are agent strategy
(Class-3), NOT rules — the rule layer lives in `rules/`.

The pure rule content that used to live here moved into the
`rules/` subpackage on the Class-1/2 segregation migration
(parallel to Elm's `Game/Rules/` lockdown). Card primitives,
classification, and the legality predicates are now
imported from `rules`.

Mirrors Elm's `canPeel` / `canPluck` / `canYank` /
`canSteal` / `canSplitOut` inside `Enumerator.elm` — the
enumerator dispatches via `verb_for(kind, n, ci)` against
these.
"""


def can_peel(kind, n, ci):
    if kind == "set" and n >= 4:
        return True
    if kind in ("pure_run", "rb_run") and n >= 4 and (
            ci == 0 or ci == n - 1):
        return True
    return False


def can_pluck(kind, n, ci):
    return kind in ("pure_run", "rb_run") and 3 <= ci <= n - 4


def can_yank(kind, n, ci):
    if kind not in ("pure_run", "rb_run"):
        return False
    if ci == 0 or ci == n - 1 or 3 <= ci <= n - 4:
        return False
    left_len = ci
    right_len = n - ci - 1
    return (max(left_len, right_len) >= 3
            and min(left_len, right_len) >= 1)


def can_steal(kind, n, ci):
    if n != 3:
        return False
    if kind in ("pure_run", "rb_run"):
        return ci == 0 or ci == n - 1
    return kind == "set"


def can_split_out(kind, n, ci):
    """Extract the interior card of a length-3 run, splitting
    it into two singleton TROUBLE fragments. Fills the only
    extraction gap in the verb vocabulary: every card on the
    board becomes reachable for absorption."""
    return (kind in ("pure_run", "rb_run")
            and n == 3 and ci == 1)
