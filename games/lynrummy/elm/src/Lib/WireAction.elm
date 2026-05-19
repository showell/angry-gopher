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
import Lib.GameEvent as GameEvent exposing (GameEvent(..))
import Lib.NonEmpty as NonEmpty exposing (NonEmpty)
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

    else if String.startsWith "isolate " s then
        parseIsolate (String.dropLeft 8 s)

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
    case splitOnSlash s of
        [ leftStr, rightStr ] ->
            Result.map2
                (\left right ->
                    let
                        cards =
                            left ++ right

                        cardIndex =
                            GameEvent.splitCardIndexFromLeftCount
                                (List.length left)
                                (List.length cards)
                    in
                    Split
                        { stack = stackOfCards cards
                        , cardIndex = cardIndex
                        }
                )
                (parseCardList leftStr)
                (parseCardList rightStr)

        _ ->
            Err ("expected 'split <left> / <right>' in: " ++ s)


parseIsolate : String -> Result String GameEvent
parseIsolate s =
    case splitOnParens s of
        Just { before, held, after } ->
            parseCardList before
                |> Result.andThen
                    (\b ->
                        parseHeldCard held
                            |> Result.andThen
                                (\h ->
                                    parseCardList after
                                        |> Result.map
                                            (\a ->
                                                Isolate
                                                    { stack = stackOfCards (b ++ [ h ] ++ a)
                                                    , cardIndex = List.length b
                                                    }
                                            )
                                )
                    )

        Nothing ->
            Err ("expected 'isolate <before> ( <held> ) <after>' in: " ++ s)


splitOnParens : String -> Maybe { before : String, held : String, after : String }
splitOnParens body =
    case String.indexes "(" body of
        open :: _ ->
            case String.indexes ")" (String.dropLeft (open + 1) body) of
                offset :: _ ->
                    let
                        close =
                            open + 1 + offset
                    in
                    Just
                        { before = String.left open body |> String.trim
                        , held =
                            String.slice (open + 1) close body |> String.trim
                        , after = String.dropLeft (close + 1) body |> String.trim
                        }

                [] ->
                    Nothing

        [] ->
            Nothing


parseHeldCard : String -> Result String Card
parseHeldCard s =
    parseCardList s
        |> Result.andThen
            (\cards ->
                case cards of
                    [ c ] ->
                        Ok c

                    _ ->
                        Err ("isolate held chunk must have exactly one card: " ++ s)
            )


splitOnSlash : String -> List String
splitOnSlash s =
    String.split "/" s |> List.map String.trim


stackOfCards : List Card -> CardStack
stackOfCards cards =
    { boardCards =
        List.map (\c -> { card = c, state = FirmlyOnBoard }) cards
    , loc = { left = 0, top = 0 }
    }


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


{-| Parse the required `:: path (l,t@ms)(...)...` suffix on
merge_stack / move_stack lines. Both action types need a non-
empty animation path on the wire (the Elm animator dispatches
on it). Missing suffix → Err; suffix present but no points → Err.
-}
parsePathSuffix : String -> Result String (NonEmpty TimeLoc)
parsePathSuffix raw =
    let
        s =
            String.trim raw
    in
    if String.isEmpty s then
        Err "expected ':: path (...)' suffix"

    else
        consume "::" s
            |> Result.andThen (consume "path")
            |> Result.andThen parsePathPoints
            |> Result.andThen
                (\points ->
                    case NonEmpty.fromList points of
                        Just ne ->
                            Ok ne

                        Nothing ->
                            Err "':: path' suffix has no points"
                )


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
