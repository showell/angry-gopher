// Card types and value/suit conversions. Mirrors elm-lynrummy's
// Card.elm module.
//
// The JSON shape is the domain shape — no intermediate wire type.
// This matches Elm's convention where Card.encode / Card.decoder
// operate directly on Card. Enabled by Suit being `type Suit int`
// so `encoding/json` handles it natively.

package lynrummy

import "fmt"

type Suit int

const (
	Club    Suit = 0
	Diamond Suit = 1
	Spade   Suit = 2
	Heart   Suit = 3
)

type CardColor int

const (
	Black CardColor = 0
	Red   CardColor = 1
)

func SuitColor(s Suit) CardColor {
	switch s {
	case Club, Spade:
		return Black
	default:
		return Red
	}
}

type Card struct {
	Value      int  `json:"value"`       // 1=Ace through 13=King
	Suit       Suit `json:"suit"`
	OriginDeck int  `json:"origin_deck"` // 0 or 1 (double deck)
}

func (c Card) Equals(other Card) bool {
	return c.Value == other.Value &&
		c.Suit == other.Suit &&
		c.OriginDeck == other.OriginDeck
}

func (c Card) IsDup(other Card) bool {
	// Same value and suit, possibly different deck.
	return c.Value == other.Value && c.Suit == other.Suit
}

func (c Card) Str() string {
	return valueStr(c.Value) + suitStr(c.Suit)
}

func valueStr(v int) string {
	switch v {
	case 1:
		return "A"
	case 10:
		return "T"
	case 11:
		return "J"
	case 12:
		return "Q"
	case 13:
		return "K"
	default:
		return fmt.Sprintf("%d", v)
	}
}

func suitStr(s Suit) string {
	switch s {
	case Club:
		return "C"
	case Diamond:
		return "D"
	case Spade:
		return "S"
	case Heart:
		return "H"
	default:
		return "?"
	}
}
