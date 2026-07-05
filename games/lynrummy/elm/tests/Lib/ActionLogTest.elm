module Lib.ActionLogTest exposing (suite)

import Expect
import Lib.ActionLog as ActionLog exposing (ActionLogEntry)
import Lib.BoardActions exposing (Side(..))
import Lib.CardStack exposing (BoardCardState(..), CardStack)
import Lib.GameEvent exposing (GameEvent(..))
import Lib.NonEmpty as NonEmpty
import Lib.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Test exposing (Test, describe, test)


card : Card
card =
    { value = Two, suit = Spade, originDeck = DeckOne }


aStack : CardStack
aStack =
    { boardCards = [ { card = card, state = FirmlyOnBoard } ]
    , loc = { top = 20, left = 20 }
    }


placeHand : GameEvent
placeHand =
    PlaceHand { handCard = card, loc = { top = 190, left = 375 } }


mergeHand : GameEvent
mergeHand =
    MergeHand { handCard = card, target = aStack, side = Right }


{-| A cosmetic reposition — the flag must look past it. -}
moveStack : GameEvent
moveStack =
    MoveStack
        { stack = aStack
        , newLoc = { top = 30, left = 40 }
        , boardPath = NonEmpty.singleton { tMs = 0, left = 20, top = 20 }
        }


log : List GameEvent -> List ActionLogEntry
log =
    List.map (\action -> { action = action })


suite : Test
suite =
    describe "Lib.ActionLog.lastMoveWasHandLoner"
        [ test "a bare PlaceHand is a loner" <|
            \_ ->
                ActionLog.lastMoveWasHandLoner (log [ placeHand ])
                    |> Expect.equal True
        , test "a cosmetic MoveStack after the placement is ignored" <|
            \_ ->
                ActionLog.lastMoveWasHandLoner (log [ placeHand, moveStack ])
                    |> Expect.equal True
        , test "a structural move after the placement supersedes it" <|
            \_ ->
                ActionLog.lastMoveWasHandLoner (log [ placeHand, mergeHand ])
                    |> Expect.equal False
        , test "an Undo cancels the placement" <|
            \_ ->
                ActionLog.lastMoveWasHandLoner (log [ placeHand, Undo ])
                    |> Expect.equal False
        , test "an empty log is not a loner" <|
            \_ ->
                ActionLog.lastMoveWasHandLoner []
                    |> Expect.equal False
        , test "a cosmetic-only log is not a loner" <|
            \_ ->
                ActionLog.lastMoveWasHandLoner (log [ moveStack ])
                    |> Expect.equal False
        ]
