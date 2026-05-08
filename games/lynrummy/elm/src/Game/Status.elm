module Game.Status exposing
    ( StatusKind(..)
    , StatusMessage
    , geometryFeedback
    , mergeStatus
    , offBoardScold
    )

{-| Status messages and the helpers that build them. -}

import Game.CardStack as CardStack exposing (CardStack)
import Game.Physics.BoardGeometry as BoardGeometry exposing (BoardGeometryStatus(..))
import Game.Rules.Card
import Game.Rules.StackType as StackType


type alias StatusMessage =
    { text : String, kind : StatusKind }


type StatusKind
    = Inform
    | Celebrate
    | Scold


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


stackCards : CardStack -> List Game.Rules.Card.Card
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
