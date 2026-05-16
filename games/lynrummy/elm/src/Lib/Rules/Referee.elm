module Lib.Rules.Referee exposing
    ( RefereeError
    , RefereeStage(..)
    , refereeStageToString
    , validateTurnComplete
    )

{-| Turn-end validation. The referee is like an expert in the
other room. You show them the final board, they give a ruling.

Production calls `validateTurnComplete` at the moment a player
declares their turn is over: every stack must be a valid card
group (run / rb-run / set), and the board geometry must be valid.

Mid-turn validation used to live here (`validateGameMove`) but
was retired 2026-05-13 — the live Elm UI prevents illegal moves
at the gesture/drag level (`isCursorOverBoard`), so a runtime
referee guard isn't needed during play.

-}

import Lib.CardStack exposing (CardStack)
import Lib.Physics.BoardGeometry exposing (BoardBounds, validateBoardGeometry)
import Lib.Rules.Card
import Lib.Rules.StackType exposing (CardStackType(..), getStackType)



-- TYPES


type RefereeStage
    = Geometry
    | Semantics


type alias RefereeError =
    { stage : RefereeStage
    , message : String
    }



-- ENTRY POINT


{-| Rule on end-of-turn. The board must be clean: geometry valid
and every stack semantically correct.
-}
validateTurnComplete : List CardStack -> BoardBounds -> Result RefereeError ()
validateTurnComplete board bounds =
    checkGeometry board bounds
        |> Result.andThen (\() -> checkSemantics board)



-- GEOMETRY


checkGeometry : List CardStack -> BoardBounds -> Result RefereeError ()
checkGeometry board bounds =
    case validateBoardGeometry board bounds of
        [] ->
            Ok ()

        first :: _ ->
            Err
                { stage = Geometry
                , message = first.message
                }



-- SEMANTICS


{-| Every stack on the board must be a valid card group:
SET, PURE\_RUN, or RED\_BLACK\_RUN. Reject Incomplete / Bogus / Dup.
-}
checkSemantics : List CardStack -> Result RefereeError ()
checkSemantics board =
    case findFirstBadStack board of
        Just ( stack, badType ) ->
            Err
                { stage = Semantics
                , message =
                    "stack \""
                        ++ stackDebugStr stack
                        ++ "\" is "
                        ++ stackTypeStr badType
                }

        Nothing ->
            Ok ()


findFirstBadStack : List CardStack -> Maybe ( CardStack, CardStackType )
findFirstBadStack board =
    case board of
        [] ->
            Nothing

        s :: rest ->
            let
                st =
                    getStackType (List.map .card s.boardCards)
            in
            case st of
                Incomplete ->
                    Just ( s, st )

                Bogus ->
                    Just ( s, st )

                Dup ->
                    Just ( s, st )

                _ ->
                    findFirstBadStack rest


stackTypeStr : CardStackType -> String
stackTypeStr t =
    case t of
        Incomplete ->
            "incomplete"

        Bogus ->
            "bogus"

        Dup ->
            "dup"

        Set ->
            "set"

        PureRun ->
            "pure run"

        RedBlackRun ->
            "red/black alternating"


stackDebugStr : CardStack -> String
stackDebugStr s =
    s.boardCards
        |> List.map (.card >> Lib.Rules.Card.cardStr)
        |> String.join ","



-- STRINGIFY (production: Lib.CompleteTurn uses this for human-readable error display)


refereeStageToString : RefereeStage -> String
refereeStageToString stage =
    case stage of
        Geometry ->
            "geometry"

        Semantics ->
            "semantics"
