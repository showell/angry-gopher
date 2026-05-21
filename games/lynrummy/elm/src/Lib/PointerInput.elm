module Lib.PointerInput exposing
    ( cardPointerDown
    , handCardPointerDown
    )

{-| Pointerdown attr-builders for board + hand cards. Move/up are
forwarded from the host JS shim over `Lib.PointerPorts` (`Browser.Events`
has no pointer subscriptions, and the shim adds pointer capture so a
drag survives leaving the card). Msg-polymorphic — callers pass their
own constructors.

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


{-| `PointerEvent.timeStamp` is a `DOMHighResTimeStamp` (Float). Floor
to Int once here so the rest of the code sees integer milliseconds.
-}
timeStampDecoder : Decoder Int
timeStampDecoder =
    Decode.field "timeStamp" Decode.float
        |> Decode.map floor


pointAndTimeDecoder : Decoder ( Point, Int )
pointAndTimeDecoder =
    Decode.map2 Tuple.pair pointDecoder timeStampDecoder


{-| Pointerdown attr-builder for a board card. `preventDefault` stops a
touch browser from synthesizing mouse events, selecting text, or
popping a long-press callout during our own 400ms long-press. Pointer
capture is handled by the host shim.
-}
cardPointerDown :
    ({ stack : CardStack, cardIndex : Int, point : Point, time : Int } -> msg)
    -> CardStack
    -> Int
    -> List (Html.Attribute msg)
cardPointerDown toMsg stack cardIdx =
    [ Events.preventDefaultOn "pointerdown"
        (Decode.map
            (\( p, t ) ->
                ( toMsg { stack = stack, cardIndex = cardIdx, point = p, time = t }, True )
            )
            pointAndTimeDecoder
        )
    ]


{-| Pointerdown attr-builder for a hand card. Mirror of `cardPointerDown`
minus the timestamp (hand drags don't capture a gesture path).
-}
handCardPointerDown :
    ({ handCard : HandCard, point : Point } -> msg)
    -> HandCard
    -> List (Html.Attribute msg)
handCardPointerDown toMsg hc =
    [ Events.preventDefaultOn "pointerdown"
        (Decode.map
            (\p -> ( toMsg { handCard = hc, point = p }, True ))
            pointDecoder
        )
    ]
