module Game.Execute exposing (split)

{-| Honest board mutators, one per `GameEvent` variant. Each
function takes the board (and whatever per-action data it
needs) and returns the new board — no `Maybe`s in the
signature.

If the caller passes a stack that isn't on the board, that's
a bridge bug; the function logs it loudly via `Debug.log`
and returns the board unchanged. The log is the
surfacer; without it (or with silent identity-return) the
divergence cascades downstream and gets harder to trace.

-}

import Game.CardStack as CardStack exposing (CardStack, findStack, isStacksEqual)


{-| Split the given stack at `cardIndex`, returning a new
board with the original stack removed and its two split
pieces appended. Bridge-bug case: stack not on board → log
+ board unchanged.
-}
split : CardStack -> Int -> List CardStack -> List CardStack
split stack cardIndex board =
    case findStack stack board of
        Just real ->
            List.filter (not << isStacksEqual real) board
                ++ CardStack.split cardIndex real

        Nothing ->
            let
                _ =
                    Debug.log "[Execute.split] stack not on board — skipping (bridge bug)" stack
            in
            board
