module Game.ConformanceDsl exposing
    ( Expect(..)
    , ExpectField(..)
    , Scenario
    , Stack
    , Step
    , parseConformanceDsl
    )

{-| Elm-side parser for the conformance DSL grammar, mirror of
`games/lynrummy/ts/test/conformance_dsl.ts`. Reads one `.dsl`
file's text and returns the scenarios within.

The grammar slice covered here is the union of what every
Elm-only verifier needs (helper / trouble / growing / complete /
existing / board / hand / hint_hand / hint_board / hint_steps /
expect / expect_steps / expect_final_board / expect_wings /
expect_replay / card_count / desc / op / trick / source /
target / steps / actions / stacks_to_remove / stacks_to_add /
board_before). The `expect` block is captured as a generic
`Dict String ExpectField` because each op consumes a different
shape — verifiers project the fields they need.

-}

import Dict exposing (Dict)
import Game.CardStack exposing (BoardLocation)
import Game.Rules.Card as Card exposing (Card, OriginDeck(..))


type alias Scenario =
    { name : String
    , desc : String
    , op : String
    , trick : Maybe String
    , hand : List Card
    , board : List Stack
    , helper : List Stack
    , trouble : List Stack
    , growing : List Stack
    , complete : List Stack
    , existing : List Stack
    , source : List Stack
    , target : List Stack
    , boardBefore : List Stack
    , stacksToRemove : List Stack
    , stacksToAdd : List Stack
    , cardCount : Maybe Int
    , hintHand : List String
    , hintBoard : List (List String)
    , hintSteps : List String
    , actions : List String -- raw action DSL lines (replay scenarios)
    , steps : List Step -- structured steps (undo walkthrough)
    , expect : Expect
    , -- Anything else (gesture scalars like `cursor`, `floater_at`,
      -- `mousedown`, op-specific blocks, etc.) lands here. Verifiers
      -- project by key.
      otherScalars : Dict String String
    , otherBlocks : Dict String (List String) -- raw child line contents
    }


type alias Stack =
    { cards : List Card -- bare cards (no state) — verifiers add state if needed
    , loc : BoardLocation
    }


type alias Step =
    { name : String -- "step_1", "step_2", ...
    , fields : Dict String String -- desc, action, expect_*
    }


{-| `expect:` capture. Either a scalar shorthand
(`expect: no_plan`) or a block of named fields.
-}
type Expect
    = ExpectScalar String
    | ExpectBlock (Dict String ExpectField)
    | ExpectEmpty


{-| Untyped expectation-field values — verifiers do the typed
projection. Most fields are strings (verifiers `String.toInt`
or equality-check as needed); lists and locs are common
enough to be named.
-}
type ExpectField
    = ExpectStr String
    | ExpectLines (List String)
    | ExpectLoc BoardLocation



-- TOKENIZER


type alias Line =
    { raw : String
    , content : String -- stripped of trailing comment + trimmed
    , indent : Int
    , lineNum : Int
    }


tokenize : String -> List Line
tokenize src =
    String.split "\n" src
        |> List.indexedMap toLine
        |> List.filterMap identity


toLine : Int -> String -> Maybe Line
toLine idx raw =
    let
        beforeComment =
            case String.indexes "#" raw of
                hash :: _ ->
                    String.left hash raw

                [] ->
                    raw

        content =
            String.trim beforeComment
    in
    if content == "" then
        Nothing

    else
        Just
            { raw = raw
            , content = content
            , indent = leadingSpaces raw
            , lineNum = idx + 1
            }


leadingSpaces : String -> Int
leadingSpaces s =
    let
        go i =
            if i >= String.length s then
                i

            else
                case String.uncons (String.dropLeft i s) of
                    Just ( ' ', _ ) ->
                        go (i + 1)

                    _ ->
                        i
    in
    go 0



-- TOP-LEVEL PARSE


parseConformanceDsl : String -> List Scenario
parseConformanceDsl src =
    let
        lines =
            tokenize src
    in
    splitScenarios lines


splitScenarios : List Line -> List Scenario
splitScenarios lines =
    case dropUntilScenario lines of
        Nothing ->
            []

        Just ( name, rest ) ->
            let
                ( body, after ) =
                    splitBody rest
            in
            parseScenarioBody name body :: splitScenarios after


dropUntilScenario : List Line -> Maybe ( String, List Line )
dropUntilScenario lines =
    case lines of
        [] ->
            Nothing

        line :: rest ->
            if line.indent == 0 && String.startsWith "scenario " line.content then
                Just ( String.trim (String.dropLeft 9 line.content), rest )

            else
                dropUntilScenario rest


