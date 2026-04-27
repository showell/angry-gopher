module Game.Referee exposing
    ( RefereeError
    , RefereeMove
    , RefereeStage(..)
    , encodeRefereeError
    , encodeRefereeMove
    , encodeRefereeResult
    , refereeErrorDecoder
    , refereeMoveDecoder
    , refereeResultDecoder
    , refereeStageToString
    , validateGameMove
    , validateTurnComplete
    )

{-| Game referee — stateless move and turn validation. Ported
from `angry-cat/src/lyn_rummy/game/referee.ts`.

The referee is like an expert in the other room. You show them
the board and the proposed move, they give a ruling. They don't
need to remember anything — the board is the state.

Two entry points:

  - `validateGameMove` — rule on a single move during a turn.
    The board can be messy mid-turn. Four stages:
    1.  Protocol — is the JSON well-formed? (stubbed)
    2.  Geometry — do stacks fit without illegal overlap? (stubbed)
    3.  Inventory — are cards conserved?
        Semantics is NOT checked here; mid-turn messiness (incomplete
        stacks, splits in progress) is allowed.

  - `validateTurnComplete` — rule on whether the turn can end.
    The board must be clean before we move on to the next
    player. Checks geometry and semantics.

The referee does not enforce turn order, player identity, or
how many moves per turn. Those are social rules, not physics.

\*\*Elm port <notes:**>

  - Returns `Result RefereeError ()` rather than TS's
    `RefereeError | undefined`. `Ok ()` = move is valid.
  - Stage-based early-exit validators map to `Result.andThen`
    chains (insight #7).
  - Protocol and geometry stages are currently stubbed via
    `Game.BoardGeometry` and a pass-through here. Real
    implementations will be ported later.
  - `stacks_to_remove` is matched by `stacksEqual`, which
    compares full card identity including `originDeck` so
    inventory accounting stays conservative on double-deck
    boards.

-}

import Game.BoardGeometry exposing (BoardBounds, validateBoardGeometry)
import Game.Card exposing (Card)
import Game.CardStack
    exposing
        ( CardStack
        , HandCard
        , cardStackDecoder
        , encodeCardStack
        , encodeHandCard
        , handCardDecoder
        , stacksEqual
        )
import Game.StackType exposing (CardStackType(..), getStackType)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)



-- TYPES


type RefereeStage
    = Protocol
    | Geometry
    | Semantics
    | Inventory


type alias RefereeError =
    { stage : RefereeStage
    , message : String
    }


type alias RefereeMove =
    { boardBefore : List CardStack
    , stacksToRemove : List CardStack
    , stacksToAdd : List CardStack

    -- TS used optional; Elm uses empty list to mean "no hand cards played."
    , handCardsPlayed : List HandCard
    }



-- ENTRY POINTS


{-| Rule on a single mid-turn move. Skips semantics by design —
the board is allowed to be messy while the player works. Runs
protocol, geometry, and inventory checks in order.
-}
validateGameMove : RefereeMove -> BoardBounds -> Result RefereeError ()
validateGameMove move bounds =
    checkProtocol
        |> Result.andThen (\() -> computeBoardAfter move)
        |> Result.andThen
            (\boardAfter ->
                checkGeometry boardAfter bounds
                    |> Result.andThen (\() -> checkInventory move boardAfter)
            )


{-| Rule on end-of-turn. The board must be clean: geometry valid
and every stack semantically correct. No mid-turn messiness
allowed.
-}
validateTurnComplete : List CardStack -> BoardBounds -> Result RefereeError ()
validateTurnComplete board bounds =
    checkGeometry board bounds
        |> Result.andThen (\() -> checkSemantics board)



-- STAGE 1: PROTOCOL (stubbed)


checkProtocol : Result RefereeError ()
checkProtocol =
    -- Placeholder. Real implementation is deferred; see
    -- `angry-cat/src/lyn_rummy/game/protocol_validation.ts`.
    Ok ()



-- STAGE 2: GEOMETRY
--
-- Any geometry error (including "too close") rejects the move.
-- This mirrors the TS referee which treats all errors as
-- failures. Whether `TooClose` should fail at the referee level
-- vs. only warn is an open question noted in PORTING_NOTES.


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



-- STAGE 3: SEMANTICS


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
        |> List.map (.card >> Game.Card.cardStr)
        |> String.join ","



-- STAGE 4: INVENTORY


