// Cross-language conformance fixture runner.
//
// Walks every JSON fixture under `conformance/`, dispatches on
// `operation`, and asserts the referee's result against `expected`.
// A matching loader lives in elm-lynrummy's test suite; both must
// stay byte-equivalent.
//
// Fixtures that fail here indicate referee drift — either this
// impl regressed, or the spec (the fixture) changed and the other
// impl needs an update. The fixture name is the first thing in
// any failure message so the file is one click away.

package lynrummy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	opValidateGameMove      = "validate_game_move"
	opValidateTurnComplete  = "validate_turn_complete"
)

// --- Fixture envelope ---

type conformanceFixture struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Operation   string          `json:"operation"`
	Input       json.RawMessage `json:"input"`
	Bounds      BoardBounds     `json:"bounds"`
	Expected    expectedResult  `json:"expected"`
}

type expectedResult struct {
	OK    bool           `json:"ok"`
	Error *expectedError `json:"error,omitempty"`
}

type expectedError struct {
	Stage         string `json:"stage"`
	MessageSubstr string `json:"message_substr"`
}

// --- Per-operation input types ---

type validateGameMoveInput struct {
	BoardBefore     []CardStack `json:"board_before"`
	StacksToRemove  []CardStack `json:"stacks_to_remove"`
	StacksToAdd     []CardStack `json:"stacks_to_add"`
	HandCardsPlayed []HandCard  `json:"hand_cards_played,omitempty"`
}

type validateTurnCompleteInput struct {
	Board []CardStack `json:"board"`
}

// --- Runner ---

func TestConformanceFixtures(t *testing.T) {
	matches, err := filepath.Glob("conformance/*.json")
	if err != nil {
		t.Fatalf("glob failed: %v", err)
	}
	if len(matches) == 0 {
		t.Fatal("no conformance fixtures found under conformance/")
	}

	for _, path := range matches {
		path := path
		name := strings.TrimSuffix(filepath.Base(path), ".json")
		t.Run(name, func(t *testing.T) {
			runFixture(t, path)
		})
	}
}

func runFixture(t *testing.T, path string) {
	t.Helper()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%s: read: %v", path, err)
	}

	var fx conformanceFixture
	if err := json.Unmarshal(data, &fx); err != nil {
		t.Fatalf("%s: parse envelope: %v", path, err)
	}

	var got *RefereeError
	switch fx.Operation {
	case opValidateGameMove:
		var in validateGameMoveInput
		if err := json.Unmarshal(fx.Input, &in); err != nil {
			t.Fatalf("%s: parse input: %v", path, err)
		}
		handCards := make([]Card, len(in.HandCardsPlayed))
		for i, hc := range in.HandCardsPlayed {
			handCards[i] = hc.Card
		}
		got = ValidateGameMove(Move{
			BoardBefore:     in.BoardBefore,
			StacksToRemove:  in.StacksToRemove,
			StacksToAdd:     in.StacksToAdd,
			HandCardsPlayed: handCards,
		}, fx.Bounds)

	case opValidateTurnComplete:
		var in validateTurnCompleteInput
		if err := json.Unmarshal(fx.Input, &in); err != nil {
			t.Fatalf("%s: parse input: %v", path, err)
		}
		got = ValidateTurnComplete(in.Board, fx.Bounds)

	default:
		t.Fatalf("%s: unknown operation %q", path, fx.Operation)
	}

	checkExpected(t, path, fx.Expected, got)
}

func checkExpected(t *testing.T, path string, want expectedResult, got *RefereeError) {
	t.Helper()

	if want.OK {
		if got != nil {
			t.Fatalf("%s: expected ok, got %s: %s", path, got.Stage, got.Message)
		}
		return
	}

	if got == nil {
		t.Fatalf("%s: expected error at stage %q, got ok", path, want.Error.Stage)
	}
	if got.Stage != want.Error.Stage {
		t.Fatalf("%s: stage mismatch — want %q, got %q (message: %s)",
			path, want.Error.Stage, got.Stage, got.Message)
	}
	if want.Error.MessageSubstr != "" && !strings.Contains(got.Message, want.Error.MessageSubstr) {
		t.Fatalf("%s: message substring %q not found in %q",
			path, want.Error.MessageSubstr, got.Message)
	}
}
