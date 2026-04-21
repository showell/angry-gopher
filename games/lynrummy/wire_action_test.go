// Tests for WireAction: round-trip, exact JSON shape, and
// decode errors. Format-lock tests intentionally mirror
// elm/tests/Game/WireActionTest.elm — matching
// expected JSON bytes across both sides is the
// cross-language conformance check.

package lynrummy

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestWireAction_RoundTrip(t *testing.T) {
	card8H := Card{Value: 8, Suit: Heart, OriginDeck: 0}

	cases := []struct {
		name   string
		action WireAction
	}{
		{"split", SplitAction{StackIndex: 5, CardIndex: 2}},
		{"merge_stack left", MergeStackAction{SourceStack: 5, TargetStack: 3, Side: LeftSide}},
		{"merge_stack right", MergeStackAction{SourceStack: 5, TargetStack: 3, Side: RightSide}},
		{"merge_hand", MergeHandAction{HandCard: card8H, TargetStack: 5, Side: RightSide}},
		{"place_hand", PlaceHandAction{HandCard: card8H, Loc: Location{Top: 140, Left: 220}}},
		{"move_stack", MoveStackAction{StackIndex: 5, NewLoc: Location{Top: 140, Left: 220}}},
		{"complete_turn", CompleteTurnAction{}},
		{"undo", UndoAction{}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			data, err := json.Marshal(tc.action)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			got, err := DecodeWireAction(data)
			if err != nil {
				t.Fatalf("decode: %v (payload=%s)", err, data)
			}
			if !reflect.DeepEqual(got, tc.action) {
				t.Errorf("round-trip mismatch:\n  want: %+v\n  got:  %+v\n  payload: %s",
					tc.action, got, data)
			}
		})
	}
}

// TestWireAction_JSONShape locks the exact wire bytes for a
// few representative actions. If this test fails, the wire
// contract has drifted — the Elm test suite has matching
// expectations, so both should break together.
func TestWireAction_JSONShape(t *testing.T) {
	cases := []struct {
		name   string
		action WireAction
		want   string
	}{
		{
			"split — tag + indices",
			SplitAction{StackIndex: 5, CardIndex: 2},
			`{"action":"split","stack_index":5,"card_index":2}`,
		},
		{
			"merge_stack — side lowercased",
			MergeStackAction{SourceStack: 1, TargetStack: 2, Side: RightSide},
			`{"action":"merge_stack","source_stack":1,"target_stack":2,"side":"right"}`,
		},
		{
			"complete_turn — bare tag",
			CompleteTurnAction{},
			`{"action":"complete_turn"}`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := json.Marshal(tc.action)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if string(got) != tc.want {
				t.Errorf("JSON shape mismatch:\n  want: %s\n  got:  %s", tc.want, got)
			}
		})
	}
}

func TestWireAction_DecodeErrors(t *testing.T) {
	cases := []struct {
		name    string
		payload string
		errSub  string
	}{
		{
			"unknown action tag",
			`{"action":"flibbertigibbet"}`,
			"unknown action",
		},
		{
			"missing payload field",
			`{"action":"split"}`,
			"missing required field",
		},
		{
			"invalid side value",
			`{"action":"merge_stack","source_stack":1,"target_stack":2,"side":"middle"}`,
			"invalid side",
		},
		{
			"missing action tag",
			`{}`,
			"missing 'action' tag",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := DecodeWireAction([]byte(tc.payload))
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.errSub)
			}
			if !strings.Contains(err.Error(), tc.errSub) {
				t.Errorf("error mismatch:\n  want substring: %s\n  got: %s", tc.errSub, err)
			}
		})
	}
}
