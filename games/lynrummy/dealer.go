// The Dealer sets up a LynRummy game: builds a shuffled double
// deck, pulls the initial board stacks, deals hands, and produces
// a GameSetup "photo" that any client can consume.
//
// The Dealer is autonomous — Angry Gopher can set up a game without
// needing an Angry Cat client. Any client (TypeScript, Python,
// curl) can read the resulting GameSetup and start playing.

package lynrummy

import "math/rand"

// --- Double deck ---

// BuildDoubleDeck creates a shuffled 104-card double deck.
func BuildDoubleDeck() []Card {
	cards := BuildDeterministicDoubleDeck()
	rand.Shuffle(len(cards), func(i, j int) {
		cards[i], cards[j] = cards[j], cards[i]
	})
	return cards
}

// BuildDeterministicDoubleDeck returns the 104-card double deck
// in a fixed canonical order (deck0 cards before deck1 cards, then
// by suit, then by value). Used by remainingDeckAfter so that
// session state is reproducible across /state calls — every replay
// sees the same draw order.
func BuildDeterministicDoubleDeck() []Card {
	var cards []Card
	for deck := 0; deck <= 1; deck++ {
		for suit := 0; suit <= 3; suit++ {
			for value := 1; value <= 13; value++ {
				cards = append(cards, Card{
					Value:      value,
					Suit:       Suit(suit),
					OriginDeck: deck,
				})
			}
		}
	}
	return cards
}

// --- Initial board stacks ---
//
// Hard-coded stacks pulled from deck 1 before dealing. The designer
// chose them to give players a starting board to work with.

type boardStackDef struct {
	row    int
	labels []string
}

var initialBoardDefs = []boardStackDef{
	{0, []string{"KS", "AS", "2S", "3S"}},
	{1, []string{"TD", "JD", "QD", "KD"}},
	{2, []string{"2H", "3H", "4H"}},
	{3, []string{"7S", "7D", "7C"}},
	{4, []string{"AC", "AD", "AH"}},
	{5, []string{"2C", "3D", "4C", "5H", "6S", "7H"}},
}

func boardLocation(row int) Location {
	col := (row*3 + 1) % 5
	return Location{
		Top:  20 + row*60,
		Left: 40 + col*30,
	}
}

// parseLabel converts "KS" → Card{Value:13, Suit:Spade, OriginDeck:0}.
func parseLabel(label string) Card {
	var value int
	switch label[0] {
	case 'A':
		value = 1
	case '2':
		value = 2
	case '3':
		value = 3
	case '4':
		value = 4
	case '5':
		value = 5
	case '6':
		value = 6
	case '7':
		value = 7
	case '8':
		value = 8
	case '9':
		value = 9
	case 'T':
		value = 10
	case 'J':
		value = 11
	case 'Q':
		value = 12
	case 'K':
		value = 13
	}

	var suit Suit
	switch label[1] {
	case 'C':
		suit = Club
	case 'D':
		suit = Diamond
	case 'S':
		suit = Spade
	case 'H':
		suit = Heart
	}

	return Card{Value: value, Suit: suit, OriginDeck: 0}
}

// pullCard searches for a card in the deck and removes it.
// Returns the remaining deck.
func pullCard(deck []Card, target Card) []Card {
	for i, c := range deck {
		if c.Equals(target) {
			return append(deck[:i], deck[i+1:]...)
		}
	}
	return deck // not found — shouldn't happen
}

// InitialBoard builds the canonical opening board directly (no
// deck threading). Mirrors elm-port-docs/src/LynRummy/Dealer.elm's
// initialBoard. Used during session replay where we want the
// starting board state without a shuffled deck.
func InitialBoard() []CardStack {
	var stacks []CardStack
	for _, def := range initialBoardDefs {
		var boardCards []BoardCard
		for _, label := range def.labels {
			boardCards = append(boardCards, BoardCard{Card: parseLabel(label), State: FirmlyOnBoard})
		}
		stacks = append(stacks, NewCardStack(boardCards, boardLocation(def.row)))
	}
	return stacks
}

// openingHandLabels is the canned 15-card hand used by the Elm
// client. Mirrors elm-port-docs/src/LynRummy/Dealer.elm's
// openingHandLabels exactly — same cards, same order.
var openingHandLabels = []string{
	"7H", "8C", "4S", "9D", "QS", "KH", "JH", "6H", "TS", "5D", "8H", "3C", "2D", "9C", "6C",
}

// OpeningHand builds the canned 15-card opening hand for player 0.
// Mirrors the Elm Dealer.openingHand. Uses DeckTwo so the 7H in
// the hand doesn't collide with the 7H in the initial board's
// 6-run (which uses DeckOne).
func OpeningHand() Hand {
	var cards []Card
	for _, label := range openingHandLabels {
		c := parseLabel(label)
		c.OriginDeck = 1
		cards = append(cards, c)
	}
	return EmptyHand().AddCards(cards, HandNormal)
}

// opening hand for player 1. Chosen from DeckOne cards that are
// not already used by the initial board. No collisions with
// player 0's hand (which is drawn from DeckTwo).
var openingHandLabelsP1 = []string{
	"4S", "5S", "9S", "6H", "9H", "TH", "4D", "5D",
	"6D", "8D", "3C", "5C", "6C", "JC", "KC",
}

// OpeningHands returns both canned opening hands in order
// [player0, player1]. The Elm client's canned opening hand
// mirrors player 0; player 1 exists for two-player replay and
// for cross-checking with the Python client.
func OpeningHands() []Hand {
	p0 := OpeningHand()
	var cards1 []Card
	for _, label := range openingHandLabelsP1 {
		c := parseLabel(label)
		c.OriginDeck = 0
		cards1 = append(cards1, c)
	}
	p1 := EmptyHand().AddCards(cards1, HandNormal)
	return []Hand{p0, p1}
}

// buildInitialBoard pulls the hard-coded stacks from the deck.
// Mutates the deck slice via pullCard.
func buildInitialBoard(deck *[]Card) []CardStack {
	var stacks []CardStack

	for _, def := range initialBoardDefs {
		var boardCards []BoardCard
		for _, label := range def.labels {
			target := parseLabel(label)
			*deck = pullCard(*deck, target)
			boardCards = append(boardCards, BoardCard{Card: target, State: FirmlyOnBoard})
		}
		stacks = append(stacks, NewCardStack(boardCards, boardLocation(def.row)))
	}

	return stacks
}

// --- Deal ---

// DealFullGame takes a shuffled deck, sets up the board, deals
// hands, and returns the GameSetup "photo" ready to send over
// the wire.
func DealFullGame(shuffledCards []Card) GameSetup {
	deck := make([]Card, len(shuffledCards))
	copy(deck, shuffledCards)

	board := buildInitialBoard(&deck)

	// Deal 15 cards from the front to each player.
	hand1 := deck[:15]
	deck = deck[15:]
	hand2 := deck[:15]
	deck = deck[15:]

	return GameSetup{
		Board: board,
		Hands: [2][]Card{hand1, hand2},
		Deck:  deck,
	}
}
