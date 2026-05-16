module Lib.CompleteTurn exposing
    ( CompleteTurnAttempt(..)
    , CompleteTurnOutcome
    , applyCompleteTurn
    , attemptCompleteTurn
    , popupForCompleteTurn
    , statusForCompleteTurn
    )

{-| Everything CompleteTurn: the pure state transition
(`applyCompleteTurn`), the outcome type, the popup/status
content builders that narrate the outcome, and the host-facing
wrapper (`attemptCompleteTurn`) that bundles the transition
with the status / popup / wire payload the UI needs. Mirrors
the Go-side `games/lynrummy/replay.go` `applyCompleteTurn`
step-for-step.

`Lib.Popup` and `Lib.Status` are pure view-chrome (`viewPopup`
/ `viewStatusBar` + the `PopupContent` / `StatusMessage`
records). Outcome-specific content lives here so dependency
arrows run `CompleteTurn → {Popup, Status}` and not the other
way. The companion undo wrapper lives in `Lib.Undo`.

-}

import Game.Util exposing (pluralize)
import Lib.ActionLog exposing (ActionLogEntry)
import Lib.CardStack as CardStack exposing (HandCardState(..))
import Lib.GameEvent as GameEvent
import Lib.GameState exposing (GameState)
import Lib.Hand as Hand
import Lib.Physics.BoardGeometry exposing (BoardBounds, refereeBounds)
import Lib.Player as Player
import Lib.PlayerTurn as PlayerTurn exposing (CompleteTurnResult(..))
import Lib.Popup exposing (PopupContent)
import Lib.Rules.Card exposing (Card)
import Lib.Rules.Referee as Referee
import Lib.Status exposing (StatusKind(..), StatusMessage)


type CompleteTurnAttempt
    = TurnRejected
        { status : StatusMessage
        , popup : PopupContent
        }
    | TurnCompleted
        { newGameState : GameState
        , appendedEntry : ActionLogEntry
        , status : StatusMessage
        , popup : PopupContent
        , outboundPayload : String
        }


attemptCompleteTurn :
    { gameState : GameState, nextSeq : Int }
    -> CompleteTurnAttempt
attemptCompleteTurn { gameState, nextSeq } =
    let
        ( afterTurn, turnOutcome ) =
            applyCompleteTurn refereeBounds gameState

        status =
            statusForCompleteTurn (Ok turnOutcome)

        popup =
            popupForCompleteTurn (Ok turnOutcome)
    in
    case turnOutcome.result of
        Failure ->
            TurnRejected { status = status, popup = popup }

        _ ->
            TurnCompleted
                { newGameState = afterTurn
                , appendedEntry = { action = GameEvent.CompleteTurn }
                , status = status
                , popup = popup
                , outboundPayload = GameEvent.completeTurnDsl nextSeq
                }


{-| What `applyCompleteTurn` produced, beyond the new state:
the outgoing player's classified result and the cards they
drew. All locally computed — no wire round-trip.
-}
type alias CompleteTurnOutcome =
    { result : CompleteTurnResult
    , cardsDrawn : Int
    , dealtCards : List Card
    }


statusForCompleteTurn : Result outcome CompleteTurnOutcome -> StatusMessage
statusForCompleteTurn outcome =
    case outcome of
        Ok o ->
            case o.result of
                Success ->
                    { text = "Turn complete. Board is growing!", kind = Celebrate }

                SuccessButNeedsCards ->
                    { text = "Turn complete, but you didn't play any cards.", kind = Inform }

                SuccessAsVictor ->
                    { text = "Hand emptied — victor!", kind = Celebrate }

                SuccessWithHandEmptied ->
                    { text = "Hand emptied — nice.", kind = Celebrate }

                Failure ->
                    { text = "Board isn't clean — tidy up before ending the turn.", kind = Scold }

        Err _ ->
            { text = "Couldn't reach the server to complete the turn.", kind = Scold }


{-| Build the popup the user should see after a CompleteTurn
attempt. `Err` (wire failure) gets a generic Angry Cat scold;
`Ok` branches into per-result narration.
-}
popupForCompleteTurn : Result outcome CompleteTurnOutcome -> PopupContent
popupForCompleteTurn result =
    case result of
        Ok outcome ->
            popupFromOutcome outcome

        Err _ ->
            { admin = "Angry Cat"
            , body = "Couldn't reach the server to complete your turn."
            }


