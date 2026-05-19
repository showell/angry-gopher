module Lib.CardStack exposing
    ( BoardCard
    , BoardCardState(..)
    , BoardLocation
    , CardStack
    , HandCard
    , HandCardState(..)
    , agedFromPriorTurn
    , cardWidth
    , findStack
    , fromHandCard
    , fromShorthand
    , isHandCardSameCard
    , isIncomplete
    , isStacksEqual
    , leftMerge
    , rightMerge
    , isolate
    , size
    , split
    , stackDisplayWidth
    , stackPitch
    )

{-| CardStack domain types and operations. Ported from
`angry-cat/src/lyn_rummy/core/card_stack.ts`.

Intentional Elm divergences:

  - `CardStack.stackType` is a function (derived on demand), not
    a stored field. Insight #5 — don't carry state that's a pure
    function of other state.
  - `isStacksEqual` compares full card identity (including
    `originDeck`) so inventory accounting is conservative on
    double-deck boards. BoardCard `state` (recency) is still
    ignored — it's a turn-accounting concern, not identity.
    See the function docstring for the rationale.
  - `clone` is N/A in Elm (values are inherently immutable).
  - `toJSON` / `fromJson` deferred (boundary plumbing).
  - `pullFromDeck` deferred (requires a pure model of the deck
    rather than TS's mutable `DeckRef` interface).
  - `CARD_WIDTH` lives in this module by design — position is
    domain data (every `CardStack` carries a `loc`), so
    split/merge producing correct positions is domain work.
    (Resolved 2026-04-14.)

-}

import Lib.Rules.Card
    exposing
        ( Card
        , OriginDeck
        , cardFromLabel
        )
import Lib.Rules.StackType
    exposing
        ( CardStackType(..)
        , getStackType
        )



-- STATE ENUMS


type HandCardState
    = HandNormal
    | FreshlyDrawn


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
(Resolved 2026-04-14.)
-}
cardWidth : Int
cardWidth =
    27


{-| Per-card horizontal pitch when cards sit side-by-side in
a stack. Card body plus padding + border + margin.
-}
stackPitch : Int
stackPitch =
    cardWidth + 6


{-| Visible width of a stack in pixels: `n * stackPitch`.
Used for placing wings and for drag-hit math.
-}
stackDisplayWidth : CardStack -> Int
stackDisplayWidth s =
    size s * stackPitch



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


{-| Strict stack identity: same `loc` (integer-exact) AND same
cards in the same order. `BoardCard.state` (recency) is
intentionally ignored — that's turn-accounting, not identity.

Location-first and exact: `loc` is checked before cards, both
for short-circuit speed and because no two stacks can share a
location on a legal board (overlap is forbidden by the
referee). Card ordering is preserved and compared directly —
AH-AD-AS and AD-AH-AS are NOT the same stack. The system
requires one canonical representation of every stack on the
wire; treating re-orderings as equal invites quiet
disagreement between actors.

Why deck identity matters: on a double-deck board there are
two 5♥'s — 5♥(d0) and 5♥(d1). They look identical to the
player, but inventory accounting must distinguish them. If
equality were deck-blind, a client could claim to have
removed 5♥(d0) from the board while adding 5♥(d1) it never
held — and the referee couldn't tell. Full-identity equality
keeps `stacks_to_remove` honest.

-}
isStacksEqual : CardStack -> CardStack -> Bool
isStacksEqual a b =
    isLocsEqual a.loc b.loc && isCardsEqualInOrder a.boardCards b.boardCards


{-| Find the stack in `board` that matches `ref` via `isStacksEqual`.
The wire-layer resolver — client sends a CardStack reference,
server finds the current matching board stack at apply time.
Returns Nothing if no stack matches.
-}
findStack : CardStack -> List CardStack -> Maybe CardStack
findStack ref board =
    board
        |> List.filter (isStacksEqual ref)
        |> List.head


{-| True when two BoardCard lists carry the same cards in the
same order. `state` flags are ignored (turn-accounting, not
identity).
-}
isCardsEqualInOrder : List BoardCard -> List BoardCard -> Bool
isCardsEqualInOrder xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: xrest, y :: yrest ) ->
            x.card == y.card && isCardsEqualInOrder xrest yrest

        _ ->
            False


isLocsEqual : BoardLocation -> BoardLocation -> Bool
isLocsEqual a b =
    a.top == b.top && a.left == b.left


