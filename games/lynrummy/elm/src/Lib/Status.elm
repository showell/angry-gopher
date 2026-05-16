module Lib.Status exposing
    ( StatusKind(..)
    , StatusMessage
    , actionLogFetchFailedStatus
    , actionRejectedStatus
    , geometryFeedback
    , handNothingStatus
    , mergeStatus
    , offBoardScold
    , sessionAllocFailedStatus
    , statusForCompleteTurn
    , viewStatusBar
    )

{-| Status messages, the helpers that build them, and the
status-bar renderer. -}

import Lib.CardStack as CardStack exposing (CardStack)
import Lib.CompleteTurn exposing (CompleteTurnOutcome)
import Lib.Physics.BoardGeometry as BoardGeometry exposing (BoardGeometryStatus(..))
import Lib.PlayerTurn exposing (CompleteTurnResult(..))
import Lib.Rules.Card
import Lib.Rules.StackType as StackType
import Html exposing (Html, div)
import Html.Attributes exposing (style)


type StatusKind
    = Inform
    | Celebrate
    | Scold


type alias StatusMessage =
    { text : String, kind : StatusKind }


viewStatusBar : StatusMessage -> Html msg
viewStatusBar status =
    let
        color =
            case status.kind of
                Inform ->
                    "#31708f"

                Celebrate ->
                    "green"

                Scold ->
                    "red"
    in
    div
        [ style "padding" "6px 20px"
        , style "font-size" "15px"
        , style "color" color
        , style "border-bottom" "1px solid #eee"
        , style "white-space" "pre-wrap"
        ]
        [ Html.text status.text ]


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


{-| Surface a board-geometry tidiness change as a status
message, or `Nothing` if there's nothing geometry-relevant to
say. Returns `Just (Celebrate)` when a Crowded board became
CleanlySpaced, `Just (Scold)` when the action left the board
Crowded (regardless of where it came from), `Nothing` otherwise
— callers fall back to their action-specific status.

Mirrors the post-hook in angry-cat's
`process_and_push_player_action`. When a feedback fires it
overrides the primary message, matching the TS order-of-
operations.

-}
geometryFeedback : List CardStack -> List CardStack -> Maybe StatusMessage
geometryFeedback oldBoard newBoard =
    case
        ( BoardGeometry.classifyBoardGeometry oldBoard BoardGeometry.refereeBounds
        , BoardGeometry.classifyBoardGeometry newBoard BoardGeometry.refereeBounds
        )
    of
        ( Crowded, CleanlySpaced ) ->
            Just { text = "Nice and tidy!", kind = Celebrate }

        ( _, Crowded ) ->
            Just
                { text = "Board is getting tight — try spacing stacks out!"
                , kind = Scold
                }

        _ ->
            Nothing


{-| The merge outcome depends on the size of the newly-merged
stack (always the last entry of the post board, by reducer
convention) and whether the whole post board is clean.
-}
mergeStatus : List CardStack -> StatusMessage
mergeStatus board =
    case List.reverse board of
        [] ->
            { text = "Merged.", kind = Inform }

        mergedStack :: _ ->
            if CardStack.size mergedStack < 3 then
                { text = "Nice, but where's the third card?", kind = Scold }

            else if isCleanBoard board then
                { text = "Combined! Clean board!", kind = Celebrate }

            else
                { text = "Combined!", kind = Celebrate }


{-| Every stack classifies as a valid group (Set / PureRun /
RedBlackRun). Mirrors the TS `CurrentBoard.is_clean()`.
-}
isCleanBoard : List CardStack -> Bool
isCleanBoard board =
    List.all (stackCards >> StackType.getStackType >> isCompleteType) board


stackCards : CardStack -> List Lib.Rules.Card.Card
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


offBoardScold : StatusMessage
offBoardScold =
    { text = "Don't knock cards off the board, please. You're not a cat!"
    , kind = Scold
    }


handNothingStatus : StatusMessage
handNothingStatus =
    { text = "Drop on a stack to merge, or on open space to place."
    , kind = Inform
    }


actionRejectedStatus : StatusMessage
actionRejectedStatus =
    { text = "Server rejected action — check console; state may be out of sync."
    , kind = Scold
    }


sessionAllocFailedStatus : StatusMessage
sessionAllocFailedStatus =
    { text = "Could not allocate a session — check console."
    , kind = Scold
    }


actionLogFetchFailedStatus : StatusMessage
actionLogFetchFailedStatus =
    { text = "Could not load action log — check console."
    , kind = Scold
    }
