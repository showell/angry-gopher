module Game.ActionLog exposing
    ( ActionLogBundle
    , ActionLogEntry
    , collapseUndos
    )

import Game.Game exposing (GameState)
import Game.GameEvent exposing (GameEvent(..))


type alias ActionLogEntry =
    { action : GameEvent }


type alias ActionLogBundle =
    { initialState : GameState
    , actions : List ActionLogEntry
    }


{-| Collapse `Undo` tokens: each Undo cancels the most recent
non-`CompleteTurn` entry. The result is the effective action
sequence — what replay and bootstrap should actually apply.

Used by the full-game `bootstrapFromBundle` (to fold only
effective actions), `clickInstantReplay` (so replay never
animates Undo tokens), and the puzzle host's redo-from-initial
on undo. Puzzle logs never contain `CompleteTurn`, so the
turn-boundary guard is a no-op there — same function works for
both hosts.

-}
collapseUndos : List ActionLogEntry -> List ActionLogEntry
collapseUndos entries =
    List.foldl
        (\entry stack ->
            case entry.action of
                Undo ->
                    popLastUndoable stack

                _ ->
                    stack ++ [ entry ]
        )
        []
        entries


popLastUndoable : List ActionLogEntry -> List ActionLogEntry
popLastUndoable entries =
    case List.reverse entries of
        [] ->
            entries

        last :: rest ->
            case last.action of
                CompleteTurn ->
                    entries

                _ ->
                    List.reverse rest
