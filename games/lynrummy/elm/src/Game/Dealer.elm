module Game.Dealer exposing
    ( GameSetup
    , dealFullGame
    , initialBoard
    , openingHand
    )

{-| Dealer: produces the opening board, the canned hand, and
(new) a full autonomous `GameSetup` from a PRNG seed. Mirror of
`games/lynrummy/dealer.go` — the Elm port gives the client
enough to build its own initial state without the server.

Two bootstrap paths:

  - `initialBoard` + `openingHand` — hardcoded fixtures used
    for drag-testing milestones and for replay initial state.
    No seed. No second hand.
  - `dealFullGame seed` — shuffles a 104-card double deck,
    pulls the six hardcoded opening stacks from DeckOne, deals
    15 cards to each of two players, returns the rest as the
    draw deck. This is what the offline-mode client calls when
    there's no `/state` to hydrate from.

Elm ↔ Go parity note: the server shuffles with `math/rand`;
Elm shuffles with Mulberry32 (`Game.Random`). Same seed →
different shuffles. That means the offline-mode deal differs
from the server's deal for the same seed. Acceptable because
the client is self-authoritative in offline mode; when online,
the client hydrates from the server's /state and ignores any
local seed.

-}

import Game.Card as Card exposing (Card, OriginDeck(..))
import Game.CardStack as CardStack exposing (BoardCardState(..), BoardLocation, CardStack)
import Game.Hand as Hand exposing (Hand)
import Game.Random as Random



-- BOARD


{-| The six-stack hardcoded opening board.
-}
initialBoard : List CardStack
initialBoard =
    List.indexedMap stackFromRow openingShorthands
        |> List.filterMap identity


openingShorthands : List String
openingShorthands =
    [ "KS,AS,2S,3S"
    , "TD,JD,QD,KD"
    , "2H,3H,4H"
    , "7S,7D,7C"
    , "AC,AD,AH"
    , "2C,3D,4C,5H,6S,7H"
    ]


stackFromRow : Int -> String -> Maybe CardStack
stackFromRow row sig =
    CardStack.fromShorthand sig DeckOne (rowLoc row)


rowLoc : Int -> BoardLocation
rowLoc row =
    let
        col =
            modBy 5 (row * 3 + 1)
    in
    { top = 20 + row * 60
    , left = 40 + col * 30
    }



-- HAND


{-| Canned 15-card hand for the hand-to-board drag milestone.
Includes 7H, 8C, 4S (our known drag testers — all three have
legal merges against the initial board). Other 12 are a grab
bag: 9D and QS also extend existing runs; the rest are loose
cards with no merges to exercise the "land as singleton"
path.
-}
openingHand : Hand
openingHand =
    let
        -- Hand uses DeckTwo so 7H in the hand doesn't collide with
        -- the 7H in the initial board's 6-run (DeckOne). Both-deck
        -- sources are idiomatic in double-deck LynRummy.
        cards =
            List.filterMap (\label -> Card.cardFromLabel label DeckTwo) openingHandLabels
    in
    Hand.addCards cards CardStack.HandNormal Hand.empty


openingHandLabels : List String
openingHandLabels =
    [ "7H"
    , "8C"
    , "4S"
    , "9D"
    , "QS"
    , "KH"
    , "JH"
    , "6H"
    , "TS"
    , "5D"
    , "8H"
    , "3C"
    , "2D"
    , "9C"
    , "6C"
    ]



-- FULL DEAL (seed-driven)


{-| Bundle returned by `dealFullGame`: initial board, both
players' 15-card hands, and the remaining draw deck.
-}
type alias GameSetup =
    { board : List CardStack
    , hands : List Hand
    , deck : List Card
    }


