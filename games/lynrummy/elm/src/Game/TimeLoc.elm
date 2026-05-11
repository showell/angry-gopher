module Game.TimeLoc exposing (TimeLoc, encodeTimeLoc)

import Json.Encode as Encode exposing (Value)


type alias TimeLoc =
    { tMs : Int, left : Int, top : Int }


encodeTimeLoc : TimeLoc -> Value
encodeTimeLoc t =
    Encode.object
        [ ( "t_ms", Encode.int t.tMs )
        , ( "left", Encode.int t.left )
        , ( "top", Encode.int t.top )
        ]
