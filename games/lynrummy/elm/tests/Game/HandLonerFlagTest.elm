module Game.HandLonerFlagTest exposing (suite)

{-| End-to-end checks of the sticky hand-loner flag through the real
`Game.update` — the `ClickUndo` branch, the resume bootstrap, AND the
`update` wrapper that re-steps the flag — not just the pure transition
(that's covered in `Lib.ActionLogTest`).
-}

import Expect
import Game
import Game.Model exposing (baseModel)
import Game.Msg exposing (Msg(..))
import Lib.ActionLog exposing (ActionLogEntry)
import Lib.CardStack exposing (BoardCardState(..), BoardLocation, CardStack, HandCardState(..))
import Lib.GameEvent exposing (GameEvent(..))
import Lib.GameState exposing (GameState)
import Lib.Hand as Hand
import Lib.NonEmpty as NonEmpty
import Lib.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Test exposing (Test, describe, test)


lonerCard : Card
lonerCard =
    { value = Two, suit = Spade, originDeck = DeckOne }


lonerLoc : BoardLocation
lonerLoc =
    { top = 190, left = 375 }


{-| The board holds only the freshly-placed loner. `FreshlyPlayed` is
what `Execute.undoEvent` matches to remove it, so undoing returns the
board to empty (clean).
-}
lonerStack : CardStack
lonerStack =
    { boardCards = [ { card = lonerCard, state = FreshlyPlayed } ]
    , loc = lonerLoc
    }


{-| A model mid-turn: the player has laid `2S` as a loner (flag already
set), and that placement is the one undoable action in the log.
-}
placedLonerModel : Game.Model.Model
placedLonerModel =
    let
        gs =
            baseModel.gameState
    in
    { baseModel
        | gameState = { gs | board = [ lonerStack ], cardsPlayedThisTurn = 1 }
        , actionLog = [ { action = PlaceHand { handCard = lonerCard, loc = lonerLoc } } ]
        , handLonerActive = True
        , nextSeq = 2
    }


{-| A resume bundle shaped like the real Stephen2 game-5 session: the
loner is placed, then cosmetically repositioned. The last log event is
MoveStack, so the wrapper's re-step CARRIES rather than sets — the flag
must come out of the bootstrap fold, not out of the pre-bootstrap model
(whose init default is False).
-}
resumedLonerBundle : ( GameState, List ActionLogEntry )
resumedLonerBundle =
    let
        gs =
            baseModel.gameState

        withLonerInHand =
            Hand.setActiveHand
                (Hand.addHandCards [ { card = lonerCard, state = HandNormal } ]
                    (Hand.activeHand gs)
                )
                gs

        movedLoc =
            { top = 233, left = 542 }
    in
    ( withLonerInHand
    , [ { action = PlaceHand { handCard = lonerCard, loc = lonerLoc } }
      , { action =
            MoveStack
                { stack = lonerStack
                , newLoc = movedLoc
                , boardPath = NonEmpty.singleton { tMs = 0, left = movedLoc.left, top = movedLoc.top }
                }
        }
      ]
    )


suite : Test
suite =
    describe "Game.update — sticky hand-loner flag on Undo"
        [ test "undoing the placement empties the board" <|
            \_ ->
                Game.update ClickUndo placedLonerModel
                    |> Tuple.first
                    |> .gameState
                    |> .board
                    |> Expect.equal []
        , test "undoing back to a clean board clears the sticky loner flag" <|
            \_ ->
                Game.update ClickUndo placedLonerModel
                    |> Tuple.first
                    |> .handLonerActive
                    |> Expect.equal False
        , test "resume bootstrap keeps the fold's flag when the last event is cosmetic" <|
            \_ ->
                Game.update (ActionLogFetched (Ok resumedLonerBundle)) baseModel
                    |> Tuple.first
                    |> .handLonerActive
                    |> Expect.equal True
        ]
