module Style exposing
    ( cardCanvas
    , cardGhost
    , cardRow
    , draggedCardOverlay
    , landingZone
    , noPointer
    , playSurface
    , posAbsolute
    , posFixed
    , sizeAttrs
    )

{-| Reusable view helpers — composed style-attribute lists and
small "kind-of-card-thing" components that show up in every
gesture's view.

Goal: shrink gesture view code so each visual concept is one
call, not 8–12 lines of `HA.style` ceremony. The explicit-styles
model is preserved (Elm has no CSS-in-JS magic), but the
boilerplate is named once.

Imported by every gesture plugin's view function.
-}

import Card exposing (Card)
import Html exposing (Attribute, Html)
import Html.Attributes as HA
import Layout exposing (Placement, ch, containerHeight, containerOriginX, containerOriginY, containerWidth, cw, pitch, viewCardShape)
import Svg
import Svg.Attributes as SA



-- LOW-LEVEL ATTRIBUTE BUILDERS


posAbsolute : Int -> Int -> List (Attribute msg)
posAbsolute x y =
    [ HA.style "position" "absolute"
    , HA.style "left" (String.fromInt x ++ "px")
    , HA.style "top" (String.fromInt y ++ "px")
    ]


posFixed : Int -> Int -> List (Attribute msg)
posFixed x y =
    [ HA.style "position" "fixed"
    , HA.style "left" (String.fromInt x ++ "px")
    , HA.style "top" (String.fromInt y ++ "px")
    ]


sizeAttrs : Int -> Int -> List (Attribute msg)
sizeAttrs w h =
    [ HA.style "width" (String.fromInt w ++ "px")
    , HA.style "height" (String.fromInt h ++ "px")
    ]


noPointer : Attribute msg
noPointer =
    HA.style "pointer-events" "none"



-- COMPOSITES


{-| A single card rendered in its own SVG canvas, sized to the
standard card metrics (cw × ch). Origin (0, 0) inside the SVG.
The caller positions the wrapper.
-}
cardCanvas : Card -> Html msg
cardCanvas card =
    Svg.svg
        [ SA.width (String.fromInt cw)
        , SA.height (String.fromInt ch)
        , SA.viewBox ("0 0 " ++ String.fromInt cw ++ " " ++ String.fromInt ch)
        ]
        [ viewCardShape 0 0 card ]


{-| A ghost preview of a single card at a placement, with custom
opacity. Used for "what you'd commit to" previews during drag.
-}
cardGhost : { at : Placement, opacity : Float, card : Card } -> Html msg
cardGhost { at, opacity, card } =
    Html.div
        (posAbsolute at.x at.y
            ++ [ HA.style "opacity" (String.fromFloat opacity)
               , noPointer
               ]
        )
        [ cardCanvas card ]


{-| A pitch-spaced row of cards positioned at `at`. Used for
board stacks, hand rows (without the per-card click handlers —
those stay gesture-specific).
-}
cardRow : { at : Placement, cards : List Card } -> Html msg
cardRow { at, cards } =
    let
        n =
            List.length cards

        wPx =
            cw + max 0 (n - 1) * pitch
    in
    Html.div (posAbsolute at.x at.y)
        [ Svg.svg
            [ SA.width (String.fromInt wPx)
            , SA.height (String.fromInt ch)
            , SA.viewBox ("0 0 " ++ String.fromInt wPx ++ " " ++ String.fromInt ch)
            ]
            (List.indexedMap (\i c -> viewCardShape (i * pitch) 0 c) cards)
        ]


{-| The dashed-border tinted landing-zone rectangle. fillAlpha
and outlineAlpha vary smoothly based on drag proximity (caller
supplies them).
-}
landingZone : { at : Placement, fillAlpha : Float, outlineAlpha : Float } -> Html msg
landingZone { at, fillAlpha, outlineAlpha } =
    Html.div
        (posAbsolute at.x at.y
            ++ sizeAttrs at.w at.h
            ++ [ HA.style "background"
                    ("rgba(107, 142, 63, " ++ String.fromFloat fillAlpha ++ ")")
               , HA.style "border"
                    ("2px dashed rgba(107, 142, 63, " ++ String.fromFloat outlineAlpha ++ ")")
               , HA.style "border-radius" "4px"
               , noPointer
               ]
        )
        []


{-| The dragged card overlay following the cursor. Positioned in
**viewport** space (not container-local), with the standard
drop-shadow that signals "this is being held."
-}
draggedCardOverlay : { atViewport : ( Int, Int ), card : Card } -> Html msg
draggedCardOverlay { atViewport, card } =
    let
        ( x, y ) =
            atViewport
    in
    Html.div
        (posFixed x y
            ++ [ noPointer
               , HA.style "opacity" "0.9"
               , HA.style "filter" "drop-shadow(2px 4px 6px rgba(0,0,0,0.2))"
               ]
        )
        [ cardCanvas card ]


{-| The play-surface container. Positioned at the standard
container origin with the standard background, border, and
dimensions. Children are rendered absolutely positioned inside.
-}
playSurface : List (Html msg) -> Html msg
playSurface children =
    Html.div
        (posAbsolute containerOriginX containerOriginY
            ++ sizeAttrs containerWidth containerHeight
            ++ [ HA.style "background" "#eef0e0"
               , HA.style "border" "1px solid #aaa"
               , HA.style "border-radius" "4px"
               ]
        )
        children
