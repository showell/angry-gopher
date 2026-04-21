module Main.Apply exposing
    ( applyAction
    , refereeBounds
    )

{-| The pure state-transition layer of the Elm client.
`applyAction` is the single entry point for applying a
validated action to the Model — same function whether the
input came from a local gesture, a replay tick, or a wire
broadcast. "Capture the input, update the data structure,
re-draw the view."

The (board, hand) half of each physics transition delegates to
`Game.Reducer.applyAction`. This module's job is the
Model-level wrapping: Score recomputation, the
`cardsPlayedThisTurn` counter, and the full `CompleteTurn`
transition via `Game.applyCompleteTurn`.

-}

import Game.BoardGeometry as BoardGeometry
import Game.Game as Game
import Game.Reducer as Reducer
import Game.Score as Score
import Game.WireAction as WA exposing (WireAction)
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



-- APPLY ACTION


{-| Apply a validated WireAction to the Model. Exhaustive
dispatch over the seven variants.

  - `Split`, `MergeStack`, `MoveStack` — board-only physics.
  - `MergeHand`, `PlaceHand` — board + hand physics; each
    releases one hand card, so increment
    `cardsPlayedThisTurn`.
  - `CompleteTurn` — full autonomous turn transition via
    `Game.applyCompleteTurn`, then UI-layer `score` + `status`.
  - `Undo` — no-op (V1 has no Undo button; deferred).

The physics branches all share `applyPhysics`: delegate the
(board, hand) transition to `Reducer.applyAction`, then thread
the result back through the Model.

-}
applyAction : WireAction -> Model -> Model
applyAction action model =
    case action of
        WA.Split _ ->
            applyPhysics action model

        WA.MergeStack _ ->
            applyPhysics action model

        WA.MergeHand _ ->
            applyPhysics action model |> Game.noteCardsPlayed 1

        WA.PlaceHand _ ->
            applyPhysics action model |> Game.noteCardsPlayed 1

        WA.MoveStack _ ->
            applyPhysics action model

        WA.CompleteTurn ->
            applyCompleteTurn model

        WA.Undo ->
            model



-- PHYSICS


{-| Delegate the (board, hand) transition to
`Game.Reducer.applyAction`, then rebuild the Model with
the UI-layer wrappers: Score recompute + active-hand
write-back. Covers the five physics actions.

No-ops (bad target stack, bad hand card reference) land back
here with `post` equal to the input `pre`, so the writes are
idempotent — same board, same hand, same score.

-}
applyPhysics : WireAction -> Model -> Model
applyPhysics action model =
    let
        pre =
            { board = model.board, hand = activeHand model }

        post =
            Reducer.applyAction action pre
    in
    setActiveHand post.hand
        { model
            | board = post.board
            , score = Score.forStacks post.board
        }



-- COMPLETE TURN


applyCompleteTurn : Model -> Model
applyCompleteTurn model =
    let
        afterTurn =
            Game.applyCompleteTurn model
    in
    { afterTurn
        | score = Score.forStacks afterTurn.board
        , status =
            { text =
                "Turn "
                    ++ String.fromInt (afterTurn.turnIndex + 1)
                    ++ " — Player "
                    ++ String.fromInt (afterTurn.activePlayerIndex + 1)
                    ++ " to play."
            , kind = Celebrate
            }
    }
