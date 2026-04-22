module Main.Apply exposing
    ( applyAction
    , commit
    , refereeBounds
    )

{-| The pure state-transition layer of the Elm client.
`applyAction` is the single entry point for applying a
validated action to the Model — same function whether the
input came from a local gesture, a replay tick, or a wire
broadcast. "Capture the input, update the data structure,
re-draw the view."

Each call returns an `ActionOutcome`: the new Model alongside
the `StatusMessage` that describes what just happened. The
status is generated at the same point the mutation is
performed — colocated with the physics, not inferred
post-hoc by a separate classifier. Callers decide whether to
use the status (human actions do; replay ignores).

The (board, hand) half of each physics transition delegates to
`Game.Reducer.applyAction`. This module's job is the
Model-level wrapping: Score recomputation, the
`cardsPlayedThisTurn` counter, the full `CompleteTurn`
transition via `Game.applyCompleteTurn`, and the per-action
status message.

-}

import Game.BoardGeometry as BoardGeometry exposing (BoardGeometryStatus(..))
import Game.Card
import Game.CardStack as CardStack exposing (CardStack)
import Game.Game as Game
import Game.Reducer as Reducer
import Game.Score as Score
import Game.StackType as StackType
import Game.WireAction as WA exposing (WireAction)
import Main.State as State
    exposing
        ( ActionOutcome
        , Model
        , StatusKind(..)
        , StatusMessage
        , activeHand
        , setActiveHand
        )



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
dispatch over the seven variants. Each branch returns an
`ActionOutcome` — the new Model plus the status message that
describes the outcome — generated at the point of mutation.

  - `Split`, `MergeStack`, `MoveStack` — board-only physics.
  - `MergeHand`, `PlaceHand` — board + hand physics; each
    releases one hand card, so increment
    `cardsPlayedThisTurn`.
  - `CompleteTurn` — full autonomous turn transition via
    `Game.applyCompleteTurn`.
  - `Undo` — no-op (V1 has no Undo button; deferred).

The physics branches all share `applyPhysics`: delegate the
(board, hand) transition to `Reducer.applyAction`, then thread
the result back through the Model.

-}
applyAction : WireAction -> Model -> ActionOutcome
applyAction action model =
    case action of
        WA.Split _ ->
            let
                next =
                    applyPhysics action model
            in
            { model = next
            , status = withTidinessOverlay model next splitStatus
            }

        WA.MergeStack _ ->
            let
                next =
                    applyPhysics action model
            in
            { model = next
            , status = withTidinessOverlay model next (mergeStatus next)
            }

        WA.MergeHand _ ->
            let
                next =
                    applyPhysics action model |> Game.noteCardsPlayed 1
            in
            { model = next
            , status = withTidinessOverlay model next (mergeStatus next)
            }

        WA.PlaceHand _ ->
            let
                next =
                    applyPhysics action model |> Game.noteCardsPlayed 1
            in
            { model = next
            , status = withTidinessOverlay model next placeHandStatus
            }

        WA.MoveStack _ ->
            let
                next =
                    applyPhysics action model
            in
            { model = next
            , status = withTidinessOverlay model next moveStackStatus
            }

        WA.CompleteTurn ->
            applyCompleteTurn model

        WA.Undo ->
            { model = model, status = undoStatus }



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


applyCompleteTurn : Model -> ActionOutcome
applyCompleteTurn model =
    let
        ( afterTurn, _ ) =
            Game.applyCompleteTurn model

        withScore =
            { afterTurn | score = Score.forStacks afterTurn.board }
    in
    { model = withScore
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



-- OUTCOME CONSUMPTION


{-| Collapse an `ActionOutcome` to a Model by writing the
outcome's status into the Model's status field. The standard
way human-driven callers "accept" an outcome. Replay callers,
which want to keep their own status text ("Replaying…"), skip
this and take `outcome.model` directly.
-}
commit : ActionOutcome -> Model
commit outcome =
    let
        m =
            outcome.model
    in
    { m | status = outcome.status }



-- STATUS MESSAGES
--
-- Lifted from angry-cat/src/lyn_rummy/game/game.ts:2044-2076.
-- Kept verbatim so feel matches the TS original. Each message
-- is built from post-mutation model data that the applyAction
-- branch above has in hand when it calls these helpers — no
-- post-hoc board-diffing.


splitStatus : StatusMessage
splitStatus =
    { text = "Be careful with splitting! Splits only pay off when you get more cards on the board or make prettier piles."
    , kind = Scold
    }


placeHandStatus : StatusMessage
placeHandStatus =
    { text = "On the board!", kind = Inform }


moveStackStatus : StatusMessage
moveStackStatus =
    { text = "Moved!", kind = Inform }


undoStatus : StatusMessage
undoStatus =
    { text = "Undone.", kind = Inform }


{-| Layer the board-tidiness overlay onto the primary action
status. If a CROWDED board became CLEANLY_SPACED, celebrate
the recovery; if the action left the board in a CROWDED state
(regardless of where it came from), scold. Otherwise the
primary message stands.

Mirrors the post-hook in angry-cat's
`process_and_push_player_action`. Overlay OVERRIDES the
primary message when it fires, matching the TS order-of-
operations.
-}
withTidinessOverlay : Model -> Model -> StatusMessage -> StatusMessage
withTidinessOverlay pre post primary =
    case
        ( BoardGeometry.classifyBoardGeometry pre.board refereeBounds
        , BoardGeometry.classifyBoardGeometry post.board refereeBounds
        )
    of
        ( Crowded, CleanlySpaced ) ->
            { text = "Nice and tidy!", kind = Celebrate }

        ( _, Crowded ) ->
            { text = "Board is getting tight — try spacing stacks out!"
            , kind = Scold
            }

        _ ->
            primary


{-| The merge outcome depends on the size of the newly-merged
stack (always the last entry of the post board, by reducer
convention), whether the whole post board is clean, and — on
a clean-board celebration — the player's board-delta for the
turn so far.
-}
mergeStatus : Model -> StatusMessage
mergeStatus post =
    case List.reverse post.board of
        [] ->
            { text = "Merged.", kind = Inform }

        mergedStack :: _ ->
            if CardStack.size mergedStack < 3 then
                { text = "Nice, but where's the third card?", kind = Scold }

            else if isCleanBoard post.board then
                { text = cleanBoardMessage "Combined! Clean board!" post
                , kind = Celebrate
                }

            else
                { text = "Combined!", kind = Celebrate }


{-| Append the turn's board-score delta to a celebratory
prefix, mirroring the TS `clean_board_message` helper. Shows
the player how much they gained on the board this turn —
meaningful after a merge that closed out a meld.
-}
cleanBoardMessage : String -> Model -> String
cleanBoardMessage prefix post =
    let
        delta =
            post.score - post.turnStartBoardScore
    in
    prefix ++ " Your board delta for this turn is " ++ String.fromInt delta ++ "."


{-| Every stack classifies as a valid group (Set / PureRun /
RedBlackRun). Mirrors the TS `CurrentBoard.is_clean()`.
-}
isCleanBoard : List CardStack -> Bool
isCleanBoard board =
    List.all (stackCards >> StackType.getStackType >> isCompleteType) board


stackCards : CardStack -> List Game.Card.Card
stackCards stack =
    List.map .card stack.boardCards


isCompleteType : StackType.CardStackType -> Bool
isCompleteType t =
    case t of
        StackType.Set ->
            True

        StackType.PureRun ->
            True

        StackType.RedBlackRun ->
            True

        StackType.Incomplete ->
            False

        StackType.Bogus ->
            False

        StackType.Dup ->
            False
