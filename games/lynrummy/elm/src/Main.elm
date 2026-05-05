port module Main exposing (main)

{-| Thin harness around `Main.Play`.

The main app's entire play surface lives in `Main.Play`. Main
here owns the host ports (URL-pinning + the TS engine bridge)
and boots `Browser.element`, then routes Play's `Output` and
engine responses to the right places.

Engine ports:

  - `engineRequest` (Cmd) — payload-agnostic outbound. JS glue
    switches on the payload's `op` field to pick the TS function
    and the response port.
  - `gameHintResponse` (Sub) — full-game hint responses arrive
    here as `GameHintReceived` Msgs; Play decodes them in
    `applyGameHintResponse`. Distinct from Puzzles' generic
    `engineResponse` channel because the two surfaces have
    different response shapes and we want each Msg to carry
    only what it needs.

-}

import Browser
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Json.Encode as Encode
import Main.Msg as MainMsg exposing (Msg)
import Main.Play as Play
import Main.State exposing (Flags, Model)


{-| Port: updates the URL path to `/gopher/lynrummy-elm/play/<sid>`
to match the active session. Fired whenever Play emits
`SessionChanged`.
-}
port setSessionPath : String -> Cmd msg


{-| Port: ship a TS-engine request payload to JS. Forwarded
from Play's `EngineSolveRequested` Output.
-}
port engineRequest : Encode.Value -> Cmd msg


{-| Port: full-game hint response from the TS engine. Carries
`{ request_id, ok, lines: string[] }`. Subscribed via
`MainMsg.GameHintReceived`.
-}
port gameHintResponse : (Encode.Value -> msg) -> Sub msg


init : Flags -> ( Model, Cmd Msg )
init flags =
    Play.init (configFromFlags flags)


configFromFlags : Flags -> Play.Config
configFromFlags flags =
    case flags.initialSessionId of
        Just sid ->
            Play.ResumeSession sid

        Nothing ->
            Play.NewSession flags.seedSource


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        ( next, cmd, output ) =
            Play.update msg model
    in
    case output of
        Play.NoOutput ->
            ( next, cmd )

        Play.SessionChanged sid ->
            ( next
            , Cmd.batch
                [ cmd
                , setSessionPath (String.fromInt sid)
                ]
            )

        Play.EngineSolveRequested payload ->
            ( next
            , Cmd.batch
                [ cmd
                , engineRequest payload
                ]
            )


view : Model -> Html Msg
view model =
    -- Viewport-filling shell for the main app. Play.view itself
    -- is embeddable (a 1100x700 `position: relative` box); here
    -- we center and scroll it inside the full browser viewport.
    div
        [ style "position" "fixed"
        , style "top" "0"
        , style "left" "0"
        , style "right" "0"
        , style "bottom" "0"
        , style "overflow" "auto"
        , style "background" "#f4f4ec"
        ]
        [ Play.view model ]


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Play.subscriptions model
        , gameHintResponse MainMsg.GameHintReceived
        ]


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
