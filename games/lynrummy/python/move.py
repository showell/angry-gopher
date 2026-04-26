"""
move.py — BFS desc dataclasses + rendering (describe,
narrate, hint).

The Python equivalent of `Game.Agent.Move.elm`. Each move
type has a dedicated dataclass mirroring Elm's per-variant
record. The enumerator emits dataclass instances; readers
use attribute access (`desc.foo`) and dispatch via
`isinstance` or `match`.

Lifted from `bfs_solver.py` 2026-04-26 as the module split
landed; dataclasses introduced in the same pass.
"""

from dataclasses import dataclass, field

from buckets import Side, Verb
from cards import classify, card_label


# --- Per-move dataclasses ---
# Each carries the field set the legacy desc dicts used. The
# `type` class attribute keeps the legacy string-key dispatch
# readable for grep-archaeology, but isinstance() is the
# preferred dispatch in code.


@dataclass
class ExtractAbsorbDesc:
    type: str = field(default="extract_absorb", init=False)
    verb: str = ""
    source: list = field(default_factory=list)
    ext_card: tuple = (0, 0, 0)
    target_before: list = field(default_factory=list)
    target_bucket_before: str = ""
    result: list = field(default_factory=list)
    side: str = "right"
    graduated: bool = False
    spawned: list = field(default_factory=list)


@dataclass
class FreePullDesc:
    type: str = field(default="free_pull", init=False)
    loose: tuple = (0, 0, 0)
    target_before: list = field(default_factory=list)
    target_bucket_before: str = ""
    result: list = field(default_factory=list)
    side: str = "right"
    graduated: bool = False


@dataclass
class PushDesc:
    type: str = field(default="push", init=False)
    trouble_before: list = field(default_factory=list)
    target_before: list = field(default_factory=list)
    result: list = field(default_factory=list)
    side: str = "right"


@dataclass
class SpliceDesc:
    type: str = field(default="splice", init=False)
    loose: tuple = (0, 0, 0)
    source: list = field(default_factory=list)
    k: int = 0
    side: str = "left"
    left_result: list = field(default_factory=list)
    right_result: list = field(default_factory=list)


@dataclass
class ShiftDesc:
    type: str = field(default="shift", init=False)
    source: list = field(default_factory=list)
    donor: list = field(default_factory=list)
    stolen: tuple = (0, 0, 0)
    p_card: tuple = (0, 0, 0)
    which_end: int = 0
    new_source: list = field(default_factory=list)
    new_donor: list = field(default_factory=list)
    target_before: list = field(default_factory=list)
    target_bucket_before: str = ""
    merged: list = field(default_factory=list)
    side: str = "right"
    graduated: bool = False


def stack_label(stack):
    return " ".join(card_label(c) for c in stack)


def narrate(desc):
    """Evocative one-liner for a move, communicating INTENT
    rather than mechanics. Steve-facing: this is how Claude
    narrates what the agent is doing in the verbose-mode
    log. Each move type gets a verb-forward phrasing at the
    human chunk level (engulf, splice, pop, tuck, ...).

    For exact structural matching, use `describe`. For
    the vague hint a human PLAYER would see in the UI, use
    `hint`.
    """
    match desc:
        case FreePullDesc(loose=loose, result=result,
                          graduated=graduated):
            check = " ✓" if graduated else ""
            return (f"pull {card_label(loose)} into "
                    f"[{stack_label(result)}]{check}")

        case ExtractAbsorbDesc(verb=verb, ext_card=ext_card,
                               result=result, graduated=graduated,
                               spawned=spawned):
            check = " ✓" if graduated else ""
            spawned_str = ""
            if spawned:
                spawned_str = (" (leaves "
                               + ", ".join("[" + stack_label(s) + "]"
                                           for s in spawned)
                               + " homeless)")
            return (f"{verb} {card_label(ext_card)} → "
                    f"[{stack_label(result)}]{check}{spawned_str}")

        case ShiftDesc(p_card=p_card, stolen=stolen, merged=merged,
                       graduated=graduated):
            check = " ✓" if graduated else ""
            return (f"{card_label(p_card)} pops {card_label(stolen)} → "
                    f"[{stack_label(merged)}]{check}")

        case SpliceDesc(loose=loose, left_result=left,
                        right_result=right):
            return (f"splice {card_label(loose)} → "
                    f"[{stack_label(left)}] + [{stack_label(right)}]")

        # Engulf-shape vs plain push: plain push extends a
        # helper by 1-2 cards; engulf swallows a helper into a
        # complete stack (graduated from GROWING).
        case PushDesc(trouble_before=tb, target_before=target,
                      result=result) if classify(result) != "other":
            return (f"engulf [{stack_label(target)}] into "
                    f"[{stack_label(tb)}] → "
                    f"[{stack_label(result)}] ✓")

        case PushDesc(trouble_before=tb, target_before=target,
                      result=result):
            return (f"tuck [{stack_label(tb)}] into "
                    f"[{stack_label(target)}] → "
                    f"[{stack_label(result)}]")

        case _:
            return str(desc)