{-| Build a complete, playable initial game state from a seed.
Ported from `games/lynrummy/dealer.go:DealFullGame`.

Steps (matches the Go counterpart's shape):

1.  Shuffle a 104-card double deck via `Card.buildFullDoubleDeck`
    (Mulberry32 under the seed).
2.  Pull each card named in the six `openingShorthands` stacks
    from the shuffled deck, building the initial board at
    `rowLoc`-derived locations. Cards are pulled with
    `originDeck = DeckOne` so they match the hardcoded labels;
    the shuffled deck carries both deck identities, so the
    pull is a by-value/suit/deck equality match.
3.  Deal 15 cards from the front of the remaining deck to
    player 0, then 15 more to player 1.
4.  Return { board, hands = [P0, P1], deck = leftover }.

-}
dealFullGame : Random.Seed -> GameSetup
dealFullGame seed =
    let
        ( shuffled, _ ) =
            Card.buildFullDoubleDeck seed

        ( board, afterBoard ) =
            buildBoardFromDeck shuffled

        ( hand0Cards, afterHand0 ) =
            takeN 15 afterBoard

        ( hand1Cards, afterHand1 ) =
            takeN 15 afterHand0

        hand0 =
            Hand.addCards hand0Cards CardStack.HandNormal Hand.empty

        hand1 =
            Hand.addCards hand1Cards CardStack.HandNormal Hand.empty
    in
    { board = board
    , hands = [ hand0, hand1 ]
    , deck = afterHand1
    }


{-| Pull each named opening-board card from the deck (all
DeckOne), assemble the six initial stacks at their row
locations, and return (board, remainingDeck).

If the deck is missing a card that the openingShorthands
reference (shouldn't happen with a correct 104-card double
deck), that stack is skipped — caller ends up with fewer
stacks but the game can still start.
-}
buildBoardFromDeck : List Card -> ( List CardStack, List Card )
buildBoardFromDeck initialDeck =
    let
        indexedShorthands =
            List.indexedMap Tuple.pair openingShorthands
    in
    List.foldl pullOneStack ( [], initialDeck ) indexedShorthands


pullOneStack : ( Int, String ) -> ( List CardStack, List Card ) -> ( List CardStack, List Card )
pullOneStack ( row, shorthand ) ( stacksSoFar, deck ) =
    let
        labels =
            String.split "," shorthand
                |> List.map String.trim

        ( boardCards, afterPull ) =
            pullAllLabels labels deck
    in
    if List.length boardCards == List.length labels then
        let
            stack =
                { boardCards = boardCards, loc = rowLoc row }
        in
        ( stacksSoFar ++ [ stack ], afterPull )

    else
        ( stacksSoFar, deck )


pullAllLabels : List String -> List Card -> ( List { card : Card, state : BoardCardState }, List Card )
pullAllLabels labels deck =
    List.foldl pullOneLabel ( [], deck ) labels


pullOneLabel : String -> ( List { card : Card, state : BoardCardState }, List Card ) -> ( List { card : Card, state : BoardCardState }, List Card )
pullOneLabel label ( accBCs, deck ) =
    case Card.cardFromLabel label DeckOne of
        Just target ->
            case pullCard target deck of
                Just newDeck ->
                    ( accBCs ++ [ { card = target, state = FirmlyOnBoard } ], newDeck )

                Nothing ->
                    ( accBCs, deck )

        Nothing ->
            ( accBCs, deck )


pullCard : Card -> List Card -> Maybe (List Card)
pullCard target deck =
    case findIndex (cardEq target) deck of
        Just i ->
            Just (List.take i deck ++ List.drop (i + 1) deck)

        Nothing ->
            Nothing


cardEq : Card -> Card -> Bool
cardEq a b =
    a.value == b.value && a.suit == b.suit && a.originDeck == b.originDeck


findIndex : (a -> Bool) -> List a -> Maybe Int
findIndex pred xs =
    findIndexHelp pred xs 0


findIndexHelp : (a -> Bool) -> List a -> Int -> Maybe Int
findIndexHelp pred xs i =
    case xs of
        [] ->
            Nothing

        x :: rest ->
            if pred x then
                Just i

            else
                findIndexHelp pred rest (i + 1)


takeN : Int -> List a -> ( List a, List a )
takeN n xs =
    ( List.take n xs, List.drop n xs )
