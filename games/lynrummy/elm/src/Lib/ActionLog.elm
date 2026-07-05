module Lib.ActionLog exposing
    ( ActionLogEntry
    , collapseUndos
    , stepHandLonerFlag
    )

import Lib.GameEvent exposing (GameEvent(..))


type alias ActionLogEntry =
    { action : GameEvent }


{-| One transition of the sticky "an unresolved hand-origin loner sits on
the board" flag, given the event just applied and whether the resulting
board is fully legal.

The flag exists because the solver should finish a hand-origin loner with
BOARD cards rather than projecting more hand cards onto the already-dirty
board (see hand_play.ts `handLonerPlaced`). Provenance is historical — it
cannot be read off the current board — so the flag lives in the model and
is stepped forward here:

  - Laying a hand card onto the board (`PlaceHand`) SETS it. `PlaceHand`
    always leaves a one-card (incomplete) stack, so the board is dirty and
    the set sticks.
  - It STAYS set through any subsequent board manipulation (split, merge,
    peel, cosmetic reposition) — those carry `wasActive` unchanged. This is
    what the older "last non-cosmetic move" heuristic got wrong: building a
    loner up with board moves knocked the flag out.
  - It CLEARS the instant the board returns to fully legal (`boardClean`),
    however that happened — including the player completing the last stack
    with a direct hand-card-to-stack play.

A bare boolean suffices: the solver can only sign off a play when every
stack ends legal, so it never needs the loner's identity.

Idempotent under a stable (event, board), so it is safe to re-run after
every update against the log's most recent event.
-}
stepHandLonerFlag : Bool -> GameEvent -> Bool -> Bool
stepHandLonerFlag boardClean event wasActive =
    if boardClean then
        False

    else
        case event of
            PlaceHand _ ->
                True

            _ ->
                wasActive


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