def hint(desc):
    """Vague-but-useful one-liner for a HUMAN PLAYER. Names
    the verb + a key card/partial + (sometimes) the GROUP
    KIND of the destination, but does NOT spell out the
    specific source/target stacks. The intent: nudge without
    solving.

    Steve's reference phrasing: "You can splice the 7H into a
    red-black run." (Names card, verb, group kind. Doesn't
    name the run.)
    """
    match desc:
        case FreePullDesc(loose=loose, result=result):
            return (f"You can pull the {card_label(loose)} onto "
                    f"{group_kind_phrase(result)}.")

        case ExtractAbsorbDesc(verb=verb, ext_card=ext_card,
                               target_before=target_before):
            return (f"You can {verb} the {card_label(ext_card)} to "
                    f"extend {partial_kind_phrase(target_before)}.")

        case ShiftDesc(p_card=p_card, stolen=stolen):
            return (f"You can pop the {card_label(stolen)} by shifting "
                    f"the {card_label(p_card)} into the run.")

        case SpliceDesc(loose=loose, source=source):
            # Source is always a length-4+ pure or rb run.
            return (f"You can splice the {card_label(loose)} into a "
                    f"{run_kind_phrase(source)}.")

        case PushDesc(trouble_before=tb, result=result) \
                if classify(result) != "other":
            return f"You can complete a run by absorbing [{stack_label(tb)}]."

        case PushDesc(trouble_before=tb):
            return f"You can tuck [{stack_label(tb)}] back into a run."

        case _:
            return None


def group_kind_phrase(stack):
    """Render the GROUP KIND of a (presumably legal) stack as
    natural language: 'a red-black run', 'a set', etc."""
    kind = classify(stack)
    if kind == "set":
        return "a set"
    if kind == "pure_run":
        return "a pure run"
    if kind == "rb_run":
        return "a red-black run"
    return "a partial"


def partial_kind_phrase(stack):
    """For a 1- or 2-card target (trouble singleton or
    growing 2-partial). Calls out the headline card."""
    n = len(stack)
    if n == 0:
        return "an empty target"
    if n == 1:
        return f"the {card_label(stack[0])}"
    return ("the partial ["
            + " ".join(card_label(c) for c in stack)
            + "]")


def run_kind_phrase(stack):
    """For a length-4+ run (used by splice). Says 'pure run'
    or 'red-black run'."""
    kind = classify(stack)
    if kind == "pure_run":
        return "pure run"
    if kind == "rb_run":
        return "red-black run"
    return "run"


def describe(desc):
    """Render a one-line DSL string for a move."""
    match desc:
        case FreePullDesc(loose=loose, target_bucket_before=bucket,
                          target_before=target_before, result=result,
                          graduated=graduated):
            graduated_str = " [→COMPLETE]" if graduated else ""
            return (f"pull {card_label(loose)} onto {bucket} "
                    f"[{stack_label(target_before)}] → "
                    f"[{stack_label(result)}]{graduated_str}")

        case ExtractAbsorbDesc(verb=verb, ext_card=ext_card,
                               source=source,
                               target_bucket_before=bucket,
                               target_before=target_before,
                               result=result, graduated=graduated,
                               spawned=spawned):
            spawned_str = ""
            if spawned:
                spawned_str = (" ; spawn TROUBLE: "
                               + ", ".join("[" + stack_label(s) + "]"
                                           for s in spawned))
            graduated_str = " [→COMPLETE]" if graduated else ""
            return (f"{verb} {card_label(ext_card)} from HELPER "
                    f"[{stack_label(source)}], "
                    f"absorb onto {bucket} "
                    f"[{stack_label(target_before)}] → "
                    f"[{stack_label(result)}]"
                    f"{graduated_str}{spawned_str}")

        case ShiftDesc(p_card=p_card, stolen=stolen,
                       new_donor=new_donor, new_source=new_source,
                       target_bucket_before=bucket,
                       target_before=target_before, merged=merged,
                       graduated=graduated):
            p = card_label(p_card)
            p_idx = new_source.index(p_card)
            rest = [c for c in new_source if c != p_card]
            rest_label = " ".join(card_label(c) for c in rest)
            shifted = (f"{p} + {rest_label}" if p_idx == 0
                       else f"{rest_label} + {p}")
            graduated_str = " [→COMPLETE]" if graduated else ""
            return (f"shift {p} to pop {card_label(stolen)} "
                    f"[{stack_label(new_donor)} -> {shifted}]; "
                    f"absorb onto {bucket} "
                    f"[{stack_label(target_before)}] → "
                    f"[{stack_label(merged)}]{graduated_str}")

        case SpliceDesc(loose=loose, source=source,
                        left_result=left, right_result=right):
            return (f"splice [{card_label(loose)}] into HELPER "
                    f"[{stack_label(source)}] → "
                    f"[{stack_label(left)}] + [{stack_label(right)}]")

        case PushDesc(trouble_before=tb, target_before=target,
                      result=result):
            return (f"push TROUBLE [{stack_label(tb)}] onto HELPER "
                    f"[{stack_label(target)}] → "
                    f"[{stack_label(result)}]")

        case _:
            return str(desc)
