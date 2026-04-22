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

`WingId` identifies its target by CardStack value, matching
the wire format and the Main.State drag model. One
representation everywhere.

-}

import Game.BoardActions as BoardActions exposing (Side(..))
import Game.BoardGeometry as BG
import Game.CardStack as CardStack exposing (CardStack, HandCard, stacksEqual)


type alias WingId =
    { target : CardStack
    , side : Side
    }



-- STACK SOURCE


{-| Wings for a board stack being dragged.
-}
wingsForStack : CardStack -> List CardStack -> List WingId
wingsForStack source board =
    List.concatMap (stackWingsForTarget source) board


stackWingsForTarget : CardStack -> CardStack -> List WingId
stackWingsForTarget source target =
    if stacksEqual target source then
        []

    else
        let
            leftWing =
                case BoardActions.tryStackMerge target source Left of
                    Just _ ->
                        [ { target = target, side = Left } ]

                    Nothing ->
                        []

            rightWing =
                case BoardActions.tryStackMerge target source Right of
                    Just _ ->
                        [ { target = target, side = Right } ]

                    Nothing ->
                        []
        in
        leftWing ++ rightWing



-- HAND-CARD SOURCE


{-| Wings for a hand card being dragged.
-}
wingsForHandCard : HandCard -> List CardStack -> List WingId
wingsForHandCard handCard board =
    List.concatMap (handCardWingsForTarget handCard) board


handCardWingsForTarget : HandCard -> CardStack -> List WingId
handCardWingsForTarget handCard target =
    let
        leftWing =
            case BoardActions.tryHandMerge target handCard Left of
                Just _ ->
                    [ { target = target, side = Left } ]

                Nothing ->
                    []

        rightWing =
            case BoardActions.tryHandMerge target handCard Right of
                Just _ ->
                    [ { target = target, side = Right } ]

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
wingBoardRect : WingId -> { left : Int, top : Int, width : Int, height : Int }
wingBoardRect wing =
    let
        left =
            case wing.side of
                Left ->
                    wing.target.loc.left - CardStack.stackPitch

                Right ->
                    wing.target.loc.left + CardStack.stackDisplayWidth wing.target
    in
    { left = left
    , top = wing.target.loc.top
    , width = CardStack.stackPitch
    , height = BG.cardHeight
    }
