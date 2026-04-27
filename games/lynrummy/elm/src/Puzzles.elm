module Puzzles exposing (main)

{-| Puzzles — a single-page gallery of curated LynRummy
puzzles. The catalog endpoint hands us all puzzles + a single
page-load session_id at boot. Panels instantiate Play
instances synchronously from the inline initial state —
zero per-panel HTTP. You play within the gallery; drags and
agent moves write to /gopher/puzzles/actions, which appends
to lynrummy_elm_puzzle_actions keyed by (session_id,
puzzle_name).

Per-panel gameId is the puzzle name, which disambiguates DOM
ids so multiple Play instances coexist on one page (board DOM
ids are per-gameId via `State.boardDomIdFor`).

Always within-a-turn: each puzzle's gallery-level state is just
`{ board }` — no deck, no dealer, no turn cycling, no hand
cards (puzzles are board-only). Page reload terminates the
session by design; sessions and action rows persist for
analysis but the in-memory attempt is single-use.

-}

import Browser
import Dict exposing (Dict)
import Html exposing (Html, button, div, h1, h2, input, label, p, text, textarea)
import Html.Attributes exposing (disabled, placeholder, rows, style, type_, value)
import Html.Events exposing (onClick, onInput)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Main.Msg as MainMsg
import Main.Play as Play
import Main.State as MainState



-- GALLERY STATE


{-| A puzzle as received from the catalog endpoint. The
`initialState` is opaque JSON; we forward it verbatim to
Play.init, which decodes once at panel boot.
-}
type alias Puzzle =
    { name : String
    , title : String
    , initialState : Encode.Value
    }


{-| The full catalog response the server sends on a page-load
GET: a fresh session_id allocated up front + the array of
puzzles. The session id is the same across every panel's wire
write; puzzle_name disambiguates which puzzle each action
belongs to.
-}
type alias Catalog =
    { sessionId : Int
    , puzzles : List Puzzle
    }



-- MODEL


type alias Model =
    { userName : String
    , started : Bool
    , finished : Bool
    , catalog : CatalogState
    , sessionId : Maybe Int
    , panels : Dict String Panel
    , annotations : Dict String AnnotationState
    }


{-| Per-puzzle annotation textarea state. Keyed by puzzle
name, mirroring `panels`. Tracks the current textarea
contents plus the most-recent send status so the UI can
show "sent" / "sending…" / error messages inline.
-}
type alias AnnotationState =
    { text : String
    , status : SendStatus
    }


type SendStatus
    = NotSent
    | Sending
    | Sent
    | SendFailed String


{-| Top-level catalog fetch state. Until the catalog lands, we
have nothing to render; on error we surface it at the page
level rather than per-panel.
-}
type CatalogState
    = CatalogLoading
    | CatalogLoaded (List Puzzle)
    | CatalogFailed String


{-| Per-puzzle panel state. With the catalog carrying initial
state inline, panels go straight to Playing on catalog landing
(no Creating limbo). Failed is the decode-error case for
malformed catalog entries.
-}
type Panel
    = Playing MainState.Model
    | Failed String



-- MSG


type Msg
    = UpdateName String
    | SubmitName
    | ClickFinish
    | CatalogFetched (Result Http.Error Catalog)
    | PlayMsg String MainMsg.Msg
    | UpdateAnnotation String String
    | SendAnnotation String
    | AnnotationSent String (Result Http.Error ())



-- CATALOG DECODE


catalogDecoder : Decoder Catalog
catalogDecoder =
    Decode.map2 Catalog
        (Decode.field "session_id" Decode.int)
        (Decode.field "puzzles" (Decode.list puzzleDecoder))


puzzleDecoder : Decoder Puzzle
puzzleDecoder =
    Decode.map3 Puzzle
        (Decode.field "name" Decode.string)
        (Decode.field "title" Decode.string)
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
init _ =
    ( { userName = ""
      , started = False
      , finished = False
      , catalog = CatalogLoading
      , sessionId = Nothing
      , panels = Dict.empty
      , annotations = Dict.empty
      }
    , Cmd.none
    )


