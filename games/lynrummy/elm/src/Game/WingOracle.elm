module Game.WingOracle exposing
    ( WingId
    , wingBoardRect
    , wingsForHandCard
    , wingsForStack
    )

{-| For a dragged source (stack or hand card), enumerate which
board stacks can legally accept it — and on which side.

`side = Left` means: the source attaches to the LEFT of the
target (cards visually end up as `source ++ target`).
`side = Right` means: the source attaches to the RIGHT of
the target (cards end up as `target ++ source`).

Call convention is TARGET-first: `tryStackMerge target source
side` (and equivalently `tryHandMerge target handCard side`).
This makes the target the "anchor" — the merged stack's
position is derived from the target, not the source — which
matches the drop-onto-target UX.

Two entry points, one `WingId` shape out. Stack-source and
hand-source paths are deliberately kept as two separate
functions; they are two similar things, not one parametrized
thing.

-}

import Game.BoardActions as BoardActions exposing (Side(..))
import Game.BoardGeometry as BG
import Game.CardStack as CardStack exposing (CardStack, HandCard)


type alias WingId =
    { stackIndex : Int
    , side : Side
    }



-- STACK SOURCE


{-| Wings for a board stack being dragged.
-}
wingsForStack : Int -> List CardStack -> List WingId
wingsForStack sourceIndex board =
    case listAt sourceIndex board of
        Nothing ->
            []

        Just source ->
            board
                |> List.indexedMap Tuple.pair
                |> List.concatMap (stackWingsForTarget sourceIndex source)


stackWingsForTarget : Int -> CardStack -> ( Int, CardStack ) -> List WingId
stackWingsForTarget sourceIndex source ( targetIndex, target ) =
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



-- HAND-CARD SOURCE


{-| Wings for a hand card being dragged.
-}
wingsForHandCard : HandCard -> List CardStack -> List WingId
wingsForHandCard handCard board =
    board
        |> List.indexedMap Tuple.pair
        |> List.concatMap (handCardWingsForTarget handCard)


handCardWingsForTarget : HandCard -> ( Int, CardStack ) -> List WingId
handCardWingsForTarget handCard ( targetIndex, target ) =
    let
        leftWing =
            case BoardActions.tryHandMerge target handCard Left of
                Just _ ->
                    [ { stackIndex = targetIndex, side = Left } ]

                Nothing ->
                    []

        rightWing =
            case BoardActions.tryHandMerge target handCard Right of
                Just _ ->
                    [ { stackIndex = targetIndex, side = Right } ]

                Nothing ->
                    []
    in
    leftWing ++ rightWing



-- WING RECT (board-frame)


{-| Board-frame rectangle the named wing renders into.
Derived from the target stack's loc + which side the wing sits
on, in the same math `Main.View.viewWingAt` uses at render
time. Kept pure and exposed so tests (and a future computed
hit-test) can ask the question without a DOM.

`left`/`top` are board-frame pixels; `width` is one card pitch;
`height` is `BG.cardHeight`.
-}
wingBoardRect : WingId -> CardStack -> { left : Int, top : Int, width : Int, height : Int }
wingBoardRect wing target =
    let
        left =
            case wing.side of
                Left ->
                    target.loc.left - CardStack.stackPitch

                Right ->
                    target.loc.left + CardStack.stackDisplayWidth target
    in
    { left = left
    , top = target.loc.top
    , width = CardStack.stackPitch
    , height = BG.cardHeight
    }



-- HELPERS


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)
