"""
move.py — BFS desc dataclasses + rendering (describe_move,
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
from cards import classify, label_d


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
    return " ".join(label_d(c) for c in stack)


def narrate(desc):
    """Evocative one-liner for a move, communicating INTENT
    rather than mechanics. Steve-facing: this is how Claude
    narrates what the agent is doing in the verbose-mode
    log. Each move type gets a verb-forward phrasing at the
    human chunk level (engulf, splice, pop, tuck, ...).

    For exact structural matching, use `describe_move`. For
    the vague hint a human PLAYER would see in the UI, use
    `hint`.
    """
    if isinstance(desc, FreePullDesc):
        loose = label_d(desc.loose)
        result = stack_label(desc.result)
        check = " ✓" if desc.graduated else ""
        return f"pull {loose} into [{result}]{check}"

    if isinstance(desc, ExtractAbsorbDesc):
        verb = desc.verb
        ec = label_d(desc.ext_card)
        result = stack_label(desc.result)
        check = " ✓" if desc.graduated else ""
        spawned = ""
        if desc.spawned:
            spawned = (" (leaves "
                       + ", ".join("[" + stack_label(s) + "]"
                                   for s in desc.spawned)
                       + " homeless)")
        return f"{verb} {ec} → [{result}]{check}{spawned}"

    if isinstance(desc, ShiftDesc):
        p = label_d(desc.p_card)
        stolen = label_d(desc.stolen)
        merged = stack_label(desc.merged)
        check = " ✓" if desc.graduated else ""
        return f"{p} pops {stolen} → [{merged}]{check}"

    if isinstance(desc, SpliceDesc):
        loose = label_d(desc.loose)
        left = stack_label(desc.left_result)
        right = stack_label(desc.right_result)
        return f"splice {loose} → [{left}] + [{right}]"

    if isinstance(desc, PushDesc):
        tb = stack_label(desc.trouble_before)
        target = stack_label(desc.target_before)
        result = stack_label(desc.result)
        # Engulf-shape vs plain push: plain push extends a
        # helper by 1-2 cards; engulf swallows a helper into a
        # complete stack (graduated from GROWING).
        if classify(desc.result) != "other":
            return f"engulf [{target}] into [{tb}] → [{result}] ✓"
        return f"tuck [{tb}] into [{target}] → [{result}]"

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
    if isinstance(desc, FreePullDesc):
        loose = label_d(desc.loose)
        kind = group_kind_phrase(desc.result)
        return f"You can pull the {loose} onto {kind}."

    if isinstance(desc, ExtractAbsorbDesc):
        verb = desc.verb
        ec = label_d(desc.ext_card)
        target_kind = partial_kind_phrase(desc.target_before)
        return f"You can {verb} the {ec} to extend {target_kind}."

    if isinstance(desc, ShiftDesc):
        p = label_d(desc.p_card)
        stolen = label_d(desc.stolen)
        return (f"You can pop the {stolen} by shifting "
                f"the {p} into the run.")

    if isinstance(desc, SpliceDesc):
        loose = label_d(desc.loose)
        # Source is always a length-4+ pure or rb run.
        run_kind = run_kind_phrase(desc.source)
        return f"You can splice the {loose} into a {run_kind}."

    if isinstance(desc, PushDesc):
        tb = stack_label(desc.trouble_before)
        if classify(desc.result) != "other":
            return f"You can complete a run by absorbing [{tb}]."
        return f"You can tuck [{tb}] back into a run."

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
        return f"the {label_d(stack[0])}"
    return ("the partial ["
            + " ".join(label_d(c) for c in stack)
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


def describe_move(desc):
    """Render a one-line DSL string for a move."""
    if isinstance(desc, FreePullDesc):
        loose = label_d(desc.loose)
        bucket = desc.target_bucket_before
        tb = stack_label(desc.target_before)
        result = stack_label(desc.result)
        graduated = " [→COMPLETE]" if desc.graduated else ""
        return (f"pull {loose} onto {bucket} [{tb}] → "
                f"[{result}]{graduated}")
    if isinstance(desc, ExtractAbsorbDesc):
        verb = desc.verb
        ec = label_d(desc.ext_card)
        src = stack_label(desc.source)
        bucket = desc.target_bucket_before
        tb = stack_label(desc.target_before)
        result = stack_label(desc.result)
        spawned = ""
        if desc.spawned:
            spawned = (" ; spawn TROUBLE: "
                       + ", ".join("[" + stack_label(s) + "]"
                                   for s in desc.spawned))
        graduated = " [→COMPLETE]" if desc.graduated else ""
        return (f"{verb} {ec} from HELPER [{src}], "
                f"absorb onto {bucket} [{tb}] → "
                f"[{result}]{graduated}{spawned}")
    if isinstance(desc, ShiftDesc):
        p = label_d(desc.p_card)
        stolen = label_d(desc.stolen)
        new_donor = stack_label(desc.new_donor)
        new_source = desc.new_source
        p_idx = new_source.index(desc.p_card)
        rest = [c for c in new_source if c != desc.p_card]
        rest_label = " ".join(label_d(c) for c in rest)
        if p_idx == 0:
            shifted = f"{p} + {rest_label}"
        else:
            shifted = f"{rest_label} + {p}"
        bucket = desc.target_bucket_before
        tb = stack_label(desc.target_before)
        merged = stack_label(desc.merged)
        graduated = " [→COMPLETE]" if desc.graduated else ""
        return (f"shift {p} to pop {stolen} "
                f"[{new_donor} -> {shifted}]; "
                f"absorb onto {bucket} [{tb}] → "
                f"[{merged}]{graduated}")
    if isinstance(desc, SpliceDesc):
        loose = label_d(desc.loose)
        src = stack_label(desc.source)
        left = stack_label(desc.left_result)
        right = stack_label(desc.right_result)
        return (f"splice [{loose}] into HELPER [{src}] → "
                f"[{left}] + [{right}]")
    if isinstance(desc, PushDesc):
        tb = stack_label(desc.trouble_before)
        target = stack_label(desc.target_before)
        result = stack_label(desc.result)
        return (f"push TROUBLE [{tb}] onto HELPER [{target}] → "
                f"[{result}]")
    return str(desc)
