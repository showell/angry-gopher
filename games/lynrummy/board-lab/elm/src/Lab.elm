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
import Html exposing (Html, button, details, div, h1, h2, input, label, p, pre, summary, text, textarea)
import Html.Attributes exposing (disabled, placeholder, rows, style, type_, value)
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
    , agentSolution : String
    }



-- MODEL


{-| Lab mode — driven by the URL path + mode flag from the
HTML harness. Play mode is the default; Review mode shows
the latest agent attempt per puzzle, read-only.
-}
type LabMode
    = PlayMode
    | ReviewMode


type alias Model =
    { mode : LabMode
    , userName : String
    , started : Bool
    , finished : Bool
    , catalog : CatalogState
    , panels : Dict String Panel
    , annotations : Dict String AnnotationState
    , agentSessions : Dict String Int
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
    | ClickFinish
    | CatalogFetched (Result Http.Error (List Puzzle))
    | AgentSessionsFetched (Result Http.Error (Dict String Int))
    | PuzzleSessionCreated String (Result Http.Error Int)
    | PlayMsg String MainMsg.Msg
    | UpdateAnnotation String String
    | SendAnnotation String
    | AnnotationSent String (Result Http.Error ())



-- CATALOG DECODE


catalogDecoder : Decoder (List Puzzle)
catalogDecoder =
    Decode.field "puzzles" (Decode.list puzzleDecoder)


puzzleDecoder : Decoder Puzzle
puzzleDecoder =
    Decode.map5 Puzzle
        (Decode.field "name" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.field "description" Decode.string)
        (Decode.field "initial_state" Decode.value)
        (Decode.oneOf
            [ Decode.field "agent_solution" Decode.string
            , Decode.succeed ""
            ]
        )



-- MAIN


type alias Flags =
    { mode : String }


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        mode =
            if flags.mode == "review" then
                ReviewMode

            else
                PlayMode

        baseModel =
            { mode = mode
            , userName = ""
            , started = False
            , finished = False
            , catalog = CatalogLoading
            , panels = Dict.empty
            , annotations = Dict.empty
            , agentSessions = Dict.empty
            }
    in
    case mode of
        PlayMode ->
            ( baseModel, Cmd.none )

        ReviewMode ->
            -- No name gate in review mode — the viewer isn't
            -- creating sessions, just inspecting existing ones.
            ( { baseModel | userName = "reviewer", started = True }
            , Cmd.batch [ fetchCatalog, fetchAgentSessions ]
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

        CatalogFetched (Ok puzzles) ->
            let
                initialPanels =
                    puzzles
                        |> List.map (\p -> ( p.name, Creating ))
                        |> Dict.fromList

                m =
                    { model | catalog = CatalogLoaded puzzles, panels = initialPanels }
            in
            case model.mode of
                PlayMode ->
                    ( m
                    , Cmd.batch (List.map (createPuzzleSession model.userName) puzzles)
                    )

                ReviewMode ->
                    hydrateReviewIfReady m

        CatalogFetched (Err err) ->
            ( { model | catalog = CatalogFailed (httpErrorToString err) }
            , Cmd.none
            )

        AgentSessionsFetched (Ok sessions) ->
            hydrateReviewIfReady { model | agentSessions = sessions }

        AgentSessionsFetched (Err _) ->
            ( { model | catalog = CatalogFailed "agent sessions fetch failed" }
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

                maybeSid =
                    case Dict.get name model.panels of
                        Just (Playing p) ->
                            p.sessionId

                        _ ->
                            Nothing
            in
            case ( trimmed, maybeSid ) of
                ( "", _ ) ->
                    ( model, Cmd.none )

                ( _, Nothing ) ->
                    -- No session yet — can't anchor the reply.
                    -- Shouldn't happen in practice (the textarea
                    -- is only reachable once a panel is Playing),
                    -- but guard rather than ship a 0 session_id.
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


sendAnnotation : Int -> String -> String -> String -> Cmd Msg
sendAnnotation sessionId userName puzzleName body =
    Http.post
        { url = "/gopher/board-lab/annotate"
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


fetchAgentSessions : Cmd Msg
fetchAgentSessions =
    Http.get
        { url = "/gopher/board-lab/agent-sessions"
        , expect = Http.expectJson AgentSessionsFetched agentSessionsDecoder
        }


agentSessionsDecoder : Decoder (Dict String Int)
agentSessionsDecoder =
    Decode.field "sessions" (Decode.dict Decode.int)


{-| Once both catalog AND agentSessions are in, construct a
Play instance per puzzle (ReviewSession mode) and wire it
into panels. Called from either handler when the second
response arrives. Safe to call with incomplete data — just
no-ops until both pieces are present.
-}
hydrateReviewIfReady : Model -> ( Model, Cmd Msg )
hydrateReviewIfReady model =
    case ( model.mode, model.catalog ) of
        ( ReviewMode, CatalogLoaded puzzles ) ->
            if Dict.isEmpty model.agentSessions then
                ( model, Cmd.none )

            else
                let
                    addPuzzle p ( panels, cmds ) =
                        case Dict.get p.name model.agentSessions of
                            Just sid ->
                                let
                                    ( playModel, cmd ) =
                                        Play.init (Play.ReviewSession sid)
                                in
                                ( Dict.insert p.name (Playing playModel) panels
                                , Cmd.map (PlayMsg p.name) cmd :: cmds
                                )

                            Nothing ->
                                -- No agent attempt for this puzzle —
                                -- panel stays in Creating (empty)
                                -- so the gallery entry is visible.
                                ( panels, cmds )

                    ( newPanels, newCmds ) =
                        List.foldl addPuzzle ( model.panels, [] ) puzzles
                in
                ( { model | panels = newPanels }, Cmd.batch newCmds )

        _ ->
            ( model, Cmd.none )



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
        , viewAgentSolution puzzle.agentSolution
        , viewPanelBody puzzle panel
        , viewAnnotation puzzle (getAnnotation puzzle.name model)
        ]


viewAgentSolution : String -> Html Msg
viewAgentSolution sol =
    if String.trim sol == "" then
        text ""

    else
        details
            [ style "margin-bottom" "12px" ]
            [ summary
                [ style "cursor" "pointer"
                , style "color" "#555"
                , style "font-size" "13px"
                ]
                [ text "Agent solution (click to expand)" ]
            , pre
                [ style "background" "#fff"
                , style "border" "1px solid #ddd"
                , style "padding" "8px 12px"
                , style "margin" "8px 0 0 0"
                , style "font-size" "12px"
                , style "white-space" "pre-wrap"
                , style "overflow-x" "auto"
                ]
                [ text sol ]
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
