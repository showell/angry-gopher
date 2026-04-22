module Game.Game exposing
    ( CompleteTurnOutcome
    , GameState
    , applyCompleteTurn
    , noteCardsPlayed
    )

{-| The autonomous LynRummy game state and its pure transitions.

This is the core of the client — the full game logic that can
run standalone without any server. Mirrors the Go-side
`games/lynrummy/replay.go` `applyCompleteTurn`, but with the
Elm primitives already in place (`Game.Score`,
`Game.PlayerTurn`, `Game.Hand`, `CardStack.agedFromPriorTurn`).

The `GameState` is defined as an extensible record so the host
Model (Main.elm) can embed these fields alongside its UI-only
ones (drag, popup, replay progress) and call transitions
without unwrapping.

Intentional divergence from Go: `applyCompleteTurn` takes a
pre-decided `Bool` for whether this empty-hand wins are awarded
to the incoming party. In the Go path that decision flows from
`state.VictorAwarded`; same here, stored on the record.

-}

import Game.Card exposing (Card)
import Game.CardStack as CardStack exposing (CardStack, HandCardState(..))
import Game.Hand as Hand exposing (Hand)
import Game.PlayerTurn as PlayerTurn exposing (CompleteTurnResult(..))
import Game.Score as Score


{-| Every field required to run a full LynRummy game. Open
record — host models can add UI-only fields (drag state, popup,
replay progress, etc.) and still pass themselves to these
transitions.
-}
type alias GameState a =
    { a
        | board : List CardStack
        , hands : List Hand
        , scores : List Int
        , activePlayerIndex : Int
        , turnIndex : Int
        , deck : List Card
        , cardsPlayedThisTurn : Int
        , victorAwarded : Bool
        , turnStartBoardScore : Int
    }


{-| Increment `cardsPlayedThisTurn` by `n`. Call once per
hand-card release (merge_hand adds 1; place_hand adds 1;
trick_result adds n where n is the number of cards released).
-}
noteCardsPlayed : Int -> GameState a -> GameState a
noteCardsPlayed n state =
    { state | cardsPlayedThisTurn = state.cardsPlayedThisTurn + n }


{-| What `applyCompleteTurn` produced, beyond the new state:
the outgoing player's classified result, the points they
banked, the cards they drew. All locally computed — no wire
round-trip. The server's /complete-turn response is a
projection of the same shape (and will diverge only if the
client and server disagree on the game's history, which
should never happen).
-}
type alias CompleteTurnOutcome =
    { result : CompleteTurnResult
    , turnScore : Int
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
applyCompleteTurn : GameState a -> ( GameState a, CompleteTurnOutcome )
applyCompleteTurn state =
    let
        outgoingIdx =
            state.activePlayerIndex

        outgoingHandSize =
            listAt outgoingIdx state.hands
                |> Maybe.map Hand.size
                |> Maybe.withDefault 0

        boardScore =
            Score.forStacks state.board

        -- Build a PlayerTurn accumulator for classification +
        -- score summing. Load in the cards-played counter the
        -- state has been tracking.
        turnBase =
            let
                seed =
                    PlayerTurn.new state.turnStartBoardScore
            in
            { seed
                | cardsPlayedDuringTurn = state.cardsPlayedThisTurn
            }

        turnWithBonuses =
            if outgoingHandSize == 0 && state.cardsPlayedThisTurn > 0 then
                PlayerTurn.updateScoreForEmptyHand
                    (not state.victorAwarded)
                    turnBase

            else
                turnBase

        result =
            PlayerTurn.turnResult turnWithBonuses

        turnScore =
            PlayerTurn.getScore boardScore turnWithBonuses

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

        newScores =
            List.indexedMap
                (\i s ->
                    if i == outgoingIdx then
                        s + turnScore

                    else
                        s
                )
                state.scores

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
                , scores = newScores
                , activePlayerIndex = nextActive
                , turnIndex = state.turnIndex + 1
                , cardsPlayedThisTurn = 0
                , turnStartBoardScore = boardScore
                , victorAwarded = state.victorAwarded || result == SuccessAsVictor
            }

        outcome =
            { result = result
            , turnScore = turnScore
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
