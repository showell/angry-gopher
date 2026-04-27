"""
export_primitives_fixtures.py — capture per-move
verb-to-primitive output as cross-language conformance
fixtures.

Plan-text parity (already covered by `planner_*.dsl`) is
necessary but not sufficient for runtime equivalence between
the Python and Elm BFS+verbs pipelines. The "two Aces" stall
on 2026-04-27 was a verb-to-primitive port-divergence bug —
identical plan text, different primitives, silent stall in
the UI. This generator closes that coverage gap.

Pipeline:
  1. Walk every BFS-solvable mined puzzle.
  2. For each plan step, capture (board_before, move_desc,
     expected_primitives) — the canonical Python output.
  3. Emit:
       a. games/lynrummy/conformance/primitives_fixtures.json
          — language-agnostic record, runner-readable.
       b. games/lynrummy/elm/tests/Game/
          PrimitivesConformanceTest.elm
          — auto-generated elm-test module that decodes the
          fixtures statically and asserts Elm's
          `Game.Agent.Verbs.moveToPrimitives` reproduces the
          same canonical sequence.

The Python runner (`test_primitives_conformance.py`) reads
the JSON directly. Both runners filter MoveStack pre-flights
before comparing — geometry pre-flights live in a separate
post-pass in Elm (`GeometryPlan.planActions`) and inline in
Python (`verbs._plan_split_after`). The verb-layer assertion
is on card-physics primitives only; geometry parity wants its
own test.

Re-run after any change to either side's `verbs.py` /
`Game.Agent.Verbs.elm`:

    python3 tools/export_primitives_fixtures.py
"""

import json
import sqlite3
import sys
from pathlib import Path

DB_PATH = "/home/steve/AngryGopher/prod/gopher.db"
REPO = Path("/home/steve/showell_repos/angry-gopher")
JSON_PATH = REPO / "games/lynrummy/conformance/primitives_fixtures.json"
ELM_PATH = REPO / ("games/lynrummy/elm/tests/Game/"
                   "PrimitivesConformanceTest.elm")

sys.path.insert(0, str(REPO / "games/lynrummy/python"))
import bfs  # noqa: E402
import primitives  # noqa: E402
import verbs  # noqa: E402
from cards import classify  # noqa: E402
from buckets import Buckets  # noqa: E402
from move import (  # noqa: E402
    ExtractAbsorbDesc, FreePullDesc, PushDesc, ShiftDesc, SpliceDesc,
)

RANKS = "A23456789TJQK"
SUITS = "CDSH"


def card_label(c):
    """(value, suit, deck) → 'AC' or 'AC\\'' (deck-1 suffix)."""
    v, s, d = c
    return RANKS[v - 1] + SUITS[s] + ("'" if d else "")


def card_dict_label(cd):
    return card_label((cd["value"], cd["suit"], cd["origin_deck"]))


def stack_labels(stack):
    """wire-shape stack → list of labels."""
    return [card_dict_label(bc["card"]) for bc in stack["board_cards"]]


def cards_to_labels(cards):
    """tuple-list → list of labels."""
    return [card_label(c) for c in cards]


# --- canonical primitive serialization -----------------------

def canonicalize_primitive(prim, sim):
    """Translate one Python (index-based) primitive to a
    content-addressed text form. MoveStack carries its
    pre-move loc in the canonical form so the Elm side has
    to produce the SAME loc — this asserts find_open_loc
    parity end-to-end."""
    kind = prim["action"]
    if kind == "move_stack":
        labels = stack_labels(sim[prim["stack_index"]])
        loc = prim["new_loc"]
        return (f"move_stack [{' '.join(labels)}] -> "
                f"({loc['top']},{loc['left']})")
    if kind == "split":
        labels = stack_labels(sim[prim["stack_index"]])
        return f"split [{' '.join(labels)}]@{prim['card_index']}"
    if kind == "merge_stack":
        src = stack_labels(sim[prim["source_stack"]])
        tgt = stack_labels(sim[prim["target_stack"]])
        side = prim.get("side", "right")
        return (f"merge_stack [{' '.join(src)}] -> "
                f"[{' '.join(tgt)}] /{side}")
    if kind == "merge_hand":
        hc = card_dict_label(prim["hand_card"])
        tgt = stack_labels(sim[prim["target_stack"]])
        side = prim.get("side", "right")
        return (f"merge_hand [{hc}] -> "
                f"[{' '.join(tgt)}] /{side}")
    if kind == "place_hand":
        hc = card_dict_label(prim["hand_card"])
        loc = prim["loc"]
        return f"place_hand [{hc}]@({loc['top']},{loc['left']})"
    raise ValueError(f"unknown prim kind {kind!r}")


