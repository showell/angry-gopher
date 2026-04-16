module Layout exposing
    ( Placement
    , ch
    , containerHeight
    , containerOriginX
    , containerOriginY
    , containerWidth
    , cw
    , pitch
    , viewCardShape
    )

{-| Geometry constants and shared low-level rendering. No domain
or gesture logic. Imported by every gesture plugin.

The card metrics (cw, ch, pitch) and container coordinates are
the *physical units* of the play surface. If you change them, the
study experiments need to be re-validated — they assume these
sizes.
-}

import Card exposing (Card, suitColor, suitText, valueText)
import Svg exposing (Svg)
import Svg.Attributes as SA


type alias Placement =
    { x : Int, y : Int, w : Int, h : Int }


cw : Int
cw =
    48


ch : Int
ch =
    68


pitch : Int
pitch =
    cw + 2


{-| The play surface is pinned to a known viewport offset so we
can convert mouse-event coords (viewport space) to container-local
coords for hit-testing. Keep these in lockstep with the Main.elm
container CSS.
-}
containerOriginX : Int
containerOriginX =
    60


containerOriginY : Int
containerOriginY =
    100


containerWidth : Int
containerWidth =
    780


containerHeight : Int
containerHeight =
    480


{-| Reusable SVG card glyph. (x, y) is the top-left in container-
or stack-local coordinates depending on caller.
-}
viewCardShape : Int -> Int -> Card -> Svg msg
viewCardShape x y card =
    Svg.g []
        [ Svg.rect
            [ SA.x (String.fromInt (x + 1))
            , SA.y (String.fromInt (y + 1))
            , SA.width (String.fromInt cw)
            , SA.height (String.fromInt ch)
            , SA.fill "rgba(0,0,0,0.12)"
            , SA.rx "4"
            ]
            []
        , Svg.rect
            [ SA.x (String.fromInt x)
            , SA.y (String.fromInt y)
            , SA.width (String.fromInt cw)
            , SA.height (String.fromInt ch)
            , SA.fill "white"
            , SA.stroke "#0000cc"
            , SA.strokeWidth "1"
            , SA.rx "4"
            ]
            []
        , Svg.text_
            [ SA.x (String.fromInt (x + cw // 2))
            , SA.y (String.fromInt (y + ch * 35 // 100))
            , SA.fill (suitColor card.suit)
            , SA.fontSize "20"
            , SA.fontWeight "bold"
            , SA.textAnchor "middle"
            ]
            [ Svg.text (valueText card.value) ]
        , Svg.text_
            [ SA.x (String.fromInt (x + cw // 2))
            , SA.y (String.fromInt (y + ch * 72 // 100))
            , SA.fill (suitColor card.suit)
            , SA.fontSize "22"
            , SA.textAnchor "middle"
            ]
            [ Svg.text (suitText card.suit) ]
        ]
