module Lib.WireAction exposing (ParsedLine, parseDsl, parseEvent)

{-| Wire parser for action-log entries. Two entry points share
the same per-event grammar; the only difference is whether a
`seq) ` prefix is required:

  - `parseDsl "45) merge_stack ... /right"` → `ParsedLine`
    (seq + event). Used by action-log replay.
  - `parseEvent "merge_stack ... /right"` → `GameEvent`. Used
    by transport surfaces that don't carry seq numbers (the
    agent-step response from the TS engine — seqs are assigned
    by the consumer when the events land in the action log).

Per-event emitters live in `Lib.GameEvent` (`splitDsl`,
`mergeStackDsl`, etc.).

Each stack reference on the wire carries `[cards] at (left,top)`
— enough to reconstruct a `CardStack` whose `findStack` lookup
on the current board will resolve. State-per-card isn't on the
wire; we default boardCards to `FirmlyOnBoard` (state doesn't
participate in `isCardsEqualInOrder`).

-}

import Lib.BoardActions exposing (Side(..))
import Lib.CardStack exposing (BoardCardState(..), BoardLocation, CardStack)
import Lib.GameEvent exposing (GameEvent(..))
import Lib.Rules.Card as Card exposing (Card, OriginDeck(..))
import Lib.TimeLoc exposing (TimeLoc)


type alias ParsedLine =
    { seq : Int, event : GameEvent }


parseDsl : String -> Result String ParsedLine
parseDsl raw =
    let
        line =
            String.trim raw
    in
    parseSeq line
        |> Result.andThen
            (\( seq, body ) ->
                parseEvent body
                    |> Result.map (\event -> { seq = seq, event = event })
            )



-- TOP-LEVEL DISPATCH


parseEvent : String -> Result String GameEvent
parseEvent s =
    if s == "complete_turn" then
        Ok CompleteTurn

    else if s == "undo" then
        Ok Undo

    else if String.startsWith "split " s then
        parseSplit (String.dropLeft 6 s)

    else if String.startsWith "merge_stack " s then
        parseMergeStack (String.dropLeft 12 s)

    else if String.startsWith "merge_hand " s then
        parseMergeHand (String.dropLeft 11 s)

    else if String.startsWith "move_stack " s then
        parseMoveStack (String.dropLeft 11 s)

    else if String.startsWith "place_hand " s then
        parsePlaceHand (String.dropLeft 11 s)

    else
        Err ("unknown action verb in: " ++ s)



-- PER-VERB PARSERS


parseSplit : String -> Result String GameEvent
parseSplit s =
    parseStackRef s
        |> Result.andThen
            (\( stack, rest ) ->
                consume "@" rest
                    |> Result.andThen parseInt
                    |> Result.andThen
                        (\( cardIndex, tail ) ->
                            expectEmpty tail
                                |> Result.map
                                    (\_ ->
                                        Split { stack = stack, cardIndex = cardIndex }
                                    )
                        )
            )


parseMergeStack : String -> Result String GameEvent
parseMergeStack s =
    parseStackRef s
        |> Result.andThen
            (\( source, r1 ) ->
                consume "->" r1
                    |> Result.andThen parseStackRef
                    |> Result.andThen
                        (\( target, r2 ) ->
                            parseSide r2
                                |> Result.andThen
                                    (\( side, r3 ) ->
                                        parsePathSuffix r3
                                            |> Result.map
                                                (\path ->
                                                    MergeStack
                                                        { source = source
                                                        , target = target
                                                        , side = side
                                                        , boardPath = path
                                                        }
                                                )
                                    )
                        )
            )


parseMergeHand : String -> Result String GameEvent
parseMergeHand s =
    parseCardToken s
        |> Result.andThen
            (\( handCard, r1 ) ->
                consume "->" r1
                    |> Result.andThen parseStackRef
                    |> Result.andThen
                        (\( target, r2 ) ->
                            parseSide r2
                                |> Result.andThen
                                    (\( side, r3 ) ->
                                        expectEmpty r3
                                            |> Result.map
                                                (\_ ->
                                                    MergeHand
                                                        { handCard = handCard
                                                        , target = target
                                                        , side = side
                                                        }
                                                )
                                    )
                        )
            )


