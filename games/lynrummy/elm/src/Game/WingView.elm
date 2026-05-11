module Game.WingView exposing
    ( hoveredWing
    , renderWingWithHover
    )

{-| All the fiddly wing stuff in one place: rendering, color
constants, and the geometric "is the floater near this wing's
landing" hover-detection.

Wings are the green/mauve drop-zones that appear next to
mergeable target stacks during a drag. They're a board-only
concept — they live inside the board shell, indexed by
`WingId` from `Game.Physics.WingOracle`, and rendered with
`viewWing`. `floaterOverWing` is the geometric predicate that
decides which wing (if any) the floater is currently over;
the result drives both the hover-color choice on render and
the resolver's decision to emit a `MergeStack` / `MergeHand`.

Math + visuals live together because both are "what is this
wing right now, given a drag in flight." Splitting them would
mean two files for the same concept.

-}

import Game.CardStack as CardStack exposing (BoardLocation)
import Game.Physics.BoardGeometry as BG
import Game.Physics.WingOracle as WingOracle exposing (WingId)
import Html exposing (Html, div, text)
import Html.Attributes exposing (style)



-- COLOR CONSTANTS


{-| Mergeable-wing background. `hsl(105, 72.70%, 87.10%)` in
`game.ts:1347` — a light pastel green.
-}
mergeableGreen : String
mergeableGreen =
    "hsl(105, 72.70%, 87.10%)"


{-| Hover-over-wing background. Direct port of `"mauve"` at
`game.ts:1353`. The CSS `mauve` keyword isn't universal —
using the conventional CSS color.
-}
mergeableHover : String
mergeableHover =
    "#E0B0FF"


cardHeightPx : String
cardHeightPx =
    String.fromInt BG.cardHeight ++ "px"



-- HOVER DETECTION


{-| Half a card-pitch of slop in each axis around the eventual
landing. Tight enough that the floater must be visually
adjacent to the target; loose enough to tolerate normal mouse
wiggle.
-}
wingSnapTolerance : Int
wingSnapTolerance =
    CardStack.stackPitch // 2


{-| True iff `floaterTopLeft` is within `wingSnapTolerance` of
`wing`'s eventual landing. Both inputs are in board frame —
the floater is a rectangle's top-left, the wing's eventual
landing is too, so the comparison is a same-frame
`{ left, top }` distance check.
-}
isNearLanding : BoardLocation -> Int -> WingId -> Bool
isNearLanding floaterTopLeft floaterWidth wing =
    let
        ev =
            WingOracle.eventualFloaterTopLeft wing floaterWidth

        dx =
            abs (floaterTopLeft.left - ev.left)

        dy =
            abs (floaterTopLeft.top - ev.top)
    in
    dx < wingSnapTolerance && dy < wingSnapTolerance


{-| Which wing (if any) the floater is about to land on.
`floaterTopLeft` is in board frame.
-}
hoveredWing :
    BoardLocation
    -> Int
    -> List WingId
    -> Maybe WingId
hoveredWing floaterTopLeft floaterWidth wings =
    wings
        |> List.filter (isNearLanding floaterTopLeft floaterWidth)
        |> List.head



-- RENDERING


{-| Render a wing at its eventual landing position, in the
mauve-hover color if it matches `hovered`, otherwise the
mergeable-green color. Caller dispatches DragState once to
extract `wings : List WingId` + `hovered : Maybe WingId` and
maps this function over the list.
-}
renderWingWithHover : Maybe WingId -> WingId -> Html msg
renderWingWithHover hovered wing =
    renderWing (WingOracle.wingBoardRect wing) (hovered == Just wing)


renderWing : { left : Int, top : Int, width : Int, height : Int } -> Bool -> Html msg
renderWing rect hovering =
    let
        bgColor =
            if hovering then
                mergeableHover

            else
                mergeableGreen
    in
    viewWing
        { top = rect.top
        , left = rect.left
        , width = rect.width
        , bgColor = bgColor
        , extraAttrs = []
        }


{-| Render a wing at an absolute board position. Faithful port
of `render_wing` (`game.ts:984`) — transparent card-char
scaffolding gives the element its height — with
`style_as_mergeable` / `style_for_hover` applied at the call
site via `bgColor`.

Wings are top-level board children here, not nested inside the
stack div (unlike TS). This avoids the ugly "grow the wrapper
and compensate by shifting the stack left" pattern — stacks
stay stable, wings render next to them.

-}
viewWing :
    { top : Int
    , left : Int
    , width : Int
    , bgColor : String
    , extraAttrs : List (Html.Attribute msg)
    }
    -> Html msg
viewWing { top, left, width, bgColor, extraAttrs } =
    let
        base =
            [ style "position" "absolute"
            , style "top" (String.fromInt top ++ "px")
            , style "left" (String.fromInt left ++ "px")
            , style "width" (String.fromInt width ++ "px")
            , style "height" cardHeightPx
            , style "padding" "1px"
            , style "background-color" bgColor
            , style "user-select" "none"
            , style "text-align" "center"
            , style "vertical-align" "center"
            , style "font-size" "17px"
            , style "box-sizing" "border-box"
            , style "border" "1px solid transparent"
            ]
    in
    div (base ++ extraAttrs)
        [ div [ style "color" "transparent" ] [ text "+" ]
        , div [ style "color" "transparent" ] [ text "+" ]
        ]