{-| Cards are conserved. Every card on the resulting board must
have a source: either it was already on the board (via
stacks\_to\_remove) or it came from the player's hand.

Also checks: no duplicate cards on the resulting board, and
every declared hand card was actually placed.

-}
checkInventory : RefereeMove -> List CardStack -> Result RefereeError ()
checkInventory move boardAfter =
    let
        pool =
            cardsFromStacks move.stacksToRemove
                ++ List.map .card move.handCardsPlayed

        addedCards =
            cardsFromStacks move.stacksToAdd
    in
    consumeFromPool pool addedCards
        |> Result.andThen (checkEveryHandCardPlaced move.handCardsPlayed)
        |> Result.andThen (\_ -> checkNoBoardDuplicates boardAfter)


cardsFromStacks : List CardStack -> List Card
cardsFromStacks stacks =
    stacks
        |> List.concatMap .boardCards
        |> List.map .card


{-| Try to consume each card in `added` from the pool. Returns
the leftover pool if all consumed; `Err` if any card had no
source.
-}
consumeFromPool : List Card -> List Card -> Result RefereeError (List Card)
consumeFromPool pool added =
    case added of
        [] ->
            Ok pool

        card :: rest ->
            case removeFirst ((==) card) pool of
                Just leftover ->
                    consumeFromPool leftover rest

                Nothing ->
                    Err
                        { stage = Inventory
                        , message =
                            "card "
                                ++ Game.Card.cardStr card
                                ++ " appeared on the board with no source"
                        }


{-| After consuming stacks\_to\_add from the pool, any hand card
still sitting in the pool was declared played but never placed.
-}
checkEveryHandCardPlaced : List HandCard -> List Card -> Result RefereeError (List Card)
checkEveryHandCardPlaced handCards leftoverPool =
    case findFirstUnplaced (List.map .card handCards) leftoverPool of
        Just c ->
            Err
                { stage = Inventory
                , message =
                    "hand card "
                        ++ Game.Card.cardStr c
                        ++ " was declared played but not placed on the board"
                }

        Nothing ->
            Ok leftoverPool


findFirstUnplaced : List Card -> List Card -> Maybe Card
findFirstUnplaced handCards leftoverPool =
    case handCards of
        [] ->
            Nothing

        c :: rest ->
            if List.member c leftoverPool then
                Just c

            else
                findFirstUnplaced rest leftoverPool


checkNoBoardDuplicates : List CardStack -> Result RefereeError ()
checkNoBoardDuplicates board =
    case findFirstDuplicate (cardsFromStacks board) of
        Just c ->
            Err
                { stage = Inventory
                , message =
                    "duplicate card on board: "
                        ++ Game.Card.cardStr c
                }

        Nothing ->
            Ok ()


findFirstDuplicate : List Card -> Maybe Card
findFirstDuplicate cards =
    case cards of
        [] ->
            Nothing

        c :: rest ->
            if List.member c rest then
                Just c

            else
                findFirstDuplicate rest



-- BOARD DERIVATION
--
-- Remove the stacks_to_remove, then append the stacks_to_add.
-- Returns Err if any stack in stacks_to_remove wasn't on the
-- board. Matches stacks via `stacksEqual` (full card identity
-- including originDeck).


computeBoardAfter : RefereeMove -> Result RefereeError (List CardStack)
computeBoardAfter move =
    case subtractStacks move.boardBefore move.stacksToRemove of
        Ok remaining ->
            Ok (remaining ++ move.stacksToAdd)

        Err () ->
            Err
                { stage = Inventory
                , message =
                    "stacks_to_remove contains a stack not on the board"
                }


subtractStacks : List CardStack -> List CardStack -> Result () (List CardStack)
subtractStacks board toRemove =
    case toRemove of
        [] ->
            Ok board

        s :: rest ->
            case removeFirst (stacksEqual s) board of
                Just newBoard ->
                    subtractStacks newBoard rest

                Nothing ->
                    Err ()



-- GENERAL HELPERS


{-| Remove the first element matching the predicate; return the
remaining list. `Nothing` if no match.
-}
removeFirst : (a -> Bool) -> List a -> Maybe (List a)
removeFirst pred list =
    removeFirstHelp pred [] list


removeFirstHelp : (a -> Bool) -> List a -> List a -> Maybe (List a)
removeFirstHelp pred acc list =
    case list of
        [] ->
            Nothing

        x :: rest ->
            if pred x then
                Just (List.reverse acc ++ rest)

            else
                removeFirstHelp pred (x :: acc) rest