splitBody : List Line -> ( List Line, List Line )
splitBody lines =
    case lines of
        [] ->
            ( [], [] )

        line :: rest ->
            if line.indent == 0 then
                ( [], lines )

            else
                let
                    ( body, after ) =
                        splitBody rest
                in
                ( line :: body, after )



-- SCENARIO BODY


empty : Scenario
empty =
    { name = ""
    , desc = ""
    , op = ""
    , trick = Nothing
    , hand = []
    , board = []
    , helper = []
    , trouble = []
    , growing = []
    , complete = []
    , existing = []
    , source = []
    , target = []
    , boardBefore = []
    , stacksToRemove = []
    , stacksToAdd = []
    , cardCount = Nothing
    , hintHand = []
    , hintBoard = []
    , hintSteps = []
    , actions = []
    , steps = []
    , expect = ExpectEmpty
    , otherScalars = Dict.empty
    , otherBlocks = Dict.empty
    }


parseScenarioBody : String -> List Line -> Scenario
parseScenarioBody name body =
    case body of
        [] ->
            { empty | name = name }

        first :: _ ->
            let
                baseIndent =
                    first.indent

                entries =
                    groupEntries baseIndent body
            in
            List.foldl applyEntry { empty | name = name } entries


{-| Top-level entries within a scenario body. Each is a `key:`
line plus its indented children.
-}
type alias Entry =
    { key : String
    , inline : String -- everything after the colon on the key line
    , children : List Line
    , lineNum : Int
    }


groupEntries : Int -> List Line -> List Entry
groupEntries baseIndent lines =
    case lines of
        [] ->
            []

        line :: rest ->
            if line.indent /= baseIndent then
                -- Strict grammar: top-level entries must align at
                -- baseIndent. Lines deeper than that should have been
                -- consumed as children of a prior entry; lines at
                -- column 0 end the body.
                Debug.todo
                    ("ConformanceDsl: unexpected indent at line "
                        ++ String.fromInt line.lineNum
                        ++ ": "
                        ++ line.raw
                    )

            else
                let
                    ( key, inline ) =
                        splitKey line.content line.lineNum line.raw

                    ( children, after ) =
                        takeChildren baseIndent rest
                in
                { key = key, inline = inline, children = children, lineNum = line.lineNum }
                    :: groupEntries baseIndent after


splitKey : String -> Int -> String -> ( String, String )
splitKey content lineNum raw =
    case String.indexes ":" content of
        idx :: _ ->
            ( String.trim (String.left idx content)
            , String.trim (String.dropLeft (idx + 1) content)
            )

        [] ->
            Debug.todo
                ("ConformanceDsl: expected 'key: ...' at line "
                    ++ String.fromInt lineNum
                    ++ ": "
                    ++ raw
                )


takeChildren : Int -> List Line -> ( List Line, List Line )
takeChildren baseIndent lines =
    case lines of
        [] ->
            ( [], [] )

        line :: rest ->
            if line.indent > baseIndent then
                let
                    ( more, after ) =
                        takeChildren baseIndent rest
                in
                ( line :: more, after )

            else
                ( [], lines )



-- DISPATCH


applyEntry : Entry -> Scenario -> Scenario
applyEntry entry sc =
    if entry.inline == "" then
        applyBlock entry.key entry.children sc

    else if List.isEmpty entry.children then
        applyScalar entry.key entry.inline sc

    else
        Debug.todo
            ("ConformanceDsl: field \""
                ++ entry.key
                ++ "\" has both inline value and children (line "
                ++ String.fromInt entry.lineNum
                ++ ")"
            )


applyScalar : String -> String -> Scenario -> Scenario
applyScalar key val sc =
    case key of
        "desc" ->
            { sc | desc = val }

        "op" ->
            { sc | op = val }

        "trick" ->
            { sc | trick = Just val }

        "card_count" ->
            { sc | cardCount = String.toInt val }

        "hand" ->
            let
                cards =
                    parseCardList val
            in
            { sc
                | hand = cards
                , hintHand = List.map cardLabel cards
            }

        "hint_hand" ->
            { sc | hintHand = List.map cardLabel (parseCardList val) }

        "expect" ->
            { sc | expect = ExpectScalar val }

        _ ->
            -- Op-specific scalar (gesture coords, click intent,
            -- mousedown points, etc.). Verifiers project by key.
            { sc | otherScalars = Dict.insert key val sc.otherScalars }