emptyAnnotation : AnnotationState
emptyAnnotation =
    { text = "", status = NotSent }


getAnnotation : String -> Model -> AnnotationState
getAnnotation puzzleName model =
    Dict.get puzzleName model.annotations
        |> Maybe.withDefault emptyAnnotation



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

        ClickFinish ->
            ( { model | finished = True }, Cmd.none )

        CatalogFetched (Ok catalog) ->
            let
                ( panels, panelCmds ) =
                    catalog.puzzles
                        |> List.foldr
                            (\puzzle ( accPanels, accCmds ) ->
                                let
                                    ( playModel, playCmd ) =
                                        Play.init
                                            (Play.PuzzleSession
                                                { sessionId = catalog.sessionId
                                                , puzzleName = puzzle.name
                                                , initialState = puzzle.initialState
                                                }
                                            )
                                in
                                ( Dict.insert puzzle.name (Playing playModel) accPanels
                                , Cmd.map (PlayMsg puzzle.name) playCmd :: accCmds
                                )
                            )
                            ( Dict.empty, [] )
            in
            ( { model
                | catalog = CatalogLoaded catalog.puzzles
                , sessionId = Just catalog.sessionId
                , panels = panels
              }
            , Cmd.batch panelCmds
            )

        CatalogFetched (Err err) ->
            ( { model | catalog = CatalogFailed (httpErrorToString err) }
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

        UpdateAnnotation name text ->
            let
                current =
                    getAnnotation name model
            in
            ( { model
                | annotations =
                    Dict.insert name
                        { current | text = text, status = NotSent }
                        model.annotations
              }
            , Cmd.none
            )

        SendAnnotation name ->
            let
                current =
                    getAnnotation name model

                trimmed =
                    String.trim current.text
            in
            case ( trimmed, model.sessionId ) of
                ( "", _ ) ->
                    ( model, Cmd.none )

                ( _, Nothing ) ->
                    -- No session yet — catalog hasn't landed.
                    -- The textarea is only reachable after a
                    -- panel is Playing, so this is structurally
                    -- impossible; bail rather than ship a 0
                    -- session_id.
                    ( model, Cmd.none )

                ( _, Just sid ) ->
                    ( { model
                        | annotations =
                            Dict.insert name
                                { current | status = Sending }
                                model.annotations
                      }
                    , sendAnnotation sid model.userName name trimmed
                    )

        AnnotationSent name (Ok ()) ->
            ( { model
                | annotations =
                    Dict.insert name
                        { text = "", status = Sent }
                        model.annotations
              }
            , Cmd.none
            )

        AnnotationSent name (Err err) ->
            let
                current =
                    getAnnotation name model
            in
            ( { model
                | annotations =
                    Dict.insert name
                        { current | status = SendFailed (httpErrorToString err) }
                        model.annotations
              }
            , Cmd.none
            )


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
        { url = "/gopher/puzzles/catalog"
        , expect = Http.expectJson CatalogFetched catalogDecoder
        }


sendAnnotation : Int -> String -> String -> String -> Cmd Msg
sendAnnotation sessionId userName puzzleName body =
    Http.post
        { url = "/gopher/puzzles/annotate"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "session_id", Encode.int sessionId )
                    , ( "puzzle_name", Encode.string puzzleName )
                    , ( "user_name", Encode.string userName )
                    , ( "body", Encode.string body )
                    ]
                )
        , expect = Http.expectWhatever (AnnotationSent puzzleName)
        }





-- VIEW


