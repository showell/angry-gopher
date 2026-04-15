// Cross-domain wire types and event replay. These span Card +
// CardStack + Move, so they don't live on any single domain type.
//
// Exported: GameSetup (the dealer's "photo" event). Everything else
// is internal JSON-shape plumbing — domain consumers call
// CheckEvent / ParseMoveEvent / ReconstructBoard and never see the
// intermediate types.

package lynrummy

import (
	"encoding/json"
	"fmt"
)

// --- Public setup type ---

// GameSetup matches the TS `GameSetup` shape and is the first event
// of every game: the board, both players' hands, and the remaining
// deck.
type GameSetup struct {
	Board []CardStack `json:"board"`
	Hands [2][]Card   `json:"hands"`
	Deck  []Card      `json:"deck"`
}

// --- Event types (internal) ---

const (
	eventTypeAdvanceTurn       = 0
	eventTypeMaybeCompleteTurn = 1
	eventTypePlayerAction      = 2
	eventTypeUndo              = 3
)

type wireBoardEvent struct {
	StacksToRemove []CardStack `json:"stacks_to_remove"`
	StacksToAdd    []CardStack `json:"stacks_to_add"`
}

type wirePlayerAction struct {
	BoardEvent       wireBoardEvent `json:"board_event"`
	HandCardsRelease []HandCard     `json:"hand_cards_to_release"`
}

type wireGameEvent struct {
	Type         int               `json:"type"`
	PlayerAction *wirePlayerAction `json:"player_action"`
}

type wireEventRow struct {
	GameEvent wireGameEvent `json:"json_game_event"`
	Addr      string        `json:"addr"`
}

// --- Event processing ---

// ParseMoveEvent extracts a Move from a raw JSON game event payload.
// Returns nil if the event is not a player action (advance-turn,
// undo, etc.) — the host should relay those without asking the
// referee.
//
// The caller must supply boardBefore — the current board state
// that the host tracks.
func ParseMoveEvent(payload json.RawMessage, boardBefore []CardStack) (*Move, error) {
	var row wireEventRow
	if err := json.Unmarshal(payload, &row); err != nil {
		return nil, err
	}

	if row.GameEvent.Type != eventTypePlayerAction {
		return nil, nil
	}
	if row.GameEvent.PlayerAction == nil {
		return nil, nil
	}

	action := row.GameEvent.PlayerAction
	be := action.BoardEvent

	var handCards []Card
	for _, hc := range action.HandCardsRelease {
		handCards = append(handCards, hc.Card)
	}

	return &Move{
		BoardBefore:     boardBefore,
		StacksToRemove:  be.StacksToRemove,
		StacksToAdd:     be.StacksToAdd,
		HandCardsPlayed: handCards,
	}, nil
}

// CheckEvent is the single entry point the host calls. Give it
// all prior event payloads and the new payload. It reconstructs
// the board, parses the move, and asks the referee. Returns nil
// if the event is valid or not a player action.
func CheckEvent(priorPayloads []json.RawMessage, newPayload json.RawMessage) *RefereeError {
	if len(priorPayloads) == 0 {
		return nil
	}

	board, err := ReconstructBoard(priorPayloads)
	if err != nil {
		return nil
	}

	move, err := ParseMoveEvent(newPayload, board)
	if err != nil {
		return nil
	}
	if move == nil {
		return nil
	}

	bounds := BoardBounds{MaxWidth: 800, MaxHeight: 600, Margin: 5}
	return ValidateGameMove(*move, bounds)
}

// ReconstructBoard rebuilds the current board state from a sequence
// of raw JSON event payloads. The first payload must be a
// game_setup event. Subsequent payloads are game events — player
// actions are applied; other event types are skipped.
func ReconstructBoard(payloads []json.RawMessage) ([]CardStack, error) {
	if len(payloads) == 0 {
		return nil, fmt.Errorf("no events")
	}

	var firstEvent struct {
		GameSetup *GameSetup `json:"game_setup"`
	}
	if err := json.Unmarshal(payloads[0], &firstEvent); err != nil {
		return nil, fmt.Errorf("failed to parse setup event: %w", err)
	}
	if firstEvent.GameSetup == nil {
		return nil, fmt.Errorf("first event is not a game_setup")
	}

	board := append([]CardStack{}, firstEvent.GameSetup.Board...)

	for _, payload := range payloads[1:] {
		var row wireEventRow
		if err := json.Unmarshal(payload, &row); err != nil {
			continue
		}
		if row.GameEvent.Type != eventTypePlayerAction {
			continue
		}
		if row.GameEvent.PlayerAction == nil {
			continue
		}

		be := row.GameEvent.PlayerAction.BoardEvent
		toRemove := append([]CardStack{}, be.StacksToRemove...)

		var remaining []CardStack
		for _, s := range board {
			idx := findMatchingStack(toRemove, s)
			if idx >= 0 {
				toRemove = append(toRemove[:idx], toRemove[idx+1:]...)
			} else {
				remaining = append(remaining, s)
			}
		}

		board = append(remaining, be.StacksToAdd...)
	}

	return board, nil
}
