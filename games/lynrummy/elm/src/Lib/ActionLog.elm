module Lib.ActionLog exposing
    ( ActionLogEntry
    , collapseUndos
    , lastMoveWasHandLoner
    )

import Lib.GameEvent exposing (GameEvent(..))


type alias ActionLogEntry =
    { action : GameEvent }


{-| True iff the player's most recent NON-COSMETIC action was laying a
hand card onto an empty spot (a `PlaceHand` loner). Cosmetic moves —
`MoveStack` repositioning — are ignored, and `Undo` tokens are
collapsed first. This is the one fact the solver needs to prefer
finishing the board with board cards before projecting more hand
cards (see hand_play.ts `handLonerPlaced`). A bare boolean suffices:
the solver can only sign off a play when every stack ends legal, so it
doesn't need the loner's identity.
-}
lastMoveWasHandLoner : List ActionLogEntry -> Bool
lastMoveWasHandLoner entries =
    case lastNonCosmeticAction (collapseUndos entries) of
        Just (PlaceHand _) ->
            True

        _ ->
            False


lastNonCosmeticAction : List ActionLogEntry -> Maybe GameEvent
lastNonCosmeticAction entries =
    entries
        |> List.map .action
        |> List.filter (not << isCosmetic)
        |> List.foldl (\action _ -> Just action) Nothing


isCosmetic : GameEvent -> Bool
isCosmetic action =
    case action of
        MoveStack _ ->
            True

        _ ->
            False


{-| Collapse `Undo` tokens against the actions they cancel,
producing the effective action sequence — what replay and
bootstrap should actually apply.

Each `Undo` cancels the most recent non-Undo entry. The
algorithm walks the reversed log left-to-right counting
pending undos: an `Undo` increments the counter; any other
entry either cancels a pending undo (if the counter is
positive) or survives (consed onto `accum` in original
order).

If the log finishes with `pendingUndos > 0`, that's a
contract violation — the input has more undo tokens than
undoable actions — and we panic rather than silently drop
the extras.

`CompleteTurn` is not special-cased here: it can be
undone like any other action. The UI gate against undoing
across a turn boundary lives in `Lib.Undo.lastUndoableAction`,
which is where it belongs (it's a UX policy, not a data
invariant).

-}
collapseUndos : List ActionLogEntry -> List ActionLogEntry
collapseUndos entries =
    let
        ( accum, pendingUndos ) =
            List.foldl
                (\entry ( kept, pending ) ->
                    case entry.action of
                        Undo ->
                            ( kept, pending + 1 )

                        _ ->
                            if pending > 0 then
                                ( kept, pending - 1 )

                            else
                                ( entry :: kept, pending )
                )
                ( [], 0 )
                (List.reverse entries)
    in
    if pendingUndos > 0 then
        Debug.todo
            ("Lib.ActionLog.collapseUndos: "
                ++ String.fromInt pendingUndos
                ++ " unmatched Undo token(s) in the log"
            )

    else
        accum
