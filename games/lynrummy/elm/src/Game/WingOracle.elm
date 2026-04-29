module Game.WingOracle exposing
    ( WingId
    , eventualFloaterTopLeft
    , wingBoardRect
    , wingsForHandCard
    , wingsForStack
    )

{-| For a dragged source (stack or hand card), enumerate which
board stacks can legally accept it — and on which side.

`side = Left` means the source attaches to the LEFT of the
target (merged order is `source ++ target`). `side = Right`
the mirror. The target anchors the merge: the merged stack's
position derives from the target, not the source, matching
the drop-onto-target UX.

`WingId` identifies its target by CardStack value (same
representation as the wire and the Main.State drag model).
-}

import Game.BoardActions as BoardActions exposing (Side(..))
import Game.BoardGeometry as BG
import Game.CardStack as CardStack exposing (CardStack, HandCard, isStacksEqual)


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
    if isStacksEqual target source then
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


{-| Board-frame rectangle the wing renders into — the visual
affordance a user sees when hovering a drop candidate. Used
by `Main.View.viewWingAt`. The live hit-test does NOT use
this rect; it calls `eventualFloaterTopLeft`. One card-pitch
wide by `BG.cardHeight` tall.
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


{-| Board-frame top-left where the floater will LAND if the
merge fires. The hit-test checks closeness to this point,
which is both tighter and more accurate than overlap with
the visual wing rect.

  - Right wing: floater lands flush against target's right
    edge — at (target.right, target.top).
  - Left wing: floater's right edge meets target's left edge
    — at (target.left - sourceWidth, target.top).

`sourceWidth` is needed for the left-wing case because the
eventual floater starts `sourceWidth` pixels to the left of
target.
-}
eventualFloaterTopLeft : WingId -> Int -> { left : Int, top : Int }
eventualFloaterTopLeft wing sourceWidth =
    let
        left =
            case wing.side of
                Left ->
                    wing.target.loc.left - sourceWidth

                Right ->
                    wing.target.loc.left + CardStack.stackDisplayWidth wing.target
    in
    { left = left, top = wing.target.loc.top }