-- JSON: WIRE FORMAT
--
-- Mirrors the TS shapes:
--   RefereeMove = {
--     board_before: JsonCardStack[],
--     stacks_to_remove: JsonCardStack[],
--     stacks_to_add: JsonCardStack[],
--     hand_cards_played?: JsonHandCard[]   // optional in TS
--   }
--   RefereeError = {
--     stage: "protocol" | "geometry" | "semantics" | "inventory",
--     message: string
--   }
--
-- The TS optional `hand_cards_played?` becomes:
--   - encoder: omit the field when the list is empty
--   - decoder: treat absence as empty list


refereeStageToString : RefereeStage -> String
refereeStageToString stage =
    case stage of
        Protocol ->
            "protocol"

        Geometry ->
            "geometry"

        Semantics ->
            "semantics"

        Inventory ->
            "inventory"


stringToRefereeStage : String -> Maybe RefereeStage
stringToRefereeStage s =
    case s of
        "protocol" ->
            Just Protocol

        "geometry" ->
            Just Geometry

        "semantics" ->
            Just Semantics

        "inventory" ->
            Just Inventory

        _ ->
            Nothing


encodeRefereeError : RefereeError -> Value
encodeRefereeError err =
    Encode.object
        [ ( "stage", Encode.string (refereeStageToString err.stage) )
        , ( "message", Encode.string err.message )
        ]


refereeErrorDecoder : Decoder RefereeError
refereeErrorDecoder =
    Decode.map2
        (\stage msg -> { stage = stage, message = msg })
        (Decode.field "stage" stageDecoder)
        (Decode.field "message" Decode.string)


stageDecoder : Decoder RefereeStage
stageDecoder =
    Decode.string
        |> Decode.andThen
            (\s ->
                case stringToRefereeStage s of
                    Just stage ->
                        Decode.succeed stage

                    Nothing ->
                        Decode.fail
                            ("invalid referee stage: " ++ s)
            )


encodeRefereeMove : RefereeMove -> Value
encodeRefereeMove move =
    let
        baseFields =
            [ ( "board_before", Encode.list encodeCardStack move.boardBefore )
            , ( "stacks_to_remove", Encode.list encodeCardStack move.stacksToRemove )
            , ( "stacks_to_add", Encode.list encodeCardStack move.stacksToAdd )
            ]

        fields =
            if List.isEmpty move.handCardsPlayed then
                baseFields

            else
                baseFields
                    ++ [ ( "hand_cards_played"
                         , Encode.list encodeHandCard move.handCardsPlayed
                         )
                       ]
    in
    Encode.object fields


refereeMoveDecoder : Decoder RefereeMove
refereeMoveDecoder =
    Decode.map4
        (\bb stRm stAdd hcp ->
            { boardBefore = bb
            , stacksToRemove = stRm
            , stacksToAdd = stAdd
            , handCardsPlayed = hcp
            }
        )
        (Decode.field "board_before" (Decode.list cardStackDecoder))
        (Decode.field "stacks_to_remove" (Decode.list cardStackDecoder))
        (Decode.field "stacks_to_add" (Decode.list cardStackDecoder))
        (Decode.oneOf
            [ Decode.field "hand_cards_played" (Decode.list handCardDecoder)
            , Decode.succeed []
            ]
        )


{-| Encode a referee result (Ok / Err) to a wire-friendly
shape:

    Ok ()  -> { "ok": true }
    Err e  -> { "ok": false, "error": <RefereeError> }

The TS source returns `RefereeError | undefined` from
`validate_game_move` and `validate_turn_complete`, but the
absent `undefined` doesn't survive JSON cleanly. The wire shape
makes the success-or-failure explicit.

-}
encodeRefereeResult : Result RefereeError () -> Value
encodeRefereeResult result =
    case result of
        Ok () ->
            Encode.object
                [ ( "ok", Encode.bool True ) ]

        Err err ->
            Encode.object
                [ ( "ok", Encode.bool False )
                , ( "error", encodeRefereeError err )
                ]


refereeResultDecoder : Decoder (Result RefereeError ())
refereeResultDecoder =
    Decode.field "ok" Decode.bool
        |> Decode.andThen
            (\ok ->
                if ok then
                    Decode.succeed (Ok ())

                else
                    Decode.field "error" refereeErrorDecoder
                        |> Decode.map Err
            )
