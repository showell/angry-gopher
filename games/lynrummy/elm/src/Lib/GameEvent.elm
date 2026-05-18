module Lib.GameEvent exposing
    ( GameEvent(..)
    , completeTurnDsl
    , eventDsl
    , mergeHandDsl
    , mergeStackDsl
    , moveStackDsl
    , placeHandDsl
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

Per-event wire emitters live here. The default is to call the
specific encoder at each dispatch site, where the caller has
earned knowledge of which event fired (no GameEvent value
built just to re-dispatch on it). For sites that *receive* a
List GameEvent from outside (e.g. the agent's turn-step
response from the TS engine), `eventDsl` is the explicit
dispatcher. The matching parser lives in `Lib.WireAction`.

Grammar — each line is `N) action_body[ :: path (...)]`,
where stack references carry their loc inline so the parser
stays stateless:

    44) move_stack [A♥ 2♥ 3♥'] at (10,53) -> (22,300) :: path (10,53@0)(22,300@500)
    45) merge_stack [4♦'] at (407,200) -> [4♠ 4♣'] at (200,100) /right :: path (...)
    46) split [2♦' 3♠' 4♦'] at (332,52) @2
    47) merge_hand 7♥' -> [7♠ 7♦ 7♣] at (107,52) /right
    48) place_hand 7♥' -> (400,300)
    49) complete_turn
    50) undo

-}

import Lib.BoardActions exposing (Side(..))
import Lib.CardStack exposing (BoardLocation, CardStack)
import Lib.NonEmpty as NonEmpty exposing (NonEmpty)
import Lib.Rules.Card as Card exposing (Card)
import Lib.TimeLoc exposing (TimeLoc)


type GameEvent
    = Split { stack : CardStack, cardIndex : Int }
    | MergeStack { source : CardStack, target : CardStack, side : Side, boardPath : NonEmpty TimeLoc }
    | MergeHand { handCard : Card, target : CardStack, side : Side }
    | PlaceHand { handCard : Card, loc : BoardLocation }
    | MoveStack { stack : CardStack, newLoc : BoardLocation, boardPath : NonEmpty TimeLoc }
    | CompleteTurn
    | Undo



-- PER-EVENT WIRE EMITTERS


splitDsl : Int -> CardStack -> Int -> String
splitDsl seq stack cardIndex =
    seqPrefix seq
        ++ "split "
        ++ stackRef stack
        ++ " @"
        ++ String.fromInt cardIndex


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


{-| Dispatch a GameEvent onto its matching per-variant emitter.
Use this only when you have a GameEvent value handed to you
from elsewhere (e.g. an engine response, a replay buffer); at
sites where you're producing the event yourself, call the
specific encoder directly.
-}
eventDsl : Int -> GameEvent -> String
eventDsl seq event =
    case event of
        Split p ->
            splitDsl seq p.stack p.cardIndex

        MergeStack p ->
            mergeStackDsl seq p.source p.target p.side p.boardPath

        MoveStack p ->
            moveStackDsl seq p.stack p.newLoc p.boardPath

        MergeHand p ->
            mergeHandDsl seq p.handCard p.target p.side

        PlaceHand p ->
            placeHandDsl seq p.handCard p.loc

        CompleteTurn ->
            completeTurnDsl seq

        Undo ->
            undoDsl seq



-- SHARED INTERNALS


seqPrefix : Int -> String
seqPrefix n =
    String.fromInt n ++ ") "


stackRef : CardStack -> String
stackRef s =
    "["
        ++ String.join " " (List.map (.card >> Card.cardStr) s.boardCards)
        ++ "] at "
        ++ locStr s.loc


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