{-| `HandCard` equality that ignores `state`. Same shape and
rationale as `isBoardCardSameCard`.
-}
isHandCardSameCard : HandCard -> HandCard -> Bool
isHandCardSameCard a b =
    a.card == b.card


isIncomplete : CardStack -> Bool
isIncomplete s =
    stackType s == Incomplete


isProblematic : CardStack -> Bool
isProblematic s =
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


{-| Slice `s` after the first `leftCount` cards and assign each piece
its post-split screen position. The physics branch is chosen
deterministically from `leftCount` alone: when `leftCount` sits in the
first half, the left piece is the "small" one (small nudge, residue
hops); otherwise the right piece is.

`leftCount` must be in `[1, size s - 1]`. Size-1 stacks return
unchanged (caller responsibility, preserves TS-port total-function
semantics).
-}
split : Int -> CardStack -> List CardStack
split leftCount s =
    if size s <= 1 then
        [ s ]

    else if leftCount <= size s // 2 then
        leftSplit leftCount s

    else
        rightSplit leftCount s


{-| Split with the left piece as the "primary" (stays near origin).
Offsets from original loc: left piece top-=4 left-=2; right piece top+=0 left+=leftCount\*stackPitch+8.
Example: stack at (top=20,left=70), leftCount=2 → left at (16,68), right at (20,136).
-}
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


{-| Split with the right piece as the "primary" (stays near origin).
Offsets from original loc: left piece top+=0 left-=8; right piece top-=4 left+=leftCount\*stackPitch+4.
Example: stack at (top=20,left=70), leftCount=2 → left at (20,62), right at (16,140).
-}
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


{-| Isolate the card at `cardIndex` from the rest of the
stack. The left piece slides 2px left, the right piece 2px
right; the isolated card stays at its original screen
position. If the held card is at either end, the corresponding
side piece is omitted.

Returns the up-to-three `pieces` for the caller to splice
into the board, plus a direct reference to the `singleton`
(the same record that appears in `pieces`) so callers can
grab it as a drag handle without re-deriving its position.
Singleton's `boardCards` is `[s]` for a 1-card input; in
that degenerate case `pieces` is `[ s ]` and `singleton` is
the original stack.
-}
isolate : Int -> CardStack -> { pieces : List CardStack, singleton : CardStack }
isolate cardIndex s =
    if size s <= 1 then
        { pieces = [ s ], singleton = s }

    else
        let
            beforeCards =
                List.take cardIndex s.boardCards

            afterCards =
                List.drop (cardIndex + 1) s.boardCards

            singleton =
                { boardCards = List.drop cardIndex s.boardCards |> List.take 1
                , loc = { top = s.loc.top, left = s.loc.left + cardIndex * stackPitch }
                }

            leftPiece =
                if List.isEmpty beforeCards then
                    []

                else
                    [ { boardCards = beforeCards
                      , loc = { top = s.loc.top, left = s.loc.left - 2 }
                      }
                    ]

            afterPiece =
                if List.isEmpty afterCards then
                    []

                else
                    [ { boardCards = afterCards
                      , loc = { top = s.loc.top, left = singleton.loc.left + stackPitch + 2 }
                      }
                    ]
        in
        { pieces = leftPiece ++ [ singleton ] ++ afterPiece
        , singleton = singleton
        }



-- MERGE


{-| Attempt a merge. Returns `Nothing` if:

  - The two stacks are `isStacksEqual` (prevents merging a stack
    with itself — also prevents merging two identical piles,
    which can never produce a valid result).
  - The combined result is `isProblematic` (Bogus or Dup).

Otherwise returns `Just` the merged stack positioned at `loc`.

-}
maybeMerge : CardStack -> CardStack -> BoardLocation -> Maybe CardStack
maybeMerge s1 s2 loc =
    if isStacksEqual s1 s2 then
        Nothing

    else
        let
            merged =
                { boardCards = s1.boardCards ++ s2.boardCards
                , loc = loc
                }
        in
        if isProblematic merged then
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
-- JSON: WIRE FORMAT
--
-- Mirrors the TS shapes:
--   JsonHandCard  = { card: JsonCard, state: <int 0-2> }
--   JsonBoardCard = { card: JsonCard, state: <int 0-2> }
--   BoardLocation = { top: number, left: number }
--   JsonCardStack = { board_cards: JsonBoardCard[], loc: BoardLocation }
