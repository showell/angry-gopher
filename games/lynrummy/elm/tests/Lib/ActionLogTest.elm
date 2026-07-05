module Lib.ActionLogTest exposing (suite)

import Expect
import Lib.ActionLog as ActionLog
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


split : GameEvent
split =
    Split { stack = aStack, leftCount = 1 }


mergeStack : GameEvent
mergeStack =
    MergeStack
        { source = aStack
        , target = aStack
        , side = Right
        , boardPath = NonEmpty.singleton { tMs = 0, left = 20, top = 20 }
        }


{-| A cosmetic reposition — the flag must look past it. -}
moveStack : GameEvent
moveStack =
    MoveStack
        { stack = aStack
        , newLoc = { top = 30, left = 40 }
        , boardPath = NonEmpty.singleton { tMs = 0, left = 20, top = 20 }
        }


{-| Step the flag forward through a sequence, given for each event whether
the board is clean AFTER it. Seeds the flag at False (a fresh, clean board).
-}
run : List ( Bool, GameEvent ) -> Bool
run steps =
    List.foldl
        (\( clean, event ) flag -> ActionLog.stepHandLonerFlag clean event flag)
        False
        steps


suite : Test
suite =
    describe "Lib.ActionLog.stepHandLonerFlag"
        [ test "placing a hand card onto the board sets the flag" <|
            \_ ->
                run [ ( False, placeHand ) ]
                    |> Expect.equal True
        , test "the flag survives board moves used to build the loner up (game 4)" <|
            \_ ->
                -- place 6H loner, split 5S off the spade run, merge it on:
                -- the board stays dirty throughout, so the flag must persist
                -- even though the LAST event is a board->board merge.
                run [ ( False, placeHand ), ( False, split ), ( False, mergeStack ) ]
                    |> Expect.equal True
        , test "a cosmetic reposition after the placement is ignored" <|
            \_ ->
                run [ ( False, placeHand ), ( False, moveStack ) ]
                    |> Expect.equal True
        , test "completing the board (clean) clears the flag" <|
            \_ ->
                run [ ( False, placeHand ), ( True, mergeStack ) ]
                    |> Expect.equal False
        , test "a direct hand-to-stack play that cleans the board clears it" <|
            \_ ->
                run [ ( False, placeHand ), ( True, mergeHand ) ]
                    |> Expect.equal False
        , test "board-origin dirt (split) with no prior placement never sets it" <|
            \_ ->
                run [ ( False, split ) ]
                    |> Expect.equal False
        , test "a placement onto a still-dirty board keeps it set" <|
            \_ ->
                -- split dirties the board (flag stays False, board-origin),
                -- then a hand loner lands: now it's set.
                run [ ( False, split ), ( False, placeHand ) ]
                    |> Expect.equal True
        , test "no events leaves the seed value (clean board, not a loner)" <|
            \_ ->
                run []
                    |> Expect.equal False
        , test "re-stepping a stable (event, dirty board) is idempotent" <|
            \_ ->
                -- the update wrapper re-runs the step on every message; a
                -- non-mutating message re-applies the last event unchanged.
                ActionLog.stepHandLonerFlag False mergeStack (run [ ( False, placeHand ), ( False, mergeStack ) ])
                    |> Expect.equal True
        ]
