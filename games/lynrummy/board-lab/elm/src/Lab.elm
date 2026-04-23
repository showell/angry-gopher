module Lab exposing (main)

{-| BOARD_LAB — a single-page gallery of curated LynRummy
puzzles. Each panel auto-creates a puzzle session on page
load and embeds a `Main.Play` instance in place. You play
within the gallery — drag a card, the gesture goes through
the normal telemetry pipeline into SQLite, scroll down to
the next puzzle.

Per-panel gameId (the puzzle session's id stringified)
disambiguates DOM ids so multiple Play instances coexist on
one page. Board DOM ids are per-gameId via
`State.boardDomIdFor`; hand-card DOM ids are shared across
instances (collision is harmless for live play since hand
cards are identified by mouse position, not DOM lookup —
only replay inside a single panel measures hand-card DOM
rects).

Always within-a-turn: each puzzle's lab-level state is just
`{ board, hand }` — no deck, no dealer, no turn cycling.
Puzzle catalog lives here as Elm literals; a follow-up will
pull from a Python-canonical catalog so agent and human
solutions to the same named puzzle can be correlated via
SQLite.

-}

import Browser
import Dict exposing (Dict)
import Html exposing (Html, button, div, h1, h2, input, label, p, text)
import Html.Attributes exposing (disabled, placeholder, style, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Main.Msg as MainMsg
import Main.Play as Play
import Main.State as MainState



-- LAB STATE


{-| A puzzle as received from the catalog endpoint. The
`initialState` is opaque JSON (we forward it verbatim to
`new-puzzle-session` rather than decode-and-re-encode — keeps
Python canonical and Elm out of the state-shape business).
-}
type alias Puzzle =
    { name : String
    , title : String
    , description : String
    , initialState : Encode.Value
    }



-- MODEL


type alias Model =
    { userName : String
    , started : Bool
    , catalog : CatalogState
    , panels : Dict String Panel
    }


{-| Top-level catalog fetch state. Until the catalog lands, we
have nothing to render; on error we surface it at the page
level rather than per-panel.
-}
type CatalogState
    = CatalogLoading
    | CatalogLoaded (List Puzzle)
    | CatalogFailed String


{-| Per-puzzle panel state. Each puzzle's session is created on
page load (Creating) and swaps to Playing as soon as the
server returns the session id. Failed is the http-error case.
-}
type Panel
    = Creating
    | Playing MainState.Model
    | Failed String



-- MSG


type Msg
    = UpdateName String
    | SubmitName
    | CatalogFetched (Result Http.Error (List Puzzle))
    | PuzzleSessionCreated String (Result Http.Error Int)
    | PlayMsg String MainMsg.Msg



-- CATALOG DECODE


catalogDecoder : Decoder (List Puzzle)
catalogDecoder =
    Decode.field "puzzles" (Decode.list puzzleDecoder)


puzzleDecoder : Decoder Puzzle
puzzleDecoder =
    Decode.map4 Puzzle
        (Decode.field "name" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.field "description" Decode.string)
        (Decode.field "initial_state" Decode.value)



-- MAIN


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


init : () -> ( Model, Cmd Msg )
init () =
    ( { userName = ""
      , started = False
      , catalog = CatalogLoading
      , panels = Dict.empty
      }
    , Cmd.none
    )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        UpdateName s ->
            ( { model | userName = s }, Cmd.none )

        SubmitName ->
            if String.trim model.userName == "" then
                ( model, Cmd.none )

            else
                ( { model | started = True }, fetchCatalog )

        CatalogFetched (Ok puzzles) ->
            let
                initialPanels =
                    puzzles
                        |> List.map (\p -> ( p.name, Creating ))
                        |> Dict.fromList
            in
            ( { model | catalog = CatalogLoaded puzzles, panels = initialPanels }
            , Cmd.batch (List.map (createPuzzleSession model.userName) puzzles)
            )

        CatalogFetched (Err err) ->
            ( { model | catalog = CatalogFailed (httpErrorToString err) }
            , Cmd.none
            )

        PuzzleSessionCreated name (Ok sessionId) ->
            let
                ( playModel, playCmd ) =
                    Play.init (Play.PuzzleSession sessionId)
            in
            ( { model
                | panels = Dict.insert name (Playing playModel) model.panels
              }
            , Cmd.map (PlayMsg name) playCmd
            )

        PuzzleSessionCreated name (Err err) ->
            ( { model
                | panels = Dict.insert name (Failed (httpErrorToString err)) model.panels
              }
            , Cmd.none
            )

        PlayMsg name pmsg ->
            case Dict.get name model.panels of
                Just (Playing p) ->
                    let
                        ( p2, c, _ ) =
                            Play.update pmsg p
                    in
                    ( { model
                        | panels = Dict.insert name (Playing p2) model.panels
                      }
                    , Cmd.map (PlayMsg name) c
                    )

                _ ->
                    ( model, Cmd.none )


httpErrorToString : Http.Error -> String
httpErrorToString err =
    case err of
        Http.BadUrl s ->
            "bad URL: " ++ s

        Http.Timeout ->
            "timeout"

        Http.NetworkError ->
            "network error"

        Http.BadStatus code ->
            "bad status: " ++ String.fromInt code

        Http.BadBody s ->
            "bad body: " ++ s



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Dict.toList model.panels
        |> List.filterMap
            (\( name, panel ) ->
                case panel of
                    Playing p ->
                        Just (Sub.map (PlayMsg name) (Play.subscriptions p))

                    _ ->
                        Nothing
            )
        |> Sub.batch



-- HTTP


fetchCatalog : Cmd Msg
fetchCatalog =
    Http.get
        { url = "/gopher/board-lab/puzzles"
        , expect = Http.expectJson CatalogFetched catalogDecoder
        }


createPuzzleSession : String -> Puzzle -> Cmd Msg
createPuzzleSession userName puzzle =
    Http.post
        { url = "/gopher/lynrummy-elm/new-puzzle-session"
        , body = Http.jsonBody (encodePuzzleRequest userName puzzle)
        , expect =
            Http.expectJson (PuzzleSessionCreated puzzle.name) sessionIdDecoder
        }


encodePuzzleRequest : String -> Puzzle -> Encode.Value
encodePuzzleRequest userName puzzle =
    let
        trimmed =
            String.trim userName

        label =
            if trimmed == "" then
                "board-lab: " ++ puzzle.title

            else
                "board-lab: " ++ puzzle.title ++ " [by " ++ trimmed ++ "]"
    in
    Encode.object
        [ ( "label", Encode.string label )
        , ( "puzzle_name", Encode.string puzzle.name )
        , ( "initial_state", puzzle.initialState )
        ]


sessionIdDecoder : Decode.Decoder Int
sessionIdDecoder =
    Decode.field "session_id" Decode.int



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ style "max-width" "1200px"
        , style "margin" "0 auto"
        , style "padding" "24px"
        , style "font-family" "sans-serif"
        ]
        ([ h1 [] [ text "BOARD_LAB" ]
         , p []
            [ text
                ("A gallery of hand-crafted LynRummy puzzles. Each "
                    ++ "loads ready to play. Scroll down after solving "
                    ++ "one to reach the next. Drags get captured into "
                    ++ "SQLite so the Python agent can study your "
                    ++ "spatial choices."
                )
            ]
         ]
            ++ (if model.started then
                    viewCatalog model

                else
                    [ viewNameGate model ]
               )
        )


viewNameGate : Model -> Html Msg
viewNameGate model =
    let
        trimmed =
            String.trim model.userName

        canStart =
            trimmed /= ""
    in
    div
        [ style "border" "1px solid #ccc"
        , style "border-radius" "6px"
        , style "padding" "20px"
        , style "margin-top" "28px"
        , style "background" "#fafafa"
        ]
        [ p []
            [ text
                ("Your name will be included in the session labels so "
                    ++ "we can tell your attempts apart from others' when "
                    ++ "we study the captures later."
                )
            ]
        , label [ style "display" "block", style "margin-bottom" "12px" ]
            [ text "Your name: "
            , input
                [ type_ "text"
                , value model.userName
                , onInput UpdateName
                , placeholder "first name is fine"
                , style "font-size" "15px"
                , style "padding" "4px 8px"
                , style "margin-left" "8px"
                , style "min-width" "200px"
                ]
                []
            ]
        , button
            [ onClick SubmitName
            , disabled (not canStart)
            , style "padding" "8px 20px"
            , style "font-size" "14px"
            ]
            [ text "Start" ]
        ]


viewCatalog : Model -> List (Html Msg)
viewCatalog model =
    case model.catalog of
        CatalogLoading ->
            [ div
                [ style "margin-top" "24px", style "color" "#666" ]
                [ text "Loading catalog…" ]
            ]

        CatalogFailed reason ->
            [ div
                [ style "margin-top" "24px", style "color" "#a00" ]
                [ text ("Could not load puzzle catalog: " ++ reason) ]
            ]

        CatalogLoaded puzzles ->
            List.map (viewPuzzle model) puzzles


viewPuzzle : Model -> Puzzle -> Html Msg
viewPuzzle model puzzle =
    let
        panel =
            Dict.get puzzle.name model.panels
                |> Maybe.withDefault Creating
    in
    div
        [ style "border" "1px solid #ccc"
        , style "border-radius" "6px"
        , style "padding" "16px"
        , style "margin-top" "28px"
        , style "background" "#fafafa"
        ]
        [ h2 [ style "margin-top" "0" ] [ text puzzle.title ]
        , p [] [ text puzzle.description ]
        , viewPanelBody puzzle panel
        ]


viewPanelBody : Puzzle -> Panel -> Html Msg
viewPanelBody puzzle panel =
    case panel of
        Playing p ->
            div
                [ style "margin-top" "12px" ]
                [ Html.map (PlayMsg puzzle.name) (Play.view p) ]

        Creating ->
            div
                [ style "margin-top" "12px"
                , style "color" "#666"
                , style "font-style" "italic"
                ]
                [ text "Loading puzzle…" ]

        Failed reason ->
            div
                [ style "margin-top" "12px"
                , style "color" "#a00"
                ]
                [ text ("Could not load puzzle: " ++ reason) ]
