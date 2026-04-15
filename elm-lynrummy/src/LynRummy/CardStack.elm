module LynRummy.CardStack exposing
    ( BoardCard
    , BoardCardState(..)
    , BoardLocation
    , CardStack
    , HandCard
    , HandCardState(..)
    , agedFromPriorTurn
    , boardCardAgedState
    , boardCardDecoder
    , boardCardSameCard
    , boardCardStateToInt
    , boardLocationDecoder
    , canExtract
    , cardStackDecoder
    , cardWidth
    , encodeBoardCard
    , encodeBoardLocation
    , encodeCardStack
    , encodeHandCard
    , fromHandCard
    , fromShorthand
    , handCardDecoder
    , handCardSameCard
    , handCardStateToInt
    , intToBoardCardState
    , intToHandCardState
    , incomplete
    , leftMerge
    , leftSplit
    , locsEqual
    , maybeMerge
    , problematic
    , rightMerge
    , rightSplit
    , size
    , split
    , stackCards
    , stackStr
    , stackType
    , stacksEqual
    )

{-| CardStack domain types and operations. Ported from
`angry-cat/src/lyn_rummy/core/card_stack.ts`.

Intentional Elm divergences:

  - `CardStack.stackType` is a function (derived on demand), not
    a stored field. Insight #5 — don't carry state that's a pure
    function of other state.
  - `stacksEqual` deliberately ignores `originDeck` AND
    BoardCard `state` — the equality reflects what the
    *player* sees on the board, since the referee uses it to
    match `stacksToRemove` against the player-supplied move.
    See the function docstring for the full rationale and the
    other available equality concepts.
  - `clone` is N/A in Elm (values are inherently immutable).
  - `toJSON` / `fromJson` deferred (boundary plumbing).
  - `pullFromDeck` deferred (requires a pure model of the deck
    rather than TS's mutable `DeckRef` interface).
  - `CARD_WIDTH` lives in this module by design — position is
    domain data (every `CardStack` carries a `loc`), so
    split/merge producing correct positions is domain work.
    See `OPEN_QUESTIONS.md` (Resolved, 2026-04-14) for the
    full rationale.

-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import LynRummy.Card
    exposing
        ( Card
        , OriginDeck
        , cardDecoder
        , cardFromLabel
        , cardStr
        , encodeCard
        )
import LynRummy.StackType
    exposing
        ( CardStackType(..)
        , getStackType
        )



-- STATE ENUMS


type HandCardState
    = HandNormal
    | FreshlyDrawn
    | BackFromBoard


type BoardCardState
    = FirmlyOnBoard
    | FreshlyPlayed
    | FreshlyPlayedByLastPlayer



-- TYPES


type alias HandCard =
    { card : Card
    , state : HandCardState
    }


type alias BoardCard =
    { card : Card
    , state : BoardCardState
    }


type alias BoardLocation =
    { top : Int
    , left : Int
    }


type alias CardStack =
    { boardCards : List BoardCard -- order matters!
    , loc : BoardLocation
    }



-- CONSTANTS


{-| Card width in pixels, used for split/merge positioning.
Lives in this module deliberately: position is domain data
(every `CardStack` carries a `loc`), and `split` / `merge`
produce correct positions as part of their semantic contract.
See `OPEN_QUESTIONS.md` (Resolved) for the rationale.
-}
cardWidth : Int
cardWidth =
    27



-- QUERIES


stackCards : CardStack -> List Card
stackCards s =
    List.map .card s.boardCards


size : CardStack -> Int
size s =
    List.length s.boardCards


stackType : CardStack -> CardStackType
stackType s =
    getStackType (stackCards s)


stackStr : CardStack -> String
stackStr s =
    s.boardCards
        |> List.map (.card >> cardStr)
        |> String.join ","


{-| CardStack equality from the player's perspective. Two
stacks compare equal iff:

  - their cards display the same (same `value` + `suit` in the
    same order — `originDeck` and BoardCard `state` are
    *intentionally ignored*), AND
  - their `loc` values are equal.

This is the equality the referee uses to match
`stacksToRemove` against the board: it mirrors what the player
*sees*. The player can't distinguish a 5♥ from `DeckOne` vs
`DeckTwo` — they look identical — so the referee shouldn't
either. `loc` does the disambiguation when two stacks have the
same display.

If you want strict full-identity equality (every field
including deck and recency), use `==` directly on the records.

-}
stacksEqual : CardStack -> CardStack -> Bool
stacksEqual a b =
    stackStr a == stackStr b && locsEqual a.loc b.loc


locsEqual : BoardLocation -> BoardLocation -> Bool
locsEqual a b =
    a.top == b.top && a.left == b.left


{-| `BoardCard` equality that ignores `state`. Use when you
mean "do these two BoardCards wrap the same `Card`?" — recency
markers don't participate. For full identity (including state),
use `==` on the records directly.
-}
boardCardSameCard : BoardCard -> BoardCard -> Bool
boardCardSameCard a b =
    a.card == b.card


{-| `HandCard` equality that ignores `state`. Same shape and
rationale as `boardCardSameCard`.
-}
handCardSameCard : HandCard -> HandCard -> Bool
handCardSameCard a b =
    a.card == b.card


incomplete : CardStack -> Bool
incomplete s =
    stackType s == Incomplete


problematic : CardStack -> Bool
problematic s =
    case stackType s of
        Bogus ->
            True

        Dup ->
            True

        _ ->
            False



-- AGING


boardCardAgedState : BoardCardState -> BoardCardState
boardCardAgedState state =
    case state of
        FreshlyPlayedByLastPlayer ->
            FirmlyOnBoard

        FreshlyPlayed ->
            FreshlyPlayedByLastPlayer

        FirmlyOnBoard ->
            FirmlyOnBoard


agedFromPriorTurn : CardStack -> CardStack
agedFromPriorTurn s =
    { s
        | boardCards =
            List.map
                (\bc -> { bc | state = boardCardAgedState bc.state })
                s.boardCards
    }



-- CONSTRUCTION


fromHandCard : HandCard -> BoardLocation -> CardStack
fromHandCard hc loc =
    { boardCards = [ { card = hc.card, state = FreshlyPlayed } ]
    , loc = loc
    }


{-| Build a stack from a comma-separated shorthand of card
labels (e.g., `"AH,2H,3H"`). All cards land in the same
`OriginDeck` and start as `FirmlyOnBoard`. Returns `Nothing` if
any label is malformed.

The TS source's `pull_from_deck` also pulled the cards from a
mutable `DeckRef`. The Elm version omits the deck-pool
semantic — it's a parse-and-build helper, not a deck mutator.
If callers need uniqueness tracking, they manage the deck
state explicitly (see OPEN\_QUESTIONS history for the rationale).

-}
fromShorthand : String -> OriginDeck -> BoardLocation -> Maybe CardStack
fromShorthand shorthand deck loc =
    String.split "," shorthand
        |> List.map (\label -> cardFromLabel label deck)
        |> List.foldr (Maybe.map2 (::)) (Just [])
        |> Maybe.map
            (\cards ->
                { boardCards =
                    List.map
                        (\c -> { card = c, state = FirmlyOnBoard })
                        cards
                , loc = loc
                }
            )



-- SPLIT
--
-- Splits a stack at `cardIndex`. If the split point is in the
-- left half of the stack, left_split handles positioning; if
-- in the right half, right_split does. The two paths produce
-- different `loc` adjustments (same TS behavior).


split : Int -> CardStack -> List CardStack
split cardIndex s =
    if size s <= 1 then
        -- Caller is expected to check this. Preserve the TS
        -- "throw" semantics here by returning the stack unchanged
        -- (the Elm port favors total functions over exceptions).
        [ s ]

    else if cardIndex + 1 <= size s // 2 then
        leftSplit (cardIndex + 1) s

    else
        rightSplit cardIndex s


leftSplit : Int -> CardStack -> List CardStack
leftSplit leftCount s =
    let
        leftCards =
            List.take leftCount s.boardCards

        rightCards =
            List.drop leftCount s.boardCards

        leftSideOffset =
            -2

        rightSideOffset =
            leftCount * (cardWidth + 6) + 8

        leftLoc =
            { top = s.loc.top - 4
            , left = s.loc.left + leftSideOffset
            }

        rightLoc =
            { top = s.loc.top
            , left = s.loc.left + rightSideOffset
            }
    in
    [ { boardCards = leftCards, loc = leftLoc }
    , { boardCards = rightCards, loc = rightLoc }
    ]


rightSplit : Int -> CardStack -> List CardStack
rightSplit leftCount s =
    let
        leftCards =
            List.take leftCount s.boardCards

        rightCards =
            List.drop leftCount s.boardCards

        leftSideOffset =
            -8

        rightSideOffset =
            leftCount * (cardWidth + 6) + 4

        leftLoc =
            { top = s.loc.top
            , left = s.loc.left + leftSideOffset
            }

        rightLoc =
            { top = s.loc.top - 4
            , left = s.loc.left + rightSideOffset
            }
    in
    [ { boardCards = leftCards, loc = leftLoc }
    , { boardCards = rightCards, loc = rightLoc }
    ]



-- MERGE


{-| Attempt a merge. Returns `Nothing` if:

  - The two stacks are `stacksEqual` (prevents merging a stack
    with itself — also prevents merging two identical piles,
    which can never produce a valid result).
  - The combined result is problematic (Bogus or Dup).

Otherwise returns `Just` the merged stack positioned at `loc`.

-}
maybeMerge : CardStack -> CardStack -> BoardLocation -> Maybe CardStack
maybeMerge s1 s2 loc =
    if stacksEqual s1 s2 then
        Nothing

    else
        let
            merged =
                { boardCards = s1.boardCards ++ s2.boardCards
                , loc = loc
                }
        in
        if problematic merged then
            Nothing

        else
            Just merged


leftMerge : CardStack -> CardStack -> Maybe CardStack
leftMerge self other =
    let
        loc =
            { left = self.loc.left - (cardWidth + 6) * size other
            , top = self.loc.top
            }
    in
    maybeMerge other self loc


rightMerge : CardStack -> CardStack -> Maybe CardStack
rightMerge self other =
    let
        loc =
            { left = self.loc.left
            , top = self.loc.top
            }
    in
    maybeMerge self other loc



-- ENUM <-> INT CONVERSIONS
--
-- Mirrors TS implicit numeric enums (NORMAL=0, FRESHLY_DRAWN=1,
-- BACK_FROM_BOARD=2; FIRMLY_ON_BOARD=0, FRESHLY_PLAYED=1,
-- FRESHLY_PLAYED_BY_LAST_PLAYER=2).


handCardStateToInt : HandCardState -> Int
handCardStateToInt s =
    case s of
        HandNormal ->
            0

        FreshlyDrawn ->
            1

        BackFromBoard ->
            2


intToHandCardState : Int -> Maybe HandCardState
intToHandCardState n =
    case n of
        0 ->
            Just HandNormal

        1 ->
            Just FreshlyDrawn

        2 ->
            Just BackFromBoard

        _ ->
            Nothing


boardCardStateToInt : BoardCardState -> Int
boardCardStateToInt s =
    case s of
        FirmlyOnBoard ->
            0

        FreshlyPlayed ->
            1

        FreshlyPlayedByLastPlayer ->
            2


intToBoardCardState : Int -> Maybe BoardCardState
intToBoardCardState n =
    case n of
        0 ->
            Just FirmlyOnBoard

        1 ->
            Just FreshlyPlayed

        2 ->
            Just FreshlyPlayedByLastPlayer

        _ ->
            Nothing



-- JSON: WIRE FORMAT
--
-- Mirrors the TS shapes:
--   JsonHandCard  = { card: JsonCard, state: <int 0-2> }
--   JsonBoardCard = { card: JsonCard, state: <int 0-2> }
--   BoardLocation = { top: number, left: number }
--   JsonCardStack = { board_cards: JsonBoardCard[], loc: BoardLocation }


encodeBoardLocation : BoardLocation -> Value
encodeBoardLocation loc =
    Encode.object
        [ ( "top", Encode.int loc.top )
        , ( "left", Encode.int loc.left )
        ]


boardLocationDecoder : Decoder BoardLocation
boardLocationDecoder =
    Decode.map2
        (\top left -> { top = top, left = left })
        (Decode.field "top" Decode.int)
        (Decode.field "left" Decode.int)


encodeHandCard : HandCard -> Value
encodeHandCard hc =
    Encode.object
        [ ( "card", encodeCard hc.card )
        , ( "state", Encode.int (handCardStateToInt hc.state) )
        ]


handCardDecoder : Decoder HandCard
handCardDecoder =
    Decode.map2
        (\card state -> { card = card, state = state })
        (Decode.field "card" cardDecoder)
        (Decode.field "state" (intDecoderVia intToHandCardState "hand card state"))


encodeBoardCard : BoardCard -> Value
encodeBoardCard bc =
    Encode.object
        [ ( "card", encodeCard bc.card )
        , ( "state", Encode.int (boardCardStateToInt bc.state) )
        ]


boardCardDecoder : Decoder BoardCard
boardCardDecoder =
    Decode.map2
        (\card state -> { card = card, state = state })
        (Decode.field "card" cardDecoder)
        (Decode.field "state" (intDecoderVia intToBoardCardState "board card state"))


encodeCardStack : CardStack -> Value
encodeCardStack stack =
    Encode.object
        [ ( "board_cards", Encode.list encodeBoardCard stack.boardCards )
        , ( "loc", encodeBoardLocation stack.loc )
        ]


cardStackDecoder : Decoder CardStack
cardStackDecoder =
    Decode.map2
        (\boardCards loc -> { boardCards = boardCards, loc = loc })
        (Decode.field "board_cards" (Decode.list boardCardDecoder))
        (Decode.field "loc" boardLocationDecoder)


{-| Internal: same shape as `LynRummy.Card.intDecoderVia`.
Duplicated rather than exported across module boundary; both
modules need the helper privately.
-}
intDecoderVia : (Int -> Maybe a) -> String -> Decoder a
intDecoderVia toMaybe label =
    Decode.int
        |> Decode.andThen
            (\n ->
                case toMaybe n of
                    Just a ->
                        Decode.succeed a

                    Nothing ->
                        Decode.fail
                            ("invalid "
                                ++ label
                                ++ ": "
                                ++ String.fromInt n
                            )
            )



-- EXTRACT
--
-- canExtract reports whether the card at `cardIdx` can be legally
-- extracted by a trick: end-peel (size >= 4), set-peel (any pos
-- in a 4+ SET), or middle-peel (run where both halves are >= 3).
-- Mirrors angry-gopher/lynrummy/card_stack.go CanExtract.


canExtract : CardStack -> Int -> Bool
canExtract stack cardIdx =
    let
        n =
            size stack

        st =
            stackType stack
    in
    if st == Set then
        n >= 4

    else if st /= PureRun && st /= RedBlackRun then
        False

    else if n >= 4 && (cardIdx == 0 || cardIdx == n - 1) then
        True

    else if cardIdx >= 3 && n - cardIdx - 1 >= 3 then
        True

    else
        False
