// Cross-language conformance for tricks. Walks the fixture files
// under ../conformance/tricks/*.json, runs the named trick, and
// asserts against expected.
//
// Mirrors ../conformance_test.go (the referee one). See
// ../conformance/README.md for the fixture format.

package tricks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"angry-gopher/lynrummy"
)

const opTrickFirstPlay = "trick_first_play"

// Registered tricks — the runner dispatches on fixture.trick_id.
// Add new tricks here as they're ported.
var trickRegistry = map[string]Trick{
	"direct_play": DirectPlay,
	"hand_stacks": HandStacks,
}

// --- Fixture envelope ---

type fixture struct {
	Name      string          `json:"name"`
	Operation string          `json:"operation"`
	Input     json.RawMessage `json:"input"`
	Expected  expected        `json:"expected"`
}

type expected struct {
	OK      bool          `json:"ok"`
	NoPlays bool          `json:"no_plays"`
	Play    *expectedPlay `json:"play"`
}

type expectedPlay struct {
	HandCardsPlayed []lynrummy.HandCard  `json:"hand_cards_played"`
	BoardAfter      []lynrummy.CardStack `json:"board_after"`
}

type trickInput struct {
	TrickID string               `json:"trick_id"`
	Hand    []lynrummy.HandCard  `json:"hand"`
	Board   []lynrummy.CardStack `json:"board"`
}

// --- Runner ---

func TestTrickConformanceFixtures(t *testing.T) {
	matches, err := filepath.Glob("../conformance/tricks/*.json")
	if err != nil {
		t.Fatalf("glob failed: %v", err)
	}
	if len(matches) == 0 {
		t.Fatal("no trick fixtures found under ../conformance/tricks/")
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

	var fx fixture
	if err := json.Unmarshal(data, &fx); err != nil {
		t.Fatalf("%s: parse envelope: %v", path, err)
	}

	if fx.Operation != opTrickFirstPlay {
		t.Fatalf("%s: unsupported operation %q", path, fx.Operation)
	}

	var in trickInput
	if err := json.Unmarshal(fx.Input, &in); err != nil {
		t.Fatalf("%s: parse input: %v", path, err)
	}

	trick, ok := trickRegistry[in.TrickID]
	if !ok {
		t.Fatalf("%s: unknown trick_id %q", path, in.TrickID)
	}

	plays := trick.FindPlays(in.Hand, in.Board)

	if fx.Expected.NoPlays {
		if len(plays) != 0 {
			t.Fatalf("%s: expected no plays, got %d", path, len(plays))
		}
		return
	}

	if len(plays) == 0 {
		t.Fatalf("%s: expected a play, got none", path)
	}

	play := plays[0]
	gotBoard, gotHand := play.Apply(in.Board)

	if fx.Expected.Play == nil {
		t.Fatalf("%s: expected.play missing in fixture", path)
	}

	assertJSONEqual(t, path, "hand_cards_played",
		fx.Expected.Play.HandCardsPlayed, gotHand)
	assertJSONEqual(t, path, "board_after",
		fx.Expected.Play.BoardAfter, gotBoard)
}

// assertJSONEqual marshals both values and compares byte output.
// Produces a readable diff on mismatch.
func assertJSONEqual(t *testing.T, path, label string, want, got interface{}) {
	t.Helper()

	wantBytes, err := json.Marshal(want)
	if err != nil {
		t.Fatalf("%s: marshal want %s: %v", path, label, err)
	}
	gotBytes, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("%s: marshal got %s: %v", path, label, err)
	}
	if string(wantBytes) != string(gotBytes) {
		t.Fatalf("%s: %s mismatch\n  want: %s\n  got:  %s",
			path, label, wantBytes, gotBytes)
	}
}