# --- desc → JSON -------------------------------------------

def side_str(s):
    """Python desc.side is already 'left'/'right' string."""
    return s


def encode_desc(desc):
    """One BFS desc → JSON record. Mirrors the Elm Move
    constructors field-for-field; the auto-gen template
    decodes it back to a Move on the Elm side."""
    if isinstance(desc, ExtractAbsorbDesc):
        return {
            "kind": "extract_absorb",
            "verb": desc.verb,
            "source": cards_to_labels(desc.source),
            "ext_card": card_label(desc.ext_card),
            "target_before": cards_to_labels(desc.target_before),
            "target_bucket_before": desc.target_bucket_before,
            "result": cards_to_labels(desc.result),
            "side": side_str(desc.side),
            "graduated": desc.graduated,
            "spawned": [cards_to_labels(s) for s in desc.spawned],
        }
    if isinstance(desc, FreePullDesc):
        return {
            "kind": "free_pull",
            "loose": card_label(desc.loose),
            "target_before": cards_to_labels(desc.target_before),
            "target_bucket_before": desc.target_bucket_before,
            "result": cards_to_labels(desc.result),
            "side": side_str(desc.side),
            "graduated": desc.graduated,
        }
    if isinstance(desc, PushDesc):
        return {
            "kind": "push",
            "trouble_before": cards_to_labels(desc.trouble_before),
            "target_before": cards_to_labels(desc.target_before),
            "result": cards_to_labels(desc.result),
            "side": side_str(desc.side),
        }
    if isinstance(desc, SpliceDesc):
        return {
            "kind": "splice",
            "loose": card_label(desc.loose),
            "source": cards_to_labels(desc.source),
            "k": desc.k,
            "side": side_str(desc.side),
            "left_result": cards_to_labels(desc.left_result),
            "right_result": cards_to_labels(desc.right_result),
        }
    if isinstance(desc, ShiftDesc):
        which = "left" if desc.which_end == 0 else "right"
        return {
            "kind": "shift",
            "source": cards_to_labels(desc.source),
            "donor": cards_to_labels(desc.donor),
            "stolen": card_label(desc.stolen),
            "p_card": card_label(desc.p_card),
            "which_end": which,
            "new_source": cards_to_labels(desc.new_source),
            "new_donor": cards_to_labels(desc.new_donor),
            "target_before": cards_to_labels(desc.target_before),
            "target_bucket_before": desc.target_bucket_before,
            "merged": cards_to_labels(desc.merged),
            "side": side_str(desc.side),
            "graduated": desc.graduated,
        }
    raise TypeError(f"unknown desc type {type(desc).__name__}")


def encode_board(board):
    """wire-shape board → list of {loc, cards} records."""
    return [
        {"loc": [s["loc"]["top"], s["loc"]["left"]],
         "cards": stack_labels(s)}
        for s in board
    ]


# --- main pipeline ----------------------------------------

def fixtures_for_puzzle(puzzle_name, state):
    """Walk one puzzle's BFS plan; return list of per-step
    fixture dicts. Returns [] if BFS finds no plan."""
    board = state["board"]  # already wire-shape with locs

    # Build the Buckets state for solve_state_with_descs.
    helper, trouble = [], []
    for s in board:
        cards = [(bc["card"]["value"], bc["card"]["suit"],
                  bc["card"]["origin_deck"])
                 for bc in s["board_cards"]]
        if classify(cards) == "other":
            trouble.append(cards)
        else:
            helper.append(cards)
    initial = Buckets(helper, trouble, [], [])
    plan = bfs.solve_state_with_descs(
        initial, max_trouble_outer=10, max_states=200000,
        verbose=False)
    if plan is None:
        return []

    # Walk the plan. local board advances per primitive so the
    # next step's verbs.move_to_primitives sees the correct
    # post-step board (matching the live agent flow).
    local = [dict(s) for s in board]
    fixtures = []
    for step_num, (_line, desc) in enumerate(plan, 1):
        prims = verbs.move_to_primitives(desc, local)

        # Canonicalize each, advancing local sim between each
        # so canonicalize_primitive's content lookup matches
        # what the primitive actually targeted.
        canonical = []
        sim = local
        for p in prims:
            text = canonicalize_primitive(p, sim)
            canonical.append(text)
            sim = primitives.apply_locally(sim, p)

        fixtures.append({
            "name": f"{puzzle_name}_step_{step_num:02d}",
            "puzzle": puzzle_name,
            "step": step_num,
            "board_before": encode_board(local),
            "move": encode_desc(desc),
            "expect_primitives": canonical,
        })
        local = sim
    return fixtures