applyBlock : String -> List Line -> Scenario -> Scenario
applyBlock key children sc =
    case key of
        "helper" ->
            { sc | helper = parseStacks children }

        "trouble" ->
            { sc | trouble = parseStacks children }

        "growing" ->
            { sc | growing = parseStacks children }

        "complete" ->
            { sc | complete = parseStacks children }

        "existing" ->
            { sc | existing = parseStacks children }

        "source" ->
            { sc | source = parseStacks children }

        "target" ->
            { sc | target = parseStacks children }

        "board_before" ->
            { sc | boardBefore = parseStacks children }

        "stacks_to_remove" ->
            { sc | stacksToRemove = parseStacks children }

        "stacks_to_add" ->
            { sc | stacksToAdd = parseStacks children }

        "board" ->
            -- hint_for_hand uses "- cards" rows (no loc); other
            -- ops use "at (t,l): cards".
            case children of
                first :: _ ->
                    if String.startsWith "- " first.content then
                        { sc | hintBoard = parseDashCardLists children }

                    else
                        { sc | board = parseStacks children }

                [] ->
                    sc

        "expect_steps" ->
            { sc | hintSteps = parseDashLines children }

        "actions" ->
            { sc | actions = parseDashLines children }

        "steps" ->
            { sc | steps = parseSteps children }

        "expect" ->
            { sc | expect = ExpectBlock (parseExpectBlock children) }

        _ ->
            -- Op-specific block. Capture raw child line content for
            -- the op's verifier to interpret.
            { sc | otherBlocks = Dict.insert key (List.map .content children) sc.otherBlocks }



-- STACK / CARD HELPERS


parseStacks : List Line -> List Stack
parseStacks lines =
    List.map parseStackLine lines


parseStackLine : Line -> Stack
parseStackLine line =
    if not (String.startsWith "at " line.content) then
        Debug.todo
            ("ConformanceDsl: expected 'at (t,l): cards' at line "
                ++ String.fromInt line.lineNum
                ++ ": "
                ++ line.raw
            )

    else
        let
            rest =
                String.dropLeft 3 line.content
        in
        case String.indexes ")" rest of
            close :: _ ->
                let
                    inside =
                        String.slice 1 close rest

                    tail =
                        String.trim (String.dropLeft (close + 1) rest)

                    ( top, left ) =
                        parseTopLeft inside line.lineNum line.raw

                    cardStr =
                        if String.startsWith ":" tail then
                            String.trim (String.dropLeft 1 tail)

                        else
                            Debug.todo
                                ("ConformanceDsl: expected ':' after location at line "
                                    ++ String.fromInt line.lineNum
                                )
                in
                { cards = parseCardList cardStr
                , loc = { top = top, left = left }
                }

            [] ->
                Debug.todo
                    ("ConformanceDsl: missing ')' at line "
                        ++ String.fromInt line.lineNum
                    )


parseTopLeft : String -> Int -> String -> ( Int, Int )
parseTopLeft inside lineNum raw =
    case String.split "," inside of
        [ a, b ] ->
            case ( String.toInt (String.trim a), String.toInt (String.trim b) ) of
                ( Just top, Just left ) ->
                    ( top, left )

                _ ->
                    Debug.todo
                        ("ConformanceDsl: non-integer (top,left) at line "
                            ++ String.fromInt lineNum
                            ++ ": "
                            ++ raw
                        )

        _ ->
            Debug.todo
                ("ConformanceDsl: bad location syntax at line "
                    ++ String.fromInt lineNum
                    ++ ": "
                    ++ raw
                )


parseCardList : String -> List Card
parseCardList s =
    String.words (String.trim s)
        |> List.filter (\w -> w /= "")
        |> List.map parseCardToken


parseCardToken : String -> Card
parseCardToken raw =
    let
        -- Strip trailing state markers (`*` = FreshlyPlayed,
        -- `**` = FreshlyPlayedByLastPlayer). Cards on the wire
        -- carry state via these suffixes; the parser drops them
        -- here so all consumers see bare Cards. Verifiers that
        -- need state can re-parse the original token via the raw
        -- DSL text.
        tok =
            raw
                |> dropSuffix "**"
                |> dropSuffix "*"

        ( base, deck ) =
            if String.endsWith "'" tok then
                ( String.dropRight 1 tok, DeckTwo )

            else
                ( tok, DeckOne )
    in
    case Card.cardFromLabel base deck of
        Just c ->
            c

        Nothing ->
            Debug.todo ("ConformanceDsl: invalid card label: " ++ raw)


dropSuffix : String -> String -> String
dropSuffix suffix s =
    if String.endsWith suffix s then
        String.dropRight (String.length suffix) s

    else
        s