popupFromOutcome : CompleteTurnOutcome -> PopupContent
popupFromOutcome { result, cardsDrawn } =
    case result of
        Failure ->
            { admin = "Angry Cat"
            , body =
                "The board is not clean!\n\n(nor is my litter box)\n\n"
                    ++ "Drag stacks back where they belong."
            }

        SuccessButNeedsCards ->
            { admin = "Oliver"
            , body =
                "Sorry you couldn't find a move.\n\n"
                    ++ "I'm going back to my nap!\n\n"
                    ++ "We have dealt you "
                    ++ pluralize cardsDrawn "more card"
                    ++ " for your next turn."
            }

        SuccessAsVictor ->
            { admin = "Steve"
            , body =
                "You are the first person to play all their cards!\n\n"
                    ++ "We have dealt you "
                    ++ pluralize cardsDrawn "more card"
                    ++ " for your next turn.\n\n"
                    ++ "Keep winning!"
            }

        SuccessWithHandEmptied ->
            { admin = "Steve"
            , body =
                "Good job — hand emptied!\n\n"
                    ++ "We have dealt you "
                    ++ pluralize cardsDrawn "more card"
                    ++ " for your next turn."
            }

        Success ->
            { admin = "Steve"
            , body = "The board is growing!"
            }


{-| The full CompleteTurn transition, deterministic from the
pre-turn state alone. Produces the post-turn state.

Steps (mirrors Go's applyCompleteTurn exactly):

1.  Classify the turn result using a PlayerTurn accumulator.
2.  Compute and bank the outgoing player's turn score.
3.  If the result awards the victor bonus, flip `victorAwarded`
    so future empty-hand turns don't re-award it.
4.  Reset the outgoing hand's card states to HandNormal, then
    draw N cards from the deck (0/3/5 based on result).
5.  Age board cards (FreshlyPlayed → FreshlyPlayedByLastPlayer
    → FirmlyOnBoard).
6.  Advance `turnIndex`, reset `cardsPlayedThisTurn`, cycle the
    seat, and capture a fresh `turnStartBoardScore` for the
    incoming turn.

No I/O, no randomness — the deck is drawn in order. Callers
who want shuffling seed it before passing it in.

-}
applyCompleteTurn : BoardBounds -> GameState -> ( GameState, CompleteTurnOutcome )
applyCompleteTurn bounds state =
    case Referee.validateTurnComplete state.board bounds of
        Err err ->
            -- Referee said no — the canonical contract is "transition
            -- did not happen." Return state unchanged with a Failure
            -- outcome so callers can branch on it (Main/Play.elm's
            -- clickCompleteTurn already does). Log loudly per
            -- memory/feedback_dont_paper_over_problems.md so the
            -- rejection surfaces; never silently swallow it.
            let
                _ =
                    Debug.log
                        ("[applyCompleteTurn] referee rejected (stage="
                            ++ Referee.refereeStageToString err.stage
                            ++ "): "
                            ++ err.message
                        )
                        ()
            in
            ( state
            , { result = Failure
              , cardsDrawn = 0
              , dealtCards = []
              }
            )

        Ok () ->
            applyValidTurn state


applyValidTurn : GameState -> ( GameState, CompleteTurnOutcome )
applyValidTurn state =
    let
        outgoingHand =
            Hand.activeHand state

        outgoingHandSize =
            Hand.size outgoingHand

        turnBase =
            let
                seed =
                    PlayerTurn.new
            in
            { seed | cardsPlayedDuringTurn = state.cardsPlayedThisTurn }

        turnWithBonuses =
            if outgoingHandSize == 0 && state.cardsPlayedThisTurn > 0 then
                PlayerTurn.noteEmptyHand (not state.victorAwarded) turnBase

            else
                turnBase

        result =
            PlayerTurn.turnResult turnWithBonuses

        drawCount =
            case result of
                SuccessButNeedsCards ->
                    3

                SuccessAsVictor ->
                    5

                SuccessWithHandEmptied ->
                    5

                Success ->
                    0

                Failure ->
                    0

        ( drawnCards, remainingDeck ) =
            takeDeck drawCount state.deck

        newOutgoingHand =
            outgoingHand
                |> Hand.resetState
                |> Hand.addCards drawnCards FreshlyDrawn

        stateWithNewHand =
            Hand.setActiveHand newOutgoingHand state

        newState =
            { stateWithNewHand
                | board = List.map CardStack.agedFromPriorTurn state.board
                , deck = remainingDeck
                , activePlayer = Player.otherPlayer state.activePlayer
                , turnIndex = state.turnIndex + 1
                , cardsPlayedThisTurn = 0
                , victorAwarded = state.victorAwarded || result == SuccessAsVictor
            }

        outcome =
            { result = result
            , cardsDrawn = drawCount
            , dealtCards = drawnCards
            }
    in
    ( newState, outcome )


takeDeck : Int -> List Card -> ( List Card, List Card )
takeDeck n deck =
    if n <= 0 then
        ( [], deck )

    else
        ( List.take n deck, List.drop n deck )