def main():
    conn = sqlite3.connect(DB_PATH)
    rows = conn.execute(
        "SELECT puzzle_name, initial_state_json "
        "FROM lynrummy_puzzle_seeds "
        "WHERE puzzle_name LIKE 'mined_%' "
        "ORDER BY puzzle_name").fetchall()

    all_fixtures = []
    for puzzle_name, state_json in rows:
        state = json.loads(state_json)
        all_fixtures.extend(fixtures_for_puzzle(puzzle_name, state))

    JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    JSON_PATH.write_text(json.dumps(all_fixtures, indent=2))
    print(f"wrote {JSON_PATH} ({len(all_fixtures)} fixtures)")

    elm = render_elm_test(all_fixtures)
    ELM_PATH.write_text(elm)
    print(f"wrote {ELM_PATH}")


# --- Elm test rendering ------------------------------------

def elm_card_lit(label):
    """'AC' → '{ value = Ace, suit = Club, originDeck = DeckOne }'.
    'AC\\'' → DeckTwo."""
    base = label.rstrip("'")
    deck = "DeckTwo" if label.endswith("'") else "DeckOne"
    rank_char = base[0]
    suit_char = base[1]
    rank_map = {
        "A": "Ace", "2": "Two", "3": "Three", "4": "Four",
        "5": "Five", "6": "Six", "7": "Seven", "8": "Eight",
        "9": "Nine", "T": "Ten", "J": "Jack", "Q": "Queen",
        "K": "King",
    }
    suit_map = {"C": "Club", "D": "Diamond",
                "S": "Spade", "H": "Heart"}
    return (f"{{ value = {rank_map[rank_char]}, suit = "
            f"{suit_map[suit_char]}, originDeck = {deck} }}")


def elm_stack_lit(labels):
    if not labels:
        return "[]"
    return "[ " + ", ".join(elm_card_lit(l) for l in labels) + " ]"


def elm_side(s):
    return {"left": "LeftSide", "right": "RightSide"}[s]


def elm_bucket(b):
    return {"trouble": "Trouble", "growing": "Growing"}[b]


def elm_verb(v):
    return {
        "peel": "Peel", "pluck": "Pluck", "yank": "Yank",
        "steal": "Steal", "split_out": "SplitOut",
    }[v]


def elm_which_end(w):
    return {"left": "LeftEnd", "right": "RightEnd"}[w]


def elm_bool(b):
    return "True" if b else "False"


def elm_loc(loc):
    top, left = loc
    return f"{{ top = {top}, left = {left} }}"


def elm_board_stacks_lit(board_before, indent):
    """Render the [CardStack] literal at the given leading-
    space indent (so continuation lines line up with the
    opening `[`)."""
    pad = " " * indent
    parts = []
    for stack in board_before:
        labels_lit = elm_stack_lit(stack["cards"])
        loc_lit = elm_loc(stack["loc"])
        parts.append(f"boardStack {loc_lit} {labels_lit}")
    if not parts:
        return "[]"
    head = "[ " + parts[0]
    if len(parts) == 1:
        return head + " ]"
    rest = "".join(f"\n{pad}, {p}" for p in parts[1:])
    return head + rest + f"\n{pad}]"


def elm_spawned_lit(spawned):
    if not spawned:
        return "[]"
    parts = [elm_stack_lit(s) for s in spawned]
    return "[ " + ", ".join(parts) + " ]"


