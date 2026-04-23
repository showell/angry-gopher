port module Main exposing (main)

{-| Thin harness around `Main.Play`.

The main app's entire play surface lives in `Main.Play` as of
REFACTOR_EMBEDDABLE_PLAY Phase I — Main here just owns the
URL-pinning port (only port modules may declare ports), boots
`Browser.element`, and routes Play's `Output` to the port.

BOARD_LAB will eventually embed `Main.Play` directly for its
puzzle gallery, without needing this port at all; that's why
the port stays a host concern instead of living inside Play.

-}

import Browser
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Main.Msg exposing (Msg)
import Main.Play as Play
import Main.State exposing (Flags, Model)


{-| Port: updates the URL path to `/gopher/lynrummy-elm/play/<sid>`
to match the active session. Fired whenever Play emits
`SessionChanged`.
-}
port setSessionPath : String -> Cmd msg


init : Flags -> ( Model, Cmd Msg )
init flags =
    Play.init (configFromFlags flags)


configFromFlags : Flags -> Play.Config
configFromFlags flags =
    case flags.initialSessionId of
        Just sid ->
            Play.ResumeSession sid

        Nothing ->
            Play.NewSession


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
subscriptions =
    Play.subscriptions


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
