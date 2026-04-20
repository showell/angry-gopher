module Main.Apply exposing
    ( applyChange
    , applyWireAction
    , findHandCard
    , refereeBounds
    )

{-| The pure state-transition layer of the Elm client.
`applyWireAction` is the single entry point for applying a
validated WireAction to the Model — same function whether the
input came from a local gesture, a replay tick, or a wire
broadcast. "Capture the input, update the data structure,
re-draw the view."

Extracted 2026-04-19 from the pre-split `Main.elm` during the
refactor that unwound the monolith. Pure: no I/O, no Msg, no
rendering, no subscriptions. Its only external effects are
producing new Model values.

-}

import LynRummy.BoardActions as BoardActions exposing (Side(..))
import LynRummy.BoardGeometry as BoardGeometry
import LynRummy.Card exposing (Card)
import LynRummy.CardStack as CardStack exposing (BoardLocation, CardStack, HandCard, stacksEqual)
import LynRummy.Game as Game
import LynRummy.GestureArbitration as GA
import LynRummy.Hand as Hand exposing (Hand)
import LynRummy.Score as Score
import LynRummy.WireAction as WA exposing (WireAction)
import Main.State exposing (Model, StatusKind(..), activeHand, setActiveHand)



-- BOUNDS CONSTANT


{-| Bounds the client's referee uses to validate end-of-turn
layouts. Matches the server's constant (see
`views/lynrummy_elm.go` — the CompleteTurn handler uses the
same 800 × 600, margin 5). Kept in one place so client and
server agree on what "clean" means.
-}
refereeBounds : BoardGeometry.BoardBounds
refereeBounds =
    { maxWidth = 800, maxHeight = 600, margin = 5 }



-- APPLY WIRE ACTION


{-| Apply a validated WireAction to the Model. Dispatches on
the action kind; each branch produces a new Model.

Branch behaviour summary:

  - `Split` — split a board stack in two at `cardIndex`.
  - `MergeStack` — try cross-stack merge via
    `BoardActions.tryStackMerge`; succeeds or no-ops.
  - `MergeHand` — hand card onto a board stack, counts toward
    `cardsPlayedThisTurn`.
  - `PlaceHand` — hand card as a new stack at a loc, counts
    toward `cardsPlayedThisTurn`.
  - `MoveStack` — reposition a stack; no card movement.
  - `CompleteTurn` — delegates to `Game.applyCompleteTurn` for
    the full autonomous transition (classify, bank, deal,
    flip, age), then updates UI-layer `score` + `status`.
  - `Undo` — no-op (deferred; V1 has no Undo button).
  - `PlayTrick` — no-op (retired wire action; if one appears
    in a log, ignore).

-}
applyWireAction : WireAction -> Model -> Model
applyWireAction action model =
    case action of
        WA.Split { stackIndex, cardIndex } ->
            let
                newBoard =
                    GA.applySplit stackIndex cardIndex model.board
            in
            { model | board = newBoard, score = Score.forStacks newBoard }

        WA.MergeStack { sourceStack, targetStack, side } ->
            case ( listAt sourceStack model.board, listAt targetStack model.board ) of
                ( Just source, Just target ) ->
                    case BoardActions.tryStackMerge target source side of
                        Just change ->
                            let
                                newBoard =
                                    applyChange change model.board
                            in
                            { model
                                | board = newBoard
                                , score = Score.forStacks newBoard
                            }

                        Nothing ->
                            model

                _ ->
                    model

        WA.MergeHand { handCard, targetStack, side } ->
            applyHandOntoStack handCard targetStack side model
                |> Game.noteCardsPlayed 1

        WA.PlaceHand { handCard, loc } ->
            applyPlaceHandCard handCard loc model
                |> Game.noteCardsPlayed 1

        WA.MoveStack { stackIndex, newLoc } ->
            case listAt stackIndex model.board of
                Just stack ->
                    let
                        change =
                            BoardActions.moveStack stack newLoc

                        newBoard =
                            applyChange change model.board
                    in
                    { model | board = newBoard, score = Score.forStacks newBoard }

                Nothing ->
                    model

        WA.CompleteTurn ->
            let
                afterTurn =
                    Game.applyCompleteTurn model

                nextActive =
                    afterTurn.activePlayerIndex

                nextTurn =
                    afterTurn.turnIndex
            in
            { afterTurn
                | score = Score.forStacks afterTurn.board
                , status =
                    { text =
                        "Turn "
                            ++ String.fromInt (nextTurn + 1)
                            ++ " — Player "
                            ++ String.fromInt (nextActive + 1)
                            ++ " to play."
                    , kind = Celebrate
                    }
            }

        WA.Undo ->
            model

        WA.PlayTrick _ ->
            model



-- MERGE HELPERS


{-| Hand-card-onto-stack merge, with a synthetic fallback when
the target hand doesn't contain the card (replay of a seat
whose hand is server-dealt and not mirrored client-side). Board
advances either way; hand only mutates when we have a real
tracked HandCard to remove.
-}
applyHandOntoStack : Card -> Int -> Side -> Model -> Model
applyHandOntoStack card targetStack side model =
    case listAt targetStack model.board of
        Just target ->
            let
                hand =
                    activeHand model

                ( hc, mutateHand ) =
                    case findHandCard card hand of
                        Just real ->
                            ( real, True )

                        Nothing ->
                            ( { card = card, state = CardStack.HandNormal }, False )
            in
            case BoardActions.tryHandMerge target hc side of
                Just change ->
                    let
                        newBoard =
                            applyChange change model.board

                        withBoard =
                            { model | board = newBoard, score = Score.forStacks newBoard }
                    in
                    if mutateHand then
                        setActiveHand (Hand.removeHandCard hc hand) withBoard

                    else
                        withBoard

                Nothing ->
                    model

        Nothing ->
            model


applyPlaceHandCard : Card -> BoardLocation -> Model -> Model
applyPlaceHandCard card loc model =
    let
        hand =
            activeHand model

        ( hc, mutateHand ) =
            case findHandCard card hand of
                Just real ->
                    ( real, True )

                Nothing ->
                    ( { card = card, state = CardStack.HandNormal }, False )

        change =
            BoardActions.placeHandCard hc loc

        newBoard =
            applyChange change model.board

        withBoard =
            { model | board = newBoard, score = Score.forStacks newBoard }
    in
    if mutateHand then
        setActiveHand (Hand.removeHandCard hc hand) withBoard

    else
        withBoard



-- BOARD UPDATE + HAND LOOKUP


{-| Remove-then-add semantics for a `BoardActions.BoardChange`
against a board. Stacks in `stacksToRemove` (matched by
`stacksEqual`) are filtered out; `stacksToAdd` is appended at
the end. Positional shift is intentional — merged stacks end
up as the last element, which lets downstream code find "just
changed" stacks at a predictable position.
-}
applyChange : BoardActions.BoardChange -> List CardStack -> List CardStack
applyChange change board =
    List.filter (\s -> not (List.any (stacksEqual s) change.stacksToRemove)) board
        ++ change.stacksToAdd


{-| Find a hand card whose Card identity (value + suit +
origin_deck) matches. First match wins. Returns `Nothing` when
the hand doesn't contain the card — which happens legitimately
during replay of a seat whose hand is server-dealt and not
mirrored client-side. Callers use `Nothing` as a signal to
build a synthetic HandCard and apply the board change without
touching the hand.
-}
findHandCard : Card -> Hand -> Maybe HandCard
findHandCard card hand =
    hand.handCards
        |> List.filter (\hc -> hc.card == card)
        |> List.head



-- INTERNAL


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)