def elm_move_lit(move, indent):
    """Render the Elm Move constructor at the given indent —
    the constructor name on the first line, fields starting
    at indent+2 (Elm's `{` lines up two right of the parent
    expression). Caller supplies indent of the constructor."""
    pad = " " * (indent + 2)
    k = move["kind"]

    def field_block(rows):
        first = f"{{ {rows[0]}"
        if len(rows) == 1:
            return f"{first} }}"
        rest = "".join(f"\n{pad}, {r}" for r in rows[1:])
        return f"{first}{rest}\n{pad}}}"

    if k == "extract_absorb":
        rows = [
            f"verb = {elm_verb(move['verb'])}",
            f"source = {elm_stack_lit(move['source'])}",
            f"extCard = {elm_card_lit(move['ext_card'])}",
            f"targetBefore = {elm_stack_lit(move['target_before'])}",
            f"targetBucketBefore = {elm_bucket(move['target_bucket_before'])}",
            f"result = {elm_stack_lit(move['result'])}",
            f"side = {elm_side(move['side'])}",
            f"graduated = {elm_bool(move['graduated'])}",
            f"spawned = {elm_spawned_lit(move['spawned'])}",
        ]
        return f"ExtractAbsorb\n{pad}{field_block(rows)}"
    if k == "free_pull":
        rows = [
            f"loose = {elm_card_lit(move['loose'])}",
            f"targetBefore = {elm_stack_lit(move['target_before'])}",
            f"targetBucketBefore = {elm_bucket(move['target_bucket_before'])}",
            f"result = {elm_stack_lit(move['result'])}",
            f"side = {elm_side(move['side'])}",
            f"graduated = {elm_bool(move['graduated'])}",
        ]
        return f"FreePull\n{pad}{field_block(rows)}"
    if k == "push":
        rows = [
            f"troubleBefore = {elm_stack_lit(move['trouble_before'])}",
            f"targetBefore = {elm_stack_lit(move['target_before'])}",
            f"result = {elm_stack_lit(move['result'])}",
            f"side = {elm_side(move['side'])}",
        ]
        return f"Push\n{pad}{field_block(rows)}"
    if k == "splice":
        rows = [
            f"loose = {elm_card_lit(move['loose'])}",
            f"source = {elm_stack_lit(move['source'])}",
            f"k = {move['k']}",
            f"side = {elm_side(move['side'])}",
            f"leftResult = {elm_stack_lit(move['left_result'])}",
            f"rightResult = {elm_stack_lit(move['right_result'])}",
        ]
        return f"Splice\n{pad}{field_block(rows)}"
    if k == "shift":
        rows = [
            f"source = {elm_stack_lit(move['source'])}",
            f"donor = {elm_stack_lit(move['donor'])}",
            f"stolen = {elm_card_lit(move['stolen'])}",
            f"pCard = {elm_card_lit(move['p_card'])}",
            f"whichEnd = {elm_which_end(move['which_end'])}",
            f"newSource = {elm_stack_lit(move['new_source'])}",
            f"newDonor = {elm_stack_lit(move['new_donor'])}",
            f"targetBefore = {elm_stack_lit(move['target_before'])}",
            f"targetBucketBefore = {elm_bucket(move['target_bucket_before'])}",
            f"merged = {elm_stack_lit(move['merged'])}",
            f"side = {elm_side(move['side'])}",
            f"graduated = {elm_bool(move['graduated'])}",
        ]
        return f"Shift\n{pad}{field_block(rows)}"
    raise ValueError(f"unknown move kind {k!r}")


def elm_expect_lit(prims, indent):
    """Render expected primitive list as one-string-per-line."""
    pad = " " * indent
    if not prims:
        return "[]"
    head = f"[ {json.dumps(prims[0])}"
    if len(prims) == 1:
        return head + " ]"
    rest = "".join(f"\n{pad}, {json.dumps(p)}" for p in prims[1:])
    return head + rest + f"\n{pad}]"


def render_fixture_record(fix):
    """One Elm record literal for the fixtures list.

    Layout: 4-space indent before `{`, fields aligned at
    column 6 with a leading `, ` for continuations. Nested
    list literals (board, expected) get their own indent so
    continuation lines stay inside the outer record."""
    name_lit = json.dumps(fix["name"])
    board_lit = elm_board_stacks_lit(fix["board_before"], indent=12)
    move_lit = elm_move_lit(fix["move"], indent=10)
    expected_lit = elm_expect_lit(fix["expect_primitives"], indent=12)
    return (
        f"      {{ name = {name_lit}\n"
        f"      , board =\n"
        f"            {board_lit}\n"
        f"      , move =\n"
        f"          {move_lit}\n"
        f"      , expected =\n"
        f"            {expected_lit}\n"
        f"      }}"
    )


