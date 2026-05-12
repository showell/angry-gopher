module Lib.BoardDsl exposing
    ( formatBoard
    , parseBoard
    , parseCardTokens
    , parseStackLine
    )

{-| Production-side parser/formatter for board DSL — the
multi-line `at (top, left): cards` shape used both in
`.dsl` conformance scenarios and now on the wire for
initial-state payloads.

Lives in `src/` rather than `tests/` so production code can
share the canonical grammar with the test side. The legacy
`tests/Game/ConformanceDsl.elm` delegates here for stack
parsing; round-trip tests in `tests/Game/BoardDslTest.elm`
pin format ∘ parse and parse ∘ format.

Cards are emitted with unicode suits (matches the live
action-log wire and what an end user sees in `actions.dsl`).
Parsing accepts both unicode and ASCII suits via
`Card.cardFromLabel`.

-}

import Lib.CardStack exposing (BoardCardState(..), BoardLocation, CardStack)
import Lib.Rules.Card as Card exposing (Card, OriginDeck(..))



-- PARSE


parseBoard : String -> Result String (List CardStack)
parseBoard src =
    String.lines src
        |> List.indexedMap Tuple.pair
        |> List.filterMap stripTrivial
        |> traverse parseStackLineWithIndex


stripTrivial : ( Int, String ) -> Maybe ( Int, String )
stripTrivial ( idx, raw ) =
    let
        trimmed =
            stripComment raw |> String.trim
    in
    if trimmed == "" then
        Nothing

    else
        Just ( idx, trimmed )


stripComment : String -> String
stripComment s =
    case String.indexes "#" s of
        i :: _ ->
            String.left i s

        [] ->
            s


parseStackLineWithIndex : ( Int, String ) -> Result String CardStack
parseStackLineWithIndex ( idx, line ) =
    parseStackLine line
        |> Result.mapError (\msg -> "line " ++ String.fromInt (idx + 1) ++ ": " ++ msg)


parseStackLine : String -> Result String CardStack
parseStackLine raw =
    let
        line =
            String.trim raw
    in
    if not (String.startsWith "at " line) then
        Err ("expected 'at (top, left): cards', got: " ++ raw)

    else
        let
            afterAt =
                String.dropLeft 3 line
        in
        case String.indexes ")" afterAt of
            close :: _ ->
                let
                    inside =
                        String.slice 1 close afterAt

                    tail =
                        String.trim (String.dropLeft (close + 1) afterAt)
                in
                case ( parseTopLeft inside, splitColon tail ) of
                    ( Ok loc, Ok cardsStr ) ->
                        parseCardTokens cardsStr
                            |> Result.map
                                (\cards ->
                                    { boardCards =
                                        List.map (\c -> { card = c, state = FirmlyOnBoard }) cards
                                    , loc = loc
                                    }
                                )

                    ( Err msg, _ ) ->
                        Err msg

                    ( _, Err msg ) ->
                        Err msg

            [] ->
                Err ("missing ')' in: " ++ raw)


parseTopLeft : String -> Result String BoardLocation
parseTopLeft inside =
    case String.split "," inside of
        [ a, b ] ->
            case ( String.toInt (String.trim a), String.toInt (String.trim b) ) of
                ( Just top, Just left ) ->
                    Ok { top = top, left = left }

                _ ->
                    Err ("non-integer (top, left): " ++ inside)

        _ ->
            Err ("bad location syntax: (" ++ inside ++ ")")


splitColon : String -> Result String String
splitColon tail =
    if String.startsWith ":" tail then
        Ok (String.trim (String.dropLeft 1 tail))

    else
        Err "expected ':' after location"


parseCardTokens : String -> Result String (List Card)
parseCardTokens s =
    String.words s
        |> List.filter (\w -> w /= "")
        |> traverse parseCardToken


{-| Strip optional trailing freshness markers (`*` =
FreshlyPlayed, `**` = FreshlyPlayedByLastPlayer) — they appear
on cards in mid-turn scenarios like `referee.dsl`. Initial-state
wire never carries them; conformance fixtures sometimes do. The
parser accepts but ignores them: state is reconstructed by the
caller as `FirmlyOnBoard` on the parsed `BoardCard`.
-}
parseCardToken : String -> Result String Card
parseCardToken raw =
    let
        bare =
            raw
                |> dropSuffix "**"
                |> dropSuffix "*"

        ( base, deck ) =
            if String.endsWith "'" bare then
                ( String.dropRight 1 bare, DeckTwo )

            else
                ( bare, DeckOne )
    in
    case Card.cardFromLabel base deck of
        Just c ->
            Ok c

        Nothing ->
            Err ("invalid card label: " ++ raw)


dropSuffix : String -> String -> String
dropSuffix suffix s =
    if String.endsWith suffix s then
        String.dropRight (String.length suffix) s

    else
        s


traverse : (a -> Result e b) -> List a -> Result e (List b)
traverse f xs =
    case xs of
        [] ->
            Ok []

        x :: rest ->
            case f x of
                Ok y ->
                    Result.map ((::) y) (traverse f rest)

                Err e ->
                    Err e



-- FORMAT


formatBoard : List CardStack -> String
formatBoard stacks =
    List.map formatStackLine stacks
        |> String.join "\n"


{-| Emit a stack line with the loc pair right-padded to width
three on each axis so the `): ` separator lines up across a
multi-stack block. The cards trail off at varying widths — the
goal is to make it easy to scan PAST the coords to where the
cards begin.
-}
formatStackLine : CardStack -> String
formatStackLine s =
    "at ("
        ++ padInt 3 s.loc.top
        ++ ", "
        ++ padInt 3 s.loc.left
        ++ "): "
        ++ String.join " " (List.map (.card >> Card.cardStr) s.boardCards)


padInt : Int -> Int -> String
padInt width n =
    String.padLeft width ' ' (String.fromInt n)
