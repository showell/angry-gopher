module Study exposing
    ( Config
    , Model
    , Outcome
    , conditionFor
    , currentCondition
    , dismissBreak
    , enterBreak
    , init
    , isBreakDue
    , isComplete
    , isOnBreak
    , recordTrial
    , restart
    , trialCount
    , view
    )

{-| Study harness. Plugin-agnostic. Tracks trial counter,
condition sequence, break state, results, and renders the
study banner. Each gesture plugin reports its outcomes via
`recordTrial`; the host orchestrates everything else.

The harness does NOT know what a gesture is or what it does.
That decoupling is intentional — the same harness drives every
gesture in the study program.
-}

import Html exposing (Html)
import Html.Attributes as HA
import Html.Events



-- TYPES


type alias Config =
    { trialTotal : Int
    , conditionSeq : List String
    , breakEvery : Int
    , breakMessages : List String
    }


type alias Outcome =
    { ok : Bool
    , durationMs : Int
    , condition : String
    }


type alias Model =
    { trialIdx : Int
    , trialResults : List Outcome
    , onBreak : Bool
    }



-- INIT / RESET


init : Model
init =
    { trialIdx = 0
    , trialResults = []
    , onBreak = False
    }


restart : Model -> Model
restart _ =
    init



-- QUERY


trialCount : Model -> Int
trialCount m =
    m.trialIdx


conditionFor : Config -> Int -> String
conditionFor cfg i =
    case List.head (List.drop i cfg.conditionSeq) of
        Just s ->
            s

        Nothing ->
            -- Fallback if sequence is shorter than trialTotal.
            -- Should never hit if cfg is well-formed.
            "?"


currentCondition : Config -> Model -> String
currentCondition cfg m =
    conditionFor cfg m.trialIdx


isComplete : Config -> Model -> Bool
isComplete cfg m =
    m.trialIdx >= cfg.trialTotal


isOnBreak : Model -> Bool
isOnBreak m =
    m.onBreak


isBreakDue : Config -> Model -> Bool
isBreakDue cfg m =
    cfg.breakEvery > 0 && modBy cfg.breakEvery m.trialIdx == 0 && m.trialIdx > 0 && not (isComplete cfg m)



-- MUTATION


recordTrial : Outcome -> Model -> Model
recordTrial o m =
    { m
        | trialIdx = m.trialIdx + 1
        , trialResults = m.trialResults ++ [ o ]
    }


enterBreak : Model -> Model
enterBreak m =
    { m | onBreak = True }


dismissBreak : Model -> Model
dismissBreak m =
    { m | onBreak = False }



-- VIEW


view :
    { restartMsg : msg, continueMsg : msg }
    -> Config
    -> Model
    -> Html msg
view msgs cfg m =
    let
        ( title, sub ) =
            if isComplete cfg m then
                ( "Study complete", studySummary cfg m.trialResults )

            else if m.onBreak then
                ( breakTitle cfg m.trialIdx, breakSub cfg m.trialIdx )

            else
                ( "Trial "
                    ++ String.fromInt (m.trialIdx + 1)
                    ++ " of "
                    ++ String.fromInt cfg.trialTotal
                , ""
                )
    in
    Html.div
        [ HA.style "text-align" "center"
        , HA.style "padding" "12px"
        , HA.style "position" "relative"
        , HA.style "z-index" "10"
        , HA.style "background" "#f4f4ec"
        ]
        [ Html.div
            [ HA.style "font-size" "18px"
            , HA.style "font-weight" "bold"
            , HA.style "color"
                (if isComplete cfg m || m.onBreak then
                    "#2d5a1f"

                 else
                    "#333"
                )
            ]
            [ Html.text title ]
        , Html.div
            [ HA.style "font-size" "14px"
            , HA.style "color" "#555"
            , HA.style "margin-top" "4px"
            , HA.style "white-space" "pre"
            , HA.style "font-family" "monospace"
            , HA.style "user-select" "text"
            , HA.style "-webkit-user-select" "text"
            ]
            [ Html.text sub ]
        , if isComplete cfg m then
            Html.button
                [ Html.Events.onClick msgs.restartMsg
                , HA.style "margin-top" "10px"
                , HA.style "padding" "6px 16px"
                , HA.style "cursor" "pointer"
                ]
                [ Html.text "restart study" ]

          else if m.onBreak then
            Html.button
                [ Html.Events.onClick msgs.continueMsg
                , HA.style "margin-top" "10px"
                , HA.style "padding" "8px 20px"
                , HA.style "font-size" "14px"
                , HA.style "cursor" "pointer"
                ]
                [ Html.text "continue" ]

          else
            Html.text ""
        ]


breakTitle : Config -> Int -> String
breakTitle cfg completedTrials =
    String.fromInt completedTrials
        ++ " / "
        ++ String.fromInt cfg.trialTotal
        ++ " — take a breath"


{-| Cycle through configured encouragement messages by completed-
trials index. Falls through to a generic message if the list is
exhausted.
-}
breakSub : Config -> Int -> String
breakSub cfg completedTrials =
    let
        idx =
            (completedTrials // cfg.breakEvery) - 1
    in
    case List.head (List.drop idx cfg.breakMessages) of
        Just msg ->
            msg

        Nothing ->
            "Nice work — take a moment and continue when ready."


studySummary : Config -> List Outcome -> String
studySummary cfg results =
    let
        analysis =
            List.drop cfg.breakEvery results

        labels =
            distinctConditions cfg.conditionSeq

        tally cond =
            let
                ofCond =
                    List.filter (\r -> r.condition == cond) analysis

                hits =
                    List.length (List.filter .ok ofCond)

                total =
                    List.length ofCond

                successDurs =
                    List.map .durationMs (List.filter .ok ofCond)

                meanDur =
                    if List.isEmpty successDurs then
                        0

                    else
                        List.sum successDurs // List.length successDurs
            in
            cond
                ++ ": "
                ++ String.fromInt hits
                ++ "/"
                ++ String.fromInt total
                ++ "  mean="
                ++ String.fromInt meanDur
                ++ "ms"

        body =
            String.join "\n  " (List.map tally labels)
    in
    "Warmup (first "
        ++ String.fromInt cfg.breakEvery
        ++ ") discarded.\n"
        ++ "Analysis (trials "
        ++ String.fromInt (cfg.breakEvery + 1)
        ++ "-"
        ++ String.fromInt cfg.trialTotal
        ++ "):\n  "
        ++ body
        ++ "\n\nRaw trial data posted to localhost:8811."


distinctConditions : List String -> List String
distinctConditions seq =
    -- Order-preserving uniqueness — labels appear in the order
    -- they first show up in the sequence.
    List.foldl
        (\c acc ->
            if List.member c acc then
                acc

            else
                acc ++ [ c ]
        )
        []
        seq