def render_elm_test(fixtures):
    if fixtures:
        first, *rest = fixtures
        records = render_fixture_record(first)
        for f in rest:
            records += "\n    , " + render_fixture_record(f).lstrip()
        records_block = f"    [ {records.lstrip()}\n    ]"
    else:
        records_block = "    []"
    return f"""-- AUTO-GENERATED by tools/export_primitives_fixtures.py
-- DO NOT EDIT. Regenerate after any change to verbs.py /
-- Game.Agent.Verbs.elm.


module Game.PrimitivesConformanceTest exposing (suite)

import Expect
import Game.Agent.GeometryPlan as GeometryPlan
import Game.Agent.Move as Move
    exposing
        ( ExtractVerb(..)
        , Move(..)
        , Side(..)
        , SourceBucket(..)
        , WhichEnd(..)
        )
import Game.Agent.Verbs as Verbs
import Game.BoardActions as BA
import Game.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack exposing (BoardCard, BoardCardState(..), CardStack)
import Game.WireAction exposing (WireAction(..))
import Test exposing (Test, describe, test)


{{-| One per-step fixture mirrors the JSON in
    `games/lynrummy/conformance/primitives_fixtures.json`.
    Both runners (this module + `test_primitives_conformance.py`)
    assert that their `moveToPrimitives` reproduces `expected`
    exactly — MoveStack pre-flights filtered out (those live
    in `GeometryPlan.planActions` / `_plan_split_after`).
-}}
type alias Fixture =
    {{ name : String
    , board : List CardStack
    , move : Move
    , expected : List String
    }}


fixtures : List Fixture
fixtures =
{records_block}


suite : Test
suite =
    describe
        "Game.Agent.Verbs.moveToPrimitives — primitive-emission parity"
        (List.map runFixture fixtures)


runFixture : Fixture -> Test
runFixture f =
    test f.name <|
        \\_ ->
            Verbs.moveToPrimitives f.board f.move
                |> GeometryPlan.planActions f.board
                |> List.filterMap canonicalize
                |> Expect.equal f.expected


{{-| Mirrors `canonicalize_primitive` in
    `tools/export_primitives_fixtures.py`. MoveStack carries
    its destination loc — Elm and Python's `findOpenLoc`
    must agree exactly for any text-equal comparison.
-}}
canonicalize : WireAction -> Maybe String
canonicalize action =
    case action of
        Split {{ stack, cardIndex }} ->
            Just
                ("split ["
                    ++ stackLabels stack
                    ++ "]@"
                    ++ String.fromInt cardIndex
                )

        MergeStack {{ source, target, side }} ->
            Just
                ("merge_stack ["
                    ++ stackLabels source
                    ++ "] -> ["
                    ++ stackLabels target
                    ++ "] /"
                    ++ wireSideStr side
                )

        MergeHand {{ handCard, target, side }} ->
            Just
                ("merge_hand ["
                    ++ cardLabel handCard
                    ++ "] -> ["
                    ++ stackLabels target
                    ++ "] /"
                    ++ wireSideStr side
                )

        PlaceHand {{ handCard, loc }} ->
            Just
                ("place_hand ["
                    ++ cardLabel handCard
                    ++ "]@("
                    ++ String.fromInt loc.top
                    ++ ","
                    ++ String.fromInt loc.left
                    ++ ")"
                )

        MoveStack {{ stack, newLoc }} ->
            Just
                ("move_stack ["
                    ++ stackLabels stack
                    ++ "] -> ("
                    ++ String.fromInt newLoc.top
                    ++ ","
                    ++ String.fromInt newLoc.left
                    ++ ")"
                )

        CompleteTurn ->
            Nothing

        Undo ->
            Nothing


wireSideStr : BA.Side -> String
wireSideStr s =
    case s of
        BA.Left ->
            "left"

        BA.Right ->
            "right"


cardLabel : Card -> String
cardLabel c =
    rankChar c.value
        ++ suitChar c.suit
        ++ deckSuffix c.originDeck


rankChar : CardValue -> String
rankChar v =
    case v of
        Ace ->
            "A"

        Two ->
            "2"

        Three ->
            "3"

        Four ->
            "4"

        Five ->
            "5"

        Six ->
            "6"

        Seven ->
            "7"

        Eight ->
            "8"

        Nine ->
            "9"

        Ten ->
            "T"

        Jack ->
            "J"

        Queen ->
            "Q"

        King ->
            "K"


suitChar : Suit -> String
suitChar s =
    case s of
        Club ->
            "C"

        Diamond ->
            "D"

        Spade ->
            "S"

        Heart ->
            "H"


deckSuffix : OriginDeck -> String
deckSuffix d =
    case d of
        DeckOne ->
            ""

        DeckTwo ->
            "'"


stackLabels : CardStack -> String
stackLabels stack =
    String.join " "
        (List.map (\\bc -> cardLabel bc.card) stack.boardCards)


boardStack : {{ top : Int, left : Int }} -> List Card -> CardStack
boardStack loc cards =
    {{ boardCards =
        List.map
            (\\c -> {{ card = c, state = FirmlyOnBoard }})
            cards
    , loc = loc
    }}
"""


if __name__ == "__main__":
    main()
