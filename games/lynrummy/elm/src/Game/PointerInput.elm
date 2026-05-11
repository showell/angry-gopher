module Game.PointerInput exposing
    ( cardMouseDown
    , mouseMoveDecoder
    , mouseUpDecoder
    , pointDecoder
    )

{-| Pointer-event decoders + the board-card mousedown attr
builder. Shared between the full-game and puzzle hosts.
Msg-polymorphic where relevant — callers pass their own
constructors.

-}

import Game.CardStack exposing (CardStack)
import Game.Point exposing (Point)
import Html
import Html.Events as Events
import Json.Decode as Decode exposing (Decoder)


pointDecoder : Decoder Point
pointDecoder =
    Decode.map2 (\x y -> { x = round x, y = round y })
        (Decode.field "clientX" Decode.float)
        (Decode.field "clientY" Decode.float)


{-| `MouseEvent.timeStamp` is a `DOMHighResTimeStamp` — JS
gives us a Float (modern browsers clamp the fractional part to
~1ms for Spectre mitigation anyway). We floor to Int once here
at the JS↔Elm boundary so the rest of the codebase only sees
integer milliseconds.
-}
timeStampDecoder : Decoder Int
timeStampDecoder =
    Decode.field "timeStamp" Decode.float
        |> Decode.map floor


pointAndTimeDecoder : Decoder ( Point, Int )
pointAndTimeDecoder =
    Decode.map2 Tuple.pair
        pointDecoder
        timeStampDecoder


{-| Document-level mousemove decoder. Wired into
`Browser.Events.onMouseMove` while a drag is live. Caller
supplies its own `Point -> Int -> msg` constructor.
-}
mouseMoveDecoder : (Point -> Int -> msg) -> Decoder msg
mouseMoveDecoder toMsg =
    Decode.map2 toMsg
        pointDecoder
        timeStampDecoder


{-| Document-level mouseup decoder. Wired into
`Browser.Events.onMouseUp` while a drag is live.
-}
mouseUpDecoder : (Point -> Int -> msg) -> Decoder msg
mouseUpDecoder toMsg =
    Decode.map2 toMsg
        pointDecoder
        timeStampDecoder


{-| Mousedown attr-builder for a board card. Caller passes a
record-shaped constructor (`MouseDownOnBoardCard` or its
puzzle-host equivalent).
-}
cardMouseDown :
    ({ stack : CardStack, cardIndex : Int, point : Point, time : Int } -> msg)
    -> CardStack
    -> Int
    -> List (Html.Attribute msg)
cardMouseDown toMsg stack cardIdx =
    [ Events.on "mousedown"
        (Decode.map
            (\( p, t ) ->
                toMsg { stack = stack, cardIndex = cardIdx, point = p, time = t }
            )
            pointAndTimeDecoder
        )
    ]
