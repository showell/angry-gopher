module Lib.Game exposing
    ( CompleteTurnOutcome
    , applyCompleteTurn
    )

{-| The autonomous LynRummy game state and its pure transitions.

This is the core of the client — the full game logic that can
run standalone without any server. Mirrors the Go-side
`games/lynrummy/replay.go` `applyCompleteTurn`, with the Elm
primitives in place (`Lib.PlayerTurn`, `Lib.Hand`,
`CardStack.agedFromPriorTurn`).

The `GameState` is defined as an extensible record so the host
Model (Game.elm) can embed these fields alongside its UI-only
ones (drag, popup, replay progress) and call transitions
without unwrapping.

Intentional divergence from Go: `applyCompleteTurn` takes a
pre-decided `Bool` for whether this empty-hand wins are awarded
to the incoming party. In the Go path that decision flows from
`state.VictorAwarded`; same here, stored on the record.

-}

import Lib.CardStack as CardStack exposing (HandCardState(..))
import Lib.GameState exposing (GameState)
import Lib.Hand as Hand
import Lib.Physics.BoardGeometry exposing (BoardBounds)
import Lib.PlayerTurn as PlayerTurn exposing (CompleteTurnResult(..))
import Lib.Rules.Card exposing (Card)
import Lib.Rules.Referee as Referee


{-| What `applyCompleteTurn` produced, beyond the new state:
the outgoing player's classified result and the cards they
drew. All locally computed — no wire round-trip.
-}
type alias CompleteTurnOutcome =
    { result : CompleteTurnResult
    , cardsDrawn : Int
    , dealtCards : List Card
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
        outgoingIdx =
            state.activePlayerIndex

        outgoingHandSize =
            case listAt outgoingIdx state.hands of
                Just h ->
                    Hand.size h

                Nothing ->
                    let
                        _ =
                            Debug.log
                                ("[applyValidTurn] no hand at active index "
                                    ++ String.fromInt outgoingIdx
                                    ++ " (have "
                                    ++ String.fromInt (List.length state.hands)
                                    ++ " hands) — bridge bug"
                                )
                                ()
                    in
                    0

        -- Build a PlayerTurn accumulator for classification.
        -- Load in the cards-played counter the state has been
        -- tracking.
        turnBase =
            let
                seed =
                    PlayerTurn.new
            in
            { seed
                | cardsPlayedDuringTurn = state.cardsPlayedThisTurn
            }

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

        -- Outgoing player: reset card states, then draw.
        ( newOutgoingHand, remainingDeck, drawnCards ) =
            case listAt outgoingIdx state.hands of
                Just h ->
                    let
                        reset =
                            Hand.resetState h

                        ( cards, leftover ) =
                            takeDeck drawCount state.deck

                        afterDraw =
                            Hand.addCards cards FreshlyDrawn reset
                    in
                    ( afterDraw, leftover, cards )

                Nothing ->
                    let
                        _ =
                            Debug.log
                                ("[applyValidTurn] outgoing player at index "
                                    ++ String.fromInt outgoingIdx
                                    ++ " has no hand record — skipping draw (bridge bug)"
                                )
                                ()
                    in
                    ( { handCards = [] }, state.deck, [] )

        newHands =
            List.indexedMap
                (\i h ->
                    if i == outgoingIdx then
                        newOutgoingHand

                    else
                        h
                )
                state.hands

        agedBoard =
            List.map CardStack.agedFromPriorTurn state.board

        nHands =
            max 1 (List.length state.hands)

        nextActive =
            modBy nHands (outgoingIdx + 1)

        newState =
            { state
                | board = agedBoard
                , hands = newHands
                , deck = remainingDeck
                , activePlayerIndex = nextActive
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



-- HELPERS


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)


takeDeck : Int -> List Card -> ( List Card, List Card )
takeDeck n deck =
    if n <= 0 then
        ( [], deck )

    else
        ( List.take n deck, List.drop n deck )
