package views

import (
	"encoding/json"
	"fmt"
	"strings"
)

// Wire-format conversion from the JSON board shape (the
// `mined_seeds.json` / Elm-encoded shape) to the multi-line
// board DSL parsed by `Game.BoardDsl.parseBoard` on the Elm
// side. Symmetric grammar to `.dsl` conformance fixtures and
// the live action-log wire — unicode suits, deck-2 suffix
// `'`, one stack per line:
//
//	at (top, left): K♦ K♦' K♥' K♠
//
// Initial-state cards are always FirmlyOnBoard, so the
// freshness markers (`*` / `**`) are unused here.

// boardDslValue is the JSON wire shape Elm encodes (and the
// mined_seeds.json catalog uses): each stack has a list of
// {card: {value, suit, origin_deck}, state} entries plus a loc.
type boardDslJSON struct {
	BoardCards []struct {
		Card struct {
			Value      int `json:"value"`
			Suit       int `json:"suit"`
			OriginDeck int `json:"origin_deck"`
		} `json:"card"`
		// State is intentionally ignored — initial-state boards
		// are always FirmlyOnBoard, so the round-trip drops it.
	} `json:"board_cards"`
	Loc struct {
		Top  int `json:"top"`
		Left int `json:"left"`
	} `json:"loc"`
}

// boardJSONToDSL converts a JSON-encoded board (array of
// stacks) to the DSL string the Elm client parses. Returns an
// error if the JSON shape is malformed or any value is out of
// range.
func boardJSONToDSL(raw json.RawMessage) (string, error) {
	var stacks []boardDslJSON
	if err := json.Unmarshal(raw, &stacks); err != nil {
		return "", fmt.Errorf("decode board JSON: %w", err)
	}

	var lines []string
	for i, s := range stacks {
		line, err := formatStackLine(s)
		if err != nil {
			return "", fmt.Errorf("stack %d: %w", i, err)
		}
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n"), nil
}

func formatStackLine(s boardDslJSON) (string, error) {
	cards := make([]string, 0, len(s.BoardCards))
	for _, bc := range s.BoardCards {
		token, err := formatCardToken(bc.Card.Value, bc.Card.Suit, bc.Card.OriginDeck)
		if err != nil {
			return "", err
		}
		cards = append(cards, token)
	}
	return fmt.Sprintf("at (%d, %d): %s", s.Loc.Top, s.Loc.Left, strings.Join(cards, " ")), nil
}

// formatCardToken mirrors Elm's `Card.cardStr` — value letter +
// unicode suit glyph + optional `'` for deck two.
func formatCardToken(value, suit, originDeck int) (string, error) {
	valueChar, err := valueLetter(value)
	if err != nil {
		return "", err
	}
	suitChar, err := suitGlyph(suit)
	if err != nil {
		return "", err
	}
	deckSuffix := ""
	switch originDeck {
	case 0:
		// DeckOne — no suffix.
	case 1:
		deckSuffix = "'"
	default:
		return "", fmt.Errorf("unknown origin_deck: %d", originDeck)
	}
	return valueChar + suitChar + deckSuffix, nil
}

func valueLetter(v int) (string, error) {
	// 1-13 → A,2,3,4,5,6,7,8,9,T,J,Q,K. Same letters Elm uses
	// in valueStr.
	if v < 1 || v > 13 {
		return "", fmt.Errorf("value out of range 1-13: %d", v)
	}
	return "A23456789TJQK"[v-1 : v], nil
}

func suitGlyph(s int) (string, error) {
	// Suit constants mirror Elm/TS: 0=Club, 1=Diamond, 2=Spade,
	// 3=Heart.
	switch s {
	case 0:
		return "♣", nil
	case 1:
		return "♦", nil
	case 2:
		return "♠", nil
	case 3:
		return "♥", nil
	default:
		return "", fmt.Errorf("unknown suit: %d", s)
	}
}
