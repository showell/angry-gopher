module Lib.PointerInput exposing
    ( cardMouseDown
    , handCardMouseDown
    )

{-| Pointerdown attr-builders for board + hand cards. Move/up no
longer flow through here: `Browser.Events` has no pointer
subscriptions, so once a press starts the host's JS shim captures
the pointer and forwards move/up over `Lib.PointerPorts`. (The
`...MouseDown` names are historical — the events are pointer events.)
Msg-polymorphic — callers pass their own constructors.

-}

import Lib.CardStack exposing (CardStack, HandCard)
import Lib.Point exposing (Point)
import Html
import Html.Events as Events
import Json.Decode as Decode exposing (Decoder)


pointDecoder : Decoder Point
pointDecoder =
    Decode.map2 (\x y -> { x = round x, y = round y })
        (Decode.field "clientX" Decode.float)
        (Decode.field "clientY" Decode.float)


{-| `PointerEvent.timeStamp` is a `DOMHighResTimeStamp` (Float;
browsers clamp the fractional part to ~1ms anyway). Floor to Int
once here at the JS↔Elm boundary so the rest of the code sees
integer milliseconds.
-}
timeStampDecoder : Decoder Int
timeStampDecoder =
    Decode.field "timeStamp" Decode.float
        |> Decode.map floor


pointerIdDecoder : Decoder Int
pointerIdDecoder =
    Decode.field "pointerId" Decode.int


{-| Pointerdown attr-builder for a board card. `preventDefault`
stops a touch browser from synthesizing mouse events, selecting
text, or popping a long-press callout during our own 400ms
long-press. The pointer id rides along so the host can capture it.
-}
cardMouseDown :
    ({ stack : CardStack, cardIndex : Int, point : Point, time : Int, pointerId : Int } -> msg)
    -> CardStack
    -> Int
    -> List (Html.Attribute msg)
cardMouseDown toMsg stack cardIdx =
    [ Events.preventDefaultOn "pointerdown"
        (Decode.map3
            (\p t pid ->
                ( toMsg { stack = stack, cardIndex = cardIdx, point = p, time = t, pointerId = pid }, True )
            )
            pointDecoder
            timeStampDecoder
            pointerIdDecoder
        )
    ]


{-| Pointerdown attr-builder for a hand card. Mirror of
`cardMouseDown` minus the timestamp (hand drags don't capture a
gesture path).
-}
handCardMouseDown :
    ({ handCard : HandCard, point : Point, pointerId : Int } -> msg)
    -> HandCard
    -> List (Html.Attribute msg)
handCardMouseDown toMsg hc =
    [ Events.preventDefaultOn "pointerdown"
        (Decode.map2
            (\p pid -> ( toMsg { handCard = hc, point = p, pointerId = pid }, True ))
            pointDecoder
            pointerIdDecoder
        )
    ]