parseMoveStack : String -> Result String GameEvent
parseMoveStack s =
    parseStackRef s
        |> Result.andThen
            (\( stack, r1 ) ->
                consume "->" r1
                    |> Result.andThen parseLoc
                    |> Result.andThen
                        (\( newLoc, r2 ) ->
                            parsePathSuffix r2
                                |> Result.map
                                    (\path ->
                                        MoveStack
                                            { stack = stack
                                            , newLoc = newLoc
                                            , boardPath = path
                                            }
                                    )
                        )
            )


parsePlaceHand : String -> Result String GameEvent
parsePlaceHand s =
    parseCardToken s
        |> Result.andThen
            (\( handCard, r1 ) ->
                consume "->" r1
                    |> Result.andThen parseLoc
                    |> Result.andThen
                        (\( loc, r2 ) ->
                            expectEmpty r2
                                |> Result.map
                                    (\_ ->
                                        PlaceHand { handCard = handCard, loc = loc }
                                    )
                        )
            )



-- TOKEN PARSERS


parseSeq : String -> Result String ( Int, String )
parseSeq s =
    case String.indexes ")" s of
        idx :: _ ->
            String.left idx s
                |> String.trim
                |> String.toInt
                |> Maybe.map (\n -> Ok ( n, String.trim (String.dropLeft (idx + 1) s) ))
                |> Maybe.withDefault (Err ("expected integer seq prefix in: " ++ s))

        [] ->
            Err ("missing ')' seq prefix in: " ++ s)


parseStackRef : String -> Result String ( CardStack, String )
parseStackRef raw =
    let
        s =
            String.trimLeft raw
    in
    consume "[" s
        |> Result.andThen
            (\afterBracket ->
                case String.indexes "]" afterBracket of
                    idx :: _ ->
                        let
                            inside =
                                String.left idx afterBracket
                                    |> String.trim

                            tail =
                                String.dropLeft (idx + 1) afterBracket
                        in
                        parseCardList inside
                            |> Result.andThen
                                (\cards ->
                                    consume "at" tail
                                        |> Result.andThen parseLoc
                                        |> Result.map
                                            (\( loc, rest ) ->
                                                ( { boardCards =
                                                        List.map
                                                            (\c -> { card = c, state = FirmlyOnBoard })
                                                            cards
                                                  , loc = loc
                                                  }
                                                , rest
                                                )
                                            )
                                )

                    [] ->
                        Err ("missing ']' for stack ref in: " ++ raw)
            )


parseCardList : String -> Result String (List Card)
parseCardList s =
    if String.isEmpty s then
        Ok []

    else
        s
            |> String.words
            |> List.map parseCardLabel
            |> sequenceResults


parseCardToken : String -> Result String ( Card, String )
parseCardToken raw =
    let
        s =
            String.trimLeft raw
    in
    case String.words s of
        [] ->
            Err "expected card token"

        token :: _ ->
            parseCardLabel token
                |> Result.map
                    (\card ->
                        ( card, String.dropLeft (String.length token) s |> String.trimLeft )
                    )


parseCardLabel : String -> Result String Card
parseCardLabel label =
    let
        ( base, deck ) =
            if String.endsWith "'" label then
                ( String.dropRight 1 label, DeckTwo )

            else
                ( label, DeckOne )
    in
    case Card.cardFromLabel base deck of
        Just c ->
            Ok c

        Nothing ->
            Err ("invalid card label: " ++ label)


parseLoc : String -> Result String ( BoardLocation, String )
parseLoc raw =
    let
        s =
            String.trimLeft raw
    in
    consume "(" s
        |> Result.andThen
            (\afterOpen ->
                case String.indexes ")" afterOpen of
                    idx :: _ ->
                        let
                            inside =
                                String.left idx afterOpen

                            rest =
                                String.dropLeft (idx + 1) afterOpen
                                    |> String.trimLeft
                        in
                        parseLocPair inside
                            |> Result.map (\loc -> ( loc, rest ))

                    [] ->
                        Err ("missing ')' for loc in: " ++ raw)
            )


parseLocPair : String -> Result String BoardLocation
parseLocPair inside =
    case String.split "," inside of
        [ l, t ] ->
            case ( String.toInt (String.trim l), String.toInt (String.trim t) ) of
                ( Just left, Just top ) ->
                    Ok { left = left, top = top }

                _ ->
                    Err ("non-integer coords in: " ++ inside)

        _ ->
            Err ("expected (left,top) in: " ++ inside)