view : Model -> Html Msg
view model =
    div
        [ style "max-width" "1200px"
        , style "margin" "0 auto"
        , style "padding" "24px"
        , style "font-family" "sans-serif"
        ]
        ([ h1 [] [ text "Puzzles" ]
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
            ++ (if model.finished then
                    [ viewFinishedMessage model ]

                else if model.started then
                    viewCatalog model ++ [ viewFinishButton ]

                else
                    [ viewNameGate model ]
               )
        )


viewFinishButton : Html Msg
viewFinishButton =
    div
        [ style "margin-top" "40px"
        , style "padding-top" "20px"
        , style "border-top" "1px solid #ddd"
        , style "text-align" "center"
        ]
        [ button
            [ onClick ClickFinish
            , style "padding" "12px 32px"
            , style "font-size" "16px"
            , style "background" "#000080"
            , style "color" "white"
            , style "border" "none"
            , style "border-radius" "6px"
            , style "cursor" "pointer"
            ]
            [ text "Finish" ]
        ]


viewFinishedMessage : Model -> Html Msg
viewFinishedMessage model =
    div
        [ style "margin-top" "40px"
        , style "padding" "32px"
        , style "background" "#f0f8f0"
        , style "border" "1px solid #9c9"
        , style "border-radius" "8px"
        , style "text-align" "center"
        , style "font-size" "18px"
        ]
        [ p [ style "margin" "0 0 8px 0", style "font-weight" "bold" ]
            [ text ("Thanks, " ++ String.trim model.userName ++ "! You are helping science!") ]
        , p [ style "margin" "0", style "font-size" "14px", style "color" "#555" ]
            [ text "(you may reload the browser to play again)" ]
        ]


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
                |> Maybe.withDefault (Failed "panel missing — race or bug")
    in
    div
        [ style "border" "1px solid #ccc"
        , style "border-radius" "6px"
        , style "padding" "16px"
        , style "margin-top" "28px"
        , style "background" "#fafafa"
        ]
        [ h2 [ style "margin-top" "0" ] [ text puzzle.title ]
        , viewPanelBody puzzle panel
        , viewAnnotation puzzle (getAnnotation puzzle.name model)
        ]


viewAnnotation : Puzzle -> AnnotationState -> Html Msg
viewAnnotation puzzle ann =
    let
        canSend =
            String.trim ann.text /= "" && ann.status /= Sending

        statusRow =
            case ann.status of
                NotSent ->
                    text ""

                Sending ->
                    statusText "#555" "sending…"

                Sent ->
                    statusText "#060" "sent"

                SendFailed reason ->
                    statusText "#a00" ("failed: " ++ reason)
    in
    div
        [ style "margin-top" "16px"
        , style "padding-top" "12px"
        , style "border-top" "1px solid #ddd"
        ]
        [ label
            [ style "display" "block"
            , style "font-size" "13px"
            , style "color" "#555"
            , style "margin-bottom" "6px"
            ]
            [ text "Notes on this puzzle (mouse slips, agent behavior, anything weird):" ]
        , textarea
            [ value ann.text
            , onInput (UpdateAnnotation puzzle.name)
            , rows 3
            , placeholder "e.g. 'mouse slip on seq 2' or 'agent's landing loc feels off'"
            , style "width" "100%"
            , style "box-sizing" "border-box"
            , style "font-family" "inherit"
            , style "font-size" "14px"
            , style "padding" "6px"
            ]
            []
        , div
            [ style "margin-top" "8px"
            , style "display" "flex"
            , style "align-items" "center"
            , style "gap" "12px"
            ]
            [ button
                [ onClick (SendAnnotation puzzle.name)
                , disabled (not canSend)
                , style "padding" "6px 16px"
                , style "font-size" "13px"
                ]
                [ text "Send" ]
            , statusRow
            ]
        ]


statusText : String -> String -> Html Msg
statusText color msg =
    div
        [ style "font-size" "13px"
        , style "color" color
        ]
        [ text msg ]


viewPanelBody : Puzzle -> Panel -> Html Msg
viewPanelBody puzzle panel =
    case panel of
        Playing p ->
            div
                [ style "margin-top" "12px" ]
                [ Html.map (PlayMsg puzzle.name) (Play.view p) ]

        Failed reason ->
            div
                [ style "margin-top" "12px"
                , style "color" "#a00"
                ]
                [ text ("Could not load puzzle: " ++ reason) ]