cardLabel : Card -> String
cardLabel c =
    -- Match the TS / fixturegen label form: "<value><suit>" or
    -- "<value><suit>'". Always ASCII-suit here for fixture
    -- back-compat (gold strings); the parser side already accepts
    -- both ASCII and unicode.
    let
        valueChar =
            case c.value of
                Card.Ace ->
                    "A"

                Card.Two ->
                    "2"

                Card.Three ->
                    "3"

                Card.Four ->
                    "4"

                Card.Five ->
                    "5"

                Card.Six ->
                    "6"

                Card.Seven ->
                    "7"

                Card.Eight ->
                    "8"

                Card.Nine ->
                    "9"

                Card.Ten ->
                    "T"

                Card.Jack ->
                    "J"

                Card.Queen ->
                    "Q"

                Card.King ->
                    "K"

        suitChar =
            case c.suit of
                Card.Club ->
                    "C"

                Card.Diamond ->
                    "D"

                Card.Spade ->
                    "S"

                Card.Heart ->
                    "H"

        deckSuffix =
            case c.originDeck of
                DeckOne ->
                    ""

                DeckTwo ->
                    "'"
    in
    valueChar ++ suitChar ++ deckSuffix


parseDashLines : List Line -> List String
parseDashLines lines =
    List.map parseDashLine lines


parseDashLine : Line -> String
parseDashLine line =
    if String.startsWith "- " line.content then
        let
            rest =
                String.trim (String.dropLeft 2 line.content)
        in
        if String.startsWith "\"" rest && String.endsWith "\"" rest then
            String.slice 1 -1 rest

        else
            rest

    else
        Debug.todo
            ("ConformanceDsl: expected '- ...' at line "
                ++ String.fromInt line.lineNum
                ++ ": "
                ++ line.raw
            )


parseDashCardLists : List Line -> List (List String)
parseDashCardLists =
    List.map
        (parseDashLine
            >> String.words
            >> List.filter (\w -> w /= "")
        )


parseSteps : List Line -> List Step
parseSteps children =
    case children of
        [] ->
            []

        first :: _ ->
            let
                baseIndent =
                    first.indent

                entries =
                    groupEntries baseIndent children
            in
            List.map entryToStep entries


entryToStep : Entry -> Step
entryToStep entry =
    let
        fields =
            entry.children
                |> List.filterMap
                    (\line ->
                        let
                            ( key, val ) =
                                splitKey line.content line.lineNum line.raw
                        in
                        Just ( key, val )
                    )
                |> Dict.fromList
    in
    { name = entry.key, fields = fields }



-- EXPECT BLOCK


parseExpectBlock : List Line -> Dict String ExpectField
parseExpectBlock children =
    case children of
        [] ->
            Dict.empty

        first :: _ ->
            let
                baseIndent =
                    first.indent

                entries =
                    groupEntries baseIndent children
            in
            List.foldl applyExpectEntry Dict.empty entries


applyExpectEntry : Entry -> Dict String ExpectField -> Dict String ExpectField
applyExpectEntry entry acc =
    if entry.inline == "" && not (List.isEmpty entry.children) then
        applyExpectBlockField entry.key entry.children acc

    else if List.isEmpty entry.children then
        applyExpectScalarField entry.key entry.inline acc

    else
        Debug.todo
            ("ConformanceDsl: expect field \""
                ++ entry.key
                ++ "\" has both inline value and children"
            )


applyExpectScalarField : String -> String -> Dict String ExpectField -> Dict String ExpectField
applyExpectScalarField key val acc =
    case key of
        "loc" ->
            -- "(top,left)"
            case parseParenPair val of
                Just ( top, left ) ->
                    Dict.insert key
                        (ExpectLoc { top = top, left = left })
                        acc

                Nothing ->
                    Debug.todo ("ConformanceDsl: expect.loc bad syntax: " ++ val)

        _ ->
            -- Keep raw — verifiers parse ints / bools / paths as
            -- they need them. One untyped channel keeps the API
            -- small.
            Dict.insert key (ExpectStr val) acc


applyExpectBlockField : String -> List Line -> Dict String ExpectField -> Dict String ExpectField
applyExpectBlockField key children acc =
    if allDashLines children then
        Dict.insert key (ExpectLines (parseDashLines children)) acc

    else
        -- Unknown nested block shape inside expect. Capture as raw
        -- child line content; the op's verifier interprets.
        Dict.insert key (ExpectLines (List.map .content children)) acc


allDashLines : List Line -> Bool
allDashLines lines =
    List.all (\l -> String.startsWith "- " l.content) lines


parseParenPair : String -> Maybe ( Int, Int )
parseParenPair s =
    if String.startsWith "(" s && String.endsWith ")" s then
        case String.split "," (String.slice 1 -1 s) of
            [ a, b ] ->
                Maybe.map2 Tuple.pair
                    (String.toInt (String.trim a))
                    (String.toInt (String.trim b))

            _ ->
                Nothing

    else
        Nothing