parseSide : String -> Result String ( Side, String )
parseSide raw =
    let
        s =
            String.trimLeft raw
    in
    consume "/" s
        |> Result.andThen
            (\afterSlash ->
                case String.words afterSlash of
                    [] ->
                        Err "expected side after '/'"

                    token :: _ ->
                        let
                            rest =
                                String.dropLeft (String.length token) afterSlash
                                    |> String.trimLeft
                        in
                        case token of
                            "left" ->
                                Ok ( Left, rest )

                            "right" ->
                                Ok ( Right, rest )

                            _ ->
                                Err ("expected /left or /right, got /" ++ token)
            )


parsePathSuffix : String -> Result String (List TimeLoc)
parsePathSuffix raw =
    let
        s =
            String.trim raw
    in
    if String.isEmpty s then
        Ok []

    else
        consume "::" s
            |> Result.andThen (consume "path")
            |> Result.andThen parsePathPoints


parsePathPoints : String -> Result String (List TimeLoc)
parsePathPoints raw =
    let
        s =
            String.trim raw
    in
    if String.isEmpty s then
        Ok []

    else
        case String.indexes ")" s of
            idx :: _ ->
                let
                    pointStr =
                        String.left (idx + 1) s

                    rest =
                        String.dropLeft (idx + 1) s
                in
                parseTimeLoc pointStr
                    |> Result.andThen
                        (\tl ->
                            parsePathPoints rest
                                |> Result.map (\tail -> tl :: tail)
                        )

            [] ->
                Err ("malformed path tail: " ++ s)


parseTimeLoc : String -> Result String TimeLoc
parseTimeLoc raw =
    let
        s =
            String.trim raw
    in
    consume "(" s
        |> Result.andThen
            (\afterOpen ->
                case String.indexes ")" afterOpen of
                    idx :: _ ->
                        let
                            inside =
                                String.left idx afterOpen
                        in
                        case String.split "@" inside of
                            [ coords, tMsStr ] ->
                                parseLocPair coords
                                    |> Result.andThen
                                        (\loc ->
                                            case String.toInt (String.trim tMsStr) of
                                                Just t ->
                                                    Ok { tMs = t, left = loc.left, top = loc.top }

                                                Nothing ->
                                                    Err ("non-integer tMs in: " ++ inside)
                                        )

                            _ ->
                                Err ("expected (left,top@tMs) in: " ++ inside)

                    [] ->
                        Err ("missing ')' for timeLoc in: " ++ raw)
            )


parseInt : String -> Result String ( Int, String )
parseInt raw =
    let
        s =
            String.trimLeft raw

        ( digits, rest ) =
            spanDigits s
    in
    case String.toInt digits of
        Just n ->
            Ok ( n, String.trimLeft rest )

        Nothing ->
            Err ("expected integer at: " ++ raw)


spanDigits : String -> ( String, String )
spanDigits s =
    let
        chars =
            String.toList s

        ( hd, tl ) =
            spanList isDigitChar chars
    in
    ( String.fromList hd, String.fromList tl )


spanList : (a -> Bool) -> List a -> ( List a, List a )
spanList pred xs =
    case xs of
        [] ->
            ( [], [] )

        x :: rest ->
            if pred x then
                let
                    ( hd, tl ) =
                        spanList pred rest
                in
                ( x :: hd, tl )

            else
                ( [], xs )


isDigitChar : Char -> Bool
isDigitChar c =
    Char.isDigit c || c == '-'


consume : String -> String -> Result String String
consume prefix raw =
    let
        s =
            String.trimLeft raw
    in
    if String.startsWith prefix s then
        Ok (String.dropLeft (String.length prefix) s |> String.trimLeft)

    else
        Err ("expected '" ++ prefix ++ "' at: " ++ s)


expectEmpty : String -> Result String ()
expectEmpty s =
    if String.isEmpty (String.trim s) then
        Ok ()

    else
        Err ("unexpected trailing input: " ++ s)


sequenceResults : List (Result e a) -> Result e (List a)
sequenceResults =
    List.foldr
        (\r acc ->
            Result.andThen (\xs -> Result.map (\x -> x :: xs) r) acc
        )
        (Ok [])
