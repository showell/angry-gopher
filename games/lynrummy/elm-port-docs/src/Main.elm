port module Main exposing (main)

{-| Host shell — currently configured for the inject-card
prototype. Swap `Active` + `Msg` + `studyConfig` + `configFor`
to slot in a different gesture for a different study/prototype.
-}

import Browser
import Browser.Events
import Card exposing (Card, Suit(..))
import Gesture.IntegratedPlay as IntegratedPlay
import Html exposing (Html)
import Html.Attributes as HA
import Json.Encode as E
import Layout exposing (Placement, ch, cw, pitch)
import Study
import Time



-- OUTBOUND PORT


port logTrial : E.Value -> Cmd msg



-- STUDY CONFIG (prototype mode — no conditions, no breaks)


studyConfig : Study.Config
studyConfig =
    -- Both prior mechanisms (hop, fill) were vetoed; study is
    -- paused until the next mechanism is picked.
    { trialTotal = 30
    , conditionSeq = List.repeat 30 "none"
    , breakEvery = 10
    , breakMessages =
        [ "Take a breath."
        , "Take a breath."
        ]
    }


configFor : Int -> IntegratedPlay.Config
configFor trialIdx =
    { initialBoardPlace = { x = 240, y = 220, w = cw + 5 * pitch, h = ch }
    , initialFivePos = { x = 30, y = 30 }
    , initialEightPos = { x = 30 + cw + 12, y = 30 }
    , mechanism = Study.conditionFor studyConfig trialIdx
    }



-- MODEL


type ActiveGesture
    = IntegratedPlayActive IntegratedPlay.State


type alias Model =
    { study : Study.Model
    , active : ActiveGesture
    , nowMillis : Int
    , pendingNextTrialAt : Maybe Int
    }


nextTrialDwellMs : Int
nextTrialDwellMs =
    -- Long-press feedback study: each trial is a single extract
    -- attempt, so auto-reset the scene between trials with a
    -- dwell long enough to see and feel the completion before
    -- the new scene appears.
    2500


init : () -> ( Model, Cmd Msg )
init _ =
    let
        s =
            Study.init
    in
    ( { study = s
      , active = IntegratedPlayActive (IntegratedPlay.init (configFor (Study.trialCount s)))
      , nowMillis = 0
      , pendingNextTrialAt = Nothing
      }
    , Cmd.none
    )



-- MSG


type Msg
    = IntegratedPlayMsg IntegratedPlay.Msg
    | StudyContinue
    | StudyRestart
    | HostTick Int



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        IntegratedPlayMsg subMsg ->
            case model.active of
                IntegratedPlayActive state ->
                    let
                        ( newState, gCmd, outcome ) =
                            IntegratedPlay.update subMsg state
                    in
                    case outcome of
                        IntegratedPlay.Pending ->
                            ( { model | active = IntegratedPlayActive newState }
                            , Cmd.map IntegratedPlayMsg gCmd
                            )

                        IntegratedPlay.Completed o ->
                            -- Lift-mechanism study: only the
                            -- set-meld completion ("Steve gets
                            -- the cheese") counts as a trial
                            -- outcome. Other Completed events
                            -- (stack drag, hand meld, etc.)
                            -- update state but don't advance.
                            if o.move == IntegratedPlay.MoveSetCompleted then
                                handleCompleted model newState o gCmd

                            else
                                ( { model | active = IntegratedPlayActive newState }
                                , Cmd.map IntegratedPlayMsg gCmd
                                )

        StudyContinue ->
            let
                s =
                    Study.dismissBreak model.study
            in
            ( { model
                | study = s
                , active = IntegratedPlayActive (IntegratedPlay.init (configFor (Study.trialCount s)))
              }
            , Cmd.none
            )

        StudyRestart ->
            init ()

        HostTick ms ->
            let
                shouldAdvance =
                    case model.pendingNextTrialAt of
                        Just deadline ->
                            ms >= deadline

                        Nothing ->
                            False
            in
            if shouldAdvance then
                ( { model
                    | nowMillis = ms
                    , pendingNextTrialAt = Nothing
                    , active = IntegratedPlayActive (IntegratedPlay.init (configFor (Study.trialCount model.study)))
                  }
                , Cmd.none
                )

            else
                ( { model | nowMillis = ms }, Cmd.none )


handleCompleted :
    Model
    -> IntegratedPlay.State
    -> { ok : Bool, durationMs : Int, move : IntegratedPlay.Move, extra : List ( String, E.Value ) }
    -> Cmd IntegratedPlay.Msg
    -> ( Model, Cmd Msg )
handleCompleted model latestState o gCmd =
    let
        _ =
            o.move

        cond =
            Study.currentCondition studyConfig model.study

        studyOutcome =
            { ok = o.ok, durationMs = o.durationMs, condition = cond }

        newStudy =
            Study.recordTrial studyOutcome model.study

        breakDue =
            Study.isBreakDue studyConfig newStudy

        finalStudy =
            if breakDue then
                Study.enterBreak newStudy

            else
                newStudy

        nextActive =
            IntegratedPlayActive latestState

        nextPending =
            if Study.isComplete studyConfig finalStudy || breakDue then
                Nothing

            else if not o.ok then
                Just model.nowMillis

            else
                Just (model.nowMillis + nextTrialDwellMs)

        payload =
            E.object
                ([ ( "trial", E.int (Study.trialCount newStudy) )
                 , ( "cond", E.string cond )
                 , ( "ok", E.bool o.ok )
                 , ( "durationMs", E.int o.durationMs )
                 ]
                    ++ o.extra
                )
    in
    ( { model
        | active = nextActive
        , study = finalStudy
        , pendingNextTrialAt = nextPending
      }
    , Cmd.batch [ Cmd.map IntegratedPlayMsg gCmd, logTrial payload ]
    )



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions m =
    Sub.batch
        [ case m.active of
            IntegratedPlayActive s ->
                Sub.map IntegratedPlayMsg (IntegratedPlay.subscriptions s)
        , Browser.Events.onAnimationFrame
            (\posix -> HostTick (Time.posixToMillis posix))
        ]



-- VIEW


view : Model -> Html Msg
view m =
    Html.div
        [ HA.style "font-family" "sans-serif"
        , HA.style "padding" "16px"
        , HA.style "background" "#f4f4ec"
        , HA.style "min-height" "100vh"
        , HA.style "user-select" "none"
        ]
        [ Study.view
            { restartMsg = StudyRestart, continueMsg = StudyContinue }
            studyConfig
            m.study
        , viewActive m.active
        ]


viewActive : ActiveGesture -> Html Msg
viewActive active =
    case active of
        IntegratedPlayActive s ->
            Html.map IntegratedPlayMsg (IntegratedPlay.view s)



-- MAIN


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , view = view
        , update = update
        , subscriptions = subscriptions
        }
