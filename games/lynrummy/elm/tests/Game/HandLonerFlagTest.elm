module Game.HandLonerFlagTest exposing (suite)

{-| End-to-end check that the sticky hand-loner flag clears when the
player undoes a placement back to a clean board. Drives the real
`Game.update` so it exercises the `ClickUndo` branch AND the `update`
wrapper that re-steps the flag — not just the pure transition (that's
covered in `Lib.ActionLogTest`).
-}

import Expect
import Game
import Game.Model exposing (baseModel)
import Game.Msg exposing (Msg(..))
import Lib.CardStack exposing (BoardCardState(..), BoardLocation, CardStack)
import Lib.GameEvent exposing (GameEvent(..))
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
        ]
