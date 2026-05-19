module Lib.GameEvent exposing
    ( GameEvent(..)
    , completeTurnDsl
    , isolateDsl
    , mergeHandDsl
    , mergeStackDsl
    , moveStackDsl
    , placeHandDsl
    , splitCardIndexFromLeftCount
    , splitDsl
    , undoDsl
    )

{-| The fundamental player-action vocabulary of Lyn Rummy.
Each value names a thing the player did — Split, MergeStack,
MergeHand, PlaceHand, MoveStack, CompleteTurn, Undo. The
post-state is derived by applying the event to the prior
state; events are diffless.

Stacks are referenced by their **full ordered card list**
(`cards`, `source_cards`, `target_cards`), not by positional
index. Cards are globally unique in the double deck, so a card
list identifies a stack unambiguously AND stays stable under
the reducer's reordering.

Per-event wire emitters live here. Each dispatch site already
has earned knowledge of which event fired, so it calls the
specific encoder (no GameEvent value built just to re-dispatch
on it). The matching parser lives in `Lib.WireAction`.

Grammar — each line is `N) action_body[ :: path (...)]`.
Stack references on most events carry their loc inline; split
and isolate show their result chunks directly (no loc needed —
cards are globally unique so they identify the source stack):

    44) move_stack [A♥ 2♥ 3♥'] at (10,53) -> (22,300) :: path (10,53@0)(22,300@500)
    45) merge_stack [4♦'] at (407,200) -> [4♠ 4♣'] at (200,100) /right :: path (...)
    46) split 2♦' / 3♠' 4♦'
    47) isolate 2♦' ( 3♠' ) 4♦'
    48) merge_hand 7♥' -> [7♠ 7♦ 7♣] at (107,52) /right
    49) place_hand 7♥' -> (400,300)
    50) complete_turn
    51) undo

The held card in isolate is parenthesized; end positions drop
the empty side:

    52) isolate ( 7♥' ) 8♥' 9♥'    (held at left end)
    53) isolate 7♥' 8♥' ( 9♥' )    (held at right end)

-}

import Lib.BoardActions exposing (Side(..))
import Lib.CardStack exposing (BoardLocation, CardStack)
import Lib.NonEmpty as NonEmpty exposing (NonEmpty)
import Lib.Rules.Card as Card exposing (Card)
import Lib.TimeLoc exposing (TimeLoc)


type GameEvent
    = Split { stack : CardStack, cardIndex : Int }
    | Isolate { stack : CardStack, cardIndex : Int }
    | MergeStack { source : CardStack, target : CardStack, side : Side, boardPath : NonEmpty TimeLoc }
    | MergeHand { handCard : Card, target : CardStack, side : Side }
    | PlaceHand { handCard : Card, loc : BoardLocation }
    | MoveStack { stack : CardStack, newLoc : BoardLocation, boardPath : NonEmpty TimeLoc }
    | CompleteTurn
    | Undo



-- PER-EVENT WIRE EMITTERS


splitDsl : Int -> CardStack -> Int -> String
splitDsl seq stack cardIndex =
    let
        cards =
            List.map .card stack.boardCards

        leftCount =
            splitLeftCount cardIndex (List.length cards)

        left =
            List.take leftCount cards

        right =
            List.drop leftCount cards
    in
    seqPrefix seq
        ++ "split "
        ++ cardListStr left
        ++ " / "
        ++ cardListStr right


isolateDsl : Int -> CardStack -> Int -> String
isolateDsl seq stack cardIndex =
    let
        cards =
            List.map .card stack.boardCards

        before =
            List.take cardIndex cards

        held =
            cards |> List.drop cardIndex |> List.take 1

        after =
            List.drop (cardIndex + 1) cards

        beforePart =
            if List.isEmpty before then
                ""

            else
                " " ++ cardListStr before

        afterPart =
            if List.isEmpty after then
                ""

            else
                " " ++ cardListStr after
    in
    seqPrefix seq
        ++ "isolate"
        ++ beforePart
        ++ " ( "
        ++ cardListStr held
        ++ " )"
        ++ afterPart


{-| Number of cards in the LEFT piece after a split at `cardIndex`
of a stack of size `n`. Mirrors the asymmetric rule in
`Lib.CardStack.split` and `ts/game_events/primitives.ts:applySplit`.
-}
splitLeftCount : Int -> Int -> Int
splitLeftCount cardIndex n =
    if cardIndex + 1 <= n // 2 then
        cardIndex + 1

    else
        cardIndex


{-| Inverse of `splitLeftCount` — recover the GameEvent cardIndex
from the left-piece length on the wire.
-}
splitCardIndexFromLeftCount : Int -> Int -> Int
splitCardIndexFromLeftCount leftCount n =
    if leftCount <= n // 2 then
        leftCount - 1

    else
        leftCount


mergeStackDsl : Int -> CardStack -> CardStack -> Side -> NonEmpty TimeLoc -> String
mergeStackDsl seq source target side boardPath =
    seqPrefix seq
        ++ "merge_stack "
        ++ stackRef source
        ++ " -> "
        ++ stackRef target
        ++ " /"
        ++ sideStr side
        ++ pathSuffix boardPath


mergeHandDsl : Int -> Card -> CardStack -> Side -> String
mergeHandDsl seq handCard target side =
    seqPrefix seq
        ++ "merge_hand "
        ++ Card.cardStr handCard
        ++ " -> "
        ++ stackRef target
        ++ " /"
        ++ sideStr side


placeHandDsl : Int -> Card -> BoardLocation -> String
placeHandDsl seq handCard loc =
    seqPrefix seq
        ++ "place_hand "
        ++ Card.cardStr handCard
        ++ " -> "
        ++ locStr loc


moveStackDsl : Int -> CardStack -> BoardLocation -> NonEmpty TimeLoc -> String
moveStackDsl seq stack newLoc boardPath =
    seqPrefix seq
        ++ "move_stack "
        ++ stackRef stack
        ++ " -> "
        ++ locStr newLoc
        ++ pathSuffix boardPath


completeTurnDsl : Int -> String
completeTurnDsl seq =
    seqPrefix seq ++ "complete_turn"


undoDsl : Int -> String
undoDsl seq =
    seqPrefix seq ++ "undo"



-- SHARED INTERNALS


seqPrefix : Int -> String
seqPrefix n =
    String.fromInt n ++ ") "


stackRef : CardStack -> String
stackRef s =
    "[" ++ cardListStr (List.map .card s.boardCards) ++ "] at " ++ locStr s.loc


cardListStr : List Card -> String
cardListStr cards =
    String.join " " (List.map Card.cardStr cards)


locStr : BoardLocation -> String
locStr loc =
    "(" ++ String.fromInt loc.left ++ "," ++ String.fromInt loc.top ++ ")"


sideStr : Side -> String
sideStr s =
    case s of
        Left ->
            "left"

        Right ->
            "right"


pathSuffix : NonEmpty TimeLoc -> String
pathSuffix path =
    " :: path " ++ String.concat (List.map timeLocStr (NonEmpty.toList path))


timeLocStr : TimeLoc -> String
timeLocStr t =
    "(" ++ String.fromInt t.left ++ "," ++ String.fromInt t.top ++ "@" ++ String.fromInt t.tMs ++ ")"
