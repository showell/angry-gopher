module LynRummy.WingOracle exposing (WingId, wingsFor)

{-| For a dragged source stack, enumerate which board stacks
can legally accept it — and on which side.

`side = Left` means: the source attaches to the LEFT of the
target (cards visually end up as `source ++ target`).
`side = Right` means: the source attaches to the RIGHT of
the target (cards end up as `target ++ source`).

Call convention is TARGET-first: `tryStackMerge target source
side`. This makes the target the "anchor" — the merged stack's
position is derived from the target, not the source — which
matches the drop-onto-target UX.

-}

import LynRummy.BoardActions as BoardActions exposing (Side(..))
import LynRummy.CardStack as CardStack exposing (CardStack)


type alias WingId =
    { stackIndex : Int
    , side : Side
    }


{-| Enumerate every winged target for the dragged stack against
the current board. Empty list means no legal merges.
-}
wingsFor : Int -> List CardStack -> List WingId
wingsFor sourceIndex board =
    case listAt sourceIndex board of
        Nothing ->
            []

        Just source ->
            board
                |> List.indexedMap Tuple.pair
                |> List.concatMap (wingsForTarget sourceIndex source)


wingsForTarget : Int -> CardStack -> ( Int, CardStack ) -> List WingId
wingsForTarget sourceIndex source ( targetIndex, target ) =
    if targetIndex == sourceIndex then
        []

    else
        let
            leftWing =
                case BoardActions.tryStackMerge target source Left of
                    Just _ ->
                        [ { stackIndex = targetIndex, side = Left } ]

                    Nothing ->
                        []

            rightWing =
                case BoardActions.tryStackMerge target source Right of
                    Just _ ->
                        [ { stackIndex = targetIndex, side = Right } ]

                    Nothing ->
                        []
        in
        leftWing ++ rightWing


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)
