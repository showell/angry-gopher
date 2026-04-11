package lynrummy

import (
	"encoding/json"
	"testing"
)

// Simulate what Angry Cat sends over the wire when a player
// extends a run with a card from their hand.

func TestParseAndValidateExtendRun(t *testing.T) {
	// Board before: one 3-card pure run (5H 6H 7H).
	boardBefore := []CardStack{
		stack(at(10, 10), bc(5, Heart, 0), bc(6, Heart, 0), bc(7, Heart, 0)),
	}

	// Angry Cat sends this JSON when the player adds 8H to the run.
	payload := json.RawMessage(`{
		"json_game_event": {
			"type": 2,
			"player_action": {
				"board_event": {
					"stacks_to_remove": [{
						"board_cards": [
							{"card": {"value": 5, "suit": 3, "origin_deck": 0}, "state": 0},
							{"card": {"value": 6, "suit": 3, "origin_deck": 0}, "state": 0},
							{"card": {"value": 7, "suit": 3, "origin_deck": 0}, "state": 0}
						],
						"loc": {"top": 10, "left": 10}
					}],
					"stacks_to_add": [{
						"board_cards": [
							{"card": {"value": 5, "suit": 3, "origin_deck": 0}, "state": 0},
							{"card": {"value": 6, "suit": 3, "origin_deck": 0}, "state": 0},
							{"card": {"value": 7, "suit": 3, "origin_deck": 0}, "state": 0},
							{"card": {"value": 8, "suit": 3, "origin_deck": 0}, "state": 1}
						],
						"loc": {"top": 10, "left": 10}
					}]
				},
				"hand_cards_to_release": [
					{"card": {"value": 8, "suit": 3, "origin_deck": 0}, "state": 0}
				]
			}
		},
		"addr": "1"
	}`)

	move, err := ParseMoveEvent(payload, boardBefore)
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if move == nil {
		t.Fatal("expected a move, got nil")
	}

	// Ask the referee.
	refErr := ValidateGameMove(*move, bounds)
	if refErr != nil {
		t.Fatalf("referee rejected valid move: %v", refErr)
	}
}

// A bogus stack should fail semantics.

func TestParseAndRejectBogusStack(t *testing.T) {
	payload := json.RawMessage(`{
		"json_game_event": {
			"type": 2,
			"player_action": {
				"board_event": {
					"stacks_to_remove": [],
					"stacks_to_add": [{
						"board_cards": [
							{"card": {"value": 1, "suit": 3, "origin_deck": 0}, "state": 1},
							{"card": {"value": 5, "suit": 0, "origin_deck": 0}, "state": 1},
							{"card": {"value": 13, "suit": 1, "origin_deck": 0}, "state": 1}
						],
						"loc": {"top": 10, "left": 10}
					}]
				},
				"hand_cards_to_release": [
					{"card": {"value": 1, "suit": 3, "origin_deck": 0}, "state": 0},
					{"card": {"value": 5, "suit": 0, "origin_deck": 0}, "state": 0},
					{"card": {"value": 13, "suit": 1, "origin_deck": 0}, "state": 0}
				]
			}
		},
		"addr": "1"
	}`)

	move, err := ParseMoveEvent(payload, nil)
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if move == nil {
		t.Fatal("expected a move")
	}

	refErr := ValidateGameMove(*move, bounds)
	if refErr == nil {
		t.Fatal("expected referee to reject bogus stack")
	}
	if refErr.Stage != "semantics" {
		t.Fatalf("expected semantics error, got %s: %s", refErr.Stage, refErr.Message)
	}
}

// Non-player-action events (advance turn, undo) return nil — host relays them.

func TestNonPlayerActionReturnsNil(t *testing.T) {
	// Type 0 = ADVANCE_TURN
	payload := json.RawMessage(`{
		"json_game_event": {"type": 0},
		"addr": "1"
	}`)

	move, err := ParseMoveEvent(payload, nil)
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if move != nil {
		t.Fatal("expected nil for non-player-action event")
	}
}

// Deck events (no json_game_event.type == player_action) also return nil.

func TestDeckEventReturnsNil(t *testing.T) {
	payload := json.RawMessage(`{
		"deck": [{"value": 1, "suit": 0, "origin_deck": 0}]
	}`)

	move, err := ParseMoveEvent(payload, nil)
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if move != nil {
		t.Fatal("expected nil for deck event")
	}
}

// A rearrangement (split) with no hand cards.

func TestParseAndValidateSplit(t *testing.T) {
	boardBefore := []CardStack{
		stack(at(10, 10),
			bc(3, Diamond, 0), bc(4, Diamond, 0), bc(5, Diamond, 0),
			bc(6, Diamond, 0), bc(7, Diamond, 0), bc(8, Diamond, 0)),
	}

	payload := json.RawMessage(`{
		"json_game_event": {
			"type": 2,
			"player_action": {
				"board_event": {
					"stacks_to_remove": [{
						"board_cards": [
							{"card": {"value": 3, "suit": 1, "origin_deck": 0}, "state": 0},
							{"card": {"value": 4, "suit": 1, "origin_deck": 0}, "state": 0},
							{"card": {"value": 5, "suit": 1, "origin_deck": 0}, "state": 0},
							{"card": {"value": 6, "suit": 1, "origin_deck": 0}, "state": 0},
							{"card": {"value": 7, "suit": 1, "origin_deck": 0}, "state": 0},
							{"card": {"value": 8, "suit": 1, "origin_deck": 0}, "state": 0}
						],
						"loc": {"top": 10, "left": 10}
					}],
					"stacks_to_add": [{
						"board_cards": [
							{"card": {"value": 3, "suit": 1, "origin_deck": 0}, "state": 0},
							{"card": {"value": 4, "suit": 1, "origin_deck": 0}, "state": 0},
							{"card": {"value": 5, "suit": 1, "origin_deck": 0}, "state": 0}
						],
						"loc": {"top": 10, "left": 10}
					}, {
						"board_cards": [
							{"card": {"value": 6, "suit": 1, "origin_deck": 0}, "state": 0},
							{"card": {"value": 7, "suit": 1, "origin_deck": 0}, "state": 0},
							{"card": {"value": 8, "suit": 1, "origin_deck": 0}, "state": 0}
						],
						"loc": {"top": 10, "left": 200}
					}]
				},
				"hand_cards_to_release": []
			}
		},
		"addr": "1"
	}`)

	move, err := ParseMoveEvent(payload, boardBefore)
	if err != nil {
		t.Fatalf("parse error: %v", err)
	}
	if move == nil {
		t.Fatal("expected a move")
	}

	refErr := ValidateGameMove(*move, bounds)
	if refErr != nil {
		t.Fatalf("referee rejected valid split: %v", refErr)
	}
}
