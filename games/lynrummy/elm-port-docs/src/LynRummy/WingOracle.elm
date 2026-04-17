module LynRummy.WingOracle exposing (WingId, wingsFor)

{-| Translate `BoardActions.findAllStackMerges` results into the
set of wings that should render during a drag. One wing = one
legal merge: a specific target stack index, plus which side
(Left/Right) of that target the dragged stack attaches to.
-}

import LynRummy.BoardActions as BoardActions exposing (Side)
import LynRummy.CardStack as CardStack exposing (CardStack, stacksEqual)


{-| A specific wing on the board: whose stack, which side.
-}
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
            BoardActions.findAllStackMerges source board
                |> List.filterMap (resultToWing sourceIndex source board)


resultToWing :
    Int
    -> CardStack
    -> List CardStack
    -> BoardActions.StackMergeResult
    -> Maybe WingId
resultToWing sourceIndex source board result =
    let
        targets =
            List.filter (\s -> not (stacksEqual s source)) result.change.stacksToRemove
    in
    case List.head targets of
        Just target ->
            indexOfStack target sourceIndex board
                |> Maybe.map (\idx -> { stackIndex = idx, side = result.side })

        Nothing ->
            Nothing


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)


indexOfStack : CardStack -> Int -> List CardStack -> Maybe Int
indexOfStack target excludeIndex board =
    board
        |> List.indexedMap Tuple.pair
        |> List.filter (\( i, s ) -> i /= excludeIndex && stacksEqual s target)
        |> List.head
        |> Maybe.map Tuple.first
