// Wire format deserialization for LynRummy game events.
//
// Angry Cat sends game events as JSON through the Gopher game bus.
// This file converts that JSON into referee types so the host can
// ask the referee for a ruling.
//
// The host calls ParseMoveEvent to extract the board event from
// a raw JSON payload. If the payload is not a player action (e.g.,
// it's an advance-turn or undo), ParseMoveEvent returns nil — the
// host relays those without consulting the referee.

package lynrummy

import "encoding/json"

// --- Wire types (match Angry Cat's JSON shapes) ---

// WireCard matches JsonCard from core/card.ts.
type WireCard struct {
	Value      int `json:"value"`
	Suit       int `json:"suit"`
	OriginDeck int `json:"origin_deck"`
}

// WireBoardCard matches JsonBoardCard from core/card_stack.ts.
type WireBoardCard struct {
	Card  WireCard `json:"card"`
	State int      `json:"state"`
}

// WireCardStack matches JsonCardStack from core/card_stack.ts.
type WireCardStack struct {
	BoardCards []WireBoardCard `json:"board_cards"`
	Loc        WireLocation    `json:"loc"`
}

// WireLocation matches BoardLocation from core/card_stack.ts.
type WireLocation struct {
	Top  int `json:"top"`
	Left int `json:"left"`
}

// WireBoardEvent matches JsonBoardEvent from game/game.ts.
type WireBoardEvent struct {
	StacksToRemove []WireCardStack `json:"stacks_to_remove"`
	StacksToAdd    []WireCardStack `json:"stacks_to_add"`
}

// WireHandCard matches JsonHandCard from core/card_stack.ts.
type WireHandCard struct {
	Card  WireCard `json:"card"`
	State int      `json:"state"`
}

// WirePlayerAction matches JsonPlayerAction from game/game.ts.
type WirePlayerAction struct {
	BoardEvent       WireBoardEvent `json:"board_event"`
	HandCardsRelease []WireHandCard `json:"hand_cards_to_release"`
}

// WireGameEvent matches JsonGameEvent from game/game.ts.
// Type values: 0=ADVANCE_TURN, 1=MAYBE_COMPLETE_TURN,
// 2=PLAYER_ACTION, 3=UNDO.
type WireGameEvent struct {
	Type         int               `json:"type"`
	PlayerAction *WirePlayerAction `json:"player_action"`
}

// WireEventRow matches EventRow from game/game.ts.
// This is the top-level payload Angry Cat sends to the host.
type WireEventRow struct {
	GameEvent WireGameEvent `json:"json_game_event"`
	Addr      string        `json:"addr"`
}

const (
	EventTypeAdvanceTurn      = 0
	EventTypeMaybeCompleteTurn = 1
	EventTypePlayerAction     = 2
	EventTypeUndo             = 3
)

// --- Conversion: wire types → referee types ---

func wireCardToCard(wc WireCard) Card {
	return Card{
		Value:      wc.Value,
		Suit:       Suit(wc.Suit),
		OriginDeck: wc.OriginDeck,
	}
}

func wireStackToCardStack(ws WireCardStack) CardStack {
	cards := make([]BoardCard, len(ws.BoardCards))
	for i, wbc := range ws.BoardCards {
		cards[i] = BoardCard{
			Card:  wireCardToCard(wbc.Card),
			State: wbc.State,
		}
	}
	return NewCardStack(cards, Location{
		Top:  ws.Loc.Top,
		Left: ws.Loc.Left,
	})
}

func wireStacksToCardStacks(ws []WireCardStack) []CardStack {
	stacks := make([]CardStack, len(ws))
	for i, w := range ws {
		stacks[i] = wireStackToCardStack(w)
	}
	return stacks
}

// ParseMoveEvent extracts a Move from a raw JSON game event payload.
// Returns nil if the event is not a player action (advance-turn,
// undo, etc.) — the host should relay those without asking the
// referee.
//
// The caller must supply boardBefore — the current board state
// that the host tracks.
func ParseMoveEvent(payload json.RawMessage, boardBefore []CardStack) (*Move, error) {
	// First try to parse as an EventRow (has json_game_event + addr).
	var row WireEventRow
	if err := json.Unmarshal(payload, &row); err != nil {
		return nil, err
	}

	// If json_game_event is missing, this might be a deck event
	// or other non-game payload. Not our concern.
	if row.GameEvent.Type != EventTypePlayerAction {
		return nil, nil
	}

	if row.GameEvent.PlayerAction == nil {
		return nil, nil
	}

	action := row.GameEvent.PlayerAction
	be := action.BoardEvent

	var handCards []Card
	for _, whc := range action.HandCardsRelease {
		handCards = append(handCards, wireCardToCard(whc.Card))
	}

	move := &Move{
		BoardBefore:     boardBefore,
		StacksToRemove:  wireStacksToCardStacks(be.StacksToRemove),
		StacksToAdd:     wireStacksToCardStacks(be.StacksToAdd),
		HandCardsPlayed: handCards,
	}
	return move, nil
}
