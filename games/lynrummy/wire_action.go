// Action-shaped wire format for the LynRummy port. Each WireAction
// names a thing the player did, rather than the mechanical diff
// that resulted. Receiver derives post-state by applying the
// action to the prior state.
//
// Mirrors elm/src/Game/WireAction.elm. JSON shape is
// the canonical wire contract; both sides round-trip identical
// bytes for identical values.
//
// See showell/claude_writings/actions_not_diffs.md for rationale.

package lynrummy

import (
	"encoding/json"
	"fmt"
)

// Side is the wire-level enum for left/right discrimination on
// merges. String-shaped so JSON carries "left"/"right" directly.
type Side string

const (
	LeftSide  Side = "left"
	RightSide Side = "right"
)

// WireAction is the interface all concrete action types satisfy.
// Implementations are SplitAction, MergeStackAction, etc. Each
// implements ActionKind() so we can introspect without type-switching
// (the kind string also appears in the JSON "action" field).
type WireAction interface {
	ActionKind() string
}

// --- Concrete action types ---

type SplitAction struct {
	StackIndex int `json:"stack_index"`
	CardIndex  int `json:"card_index"`
}

func (SplitAction) ActionKind() string { return "split" }

type MergeStackAction struct {
	SourceStack int  `json:"source_stack"`
	TargetStack int  `json:"target_stack"`
	Side        Side `json:"side"`
}

func (MergeStackAction) ActionKind() string { return "merge_stack" }

type MergeHandAction struct {
	HandCard    Card `json:"hand_card"`
	TargetStack int  `json:"target_stack"`
	Side        Side `json:"side"`
}

func (MergeHandAction) ActionKind() string { return "merge_hand" }

type PlaceHandAction struct {
	HandCard Card     `json:"hand_card"`
	Loc      Location `json:"loc"`
}

func (PlaceHandAction) ActionKind() string { return "place_hand" }

type MoveStackAction struct {
	StackIndex int      `json:"stack_index"`
	NewLoc     Location `json:"new_loc"`
}

func (MoveStackAction) ActionKind() string { return "move_stack" }

type CompleteTurnAction struct{}

func (CompleteTurnAction) ActionKind() string { return "complete_turn" }

type UndoAction struct{}

func (UndoAction) ActionKind() string { return "undo" }

// --- Encode ---
//
// Each concrete type implements MarshalJSON to inject the
// "action" tag alongside its own fields. This lets callers
// json.Marshal a WireAction value (via an interface variable
// or a concrete value) and get the canonical wire shape.

func (a SplitAction) MarshalJSON() ([]byte, error) {
	type alias SplitAction
	return json.Marshal(struct {
		Action string `json:"action"`
		alias
	}{Action: a.ActionKind(), alias: alias(a)})
}

func (a MergeStackAction) MarshalJSON() ([]byte, error) {
	type alias MergeStackAction
	return json.Marshal(struct {
		Action string `json:"action"`
		alias
	}{Action: a.ActionKind(), alias: alias(a)})
}

func (a MergeHandAction) MarshalJSON() ([]byte, error) {
	type alias MergeHandAction
	return json.Marshal(struct {
		Action string `json:"action"`
		alias
	}{Action: a.ActionKind(), alias: alias(a)})
}

func (a PlaceHandAction) MarshalJSON() ([]byte, error) {
	type alias PlaceHandAction
	return json.Marshal(struct {
		Action string `json:"action"`
		alias
	}{Action: a.ActionKind(), alias: alias(a)})
}

func (a MoveStackAction) MarshalJSON() ([]byte, error) {
	type alias MoveStackAction
	return json.Marshal(struct {
		Action string `json:"action"`
		alias
	}{Action: a.ActionKind(), alias: alias(a)})
}

func (a CompleteTurnAction) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		Action string `json:"action"`
	}{Action: a.ActionKind()})
}

func (a UndoAction) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		Action string `json:"action"`
	}{Action: a.ActionKind()})
}

// --- Decode ---

// DecodeWireAction parses a JSON byte slice into one of the
// concrete action types (returned via the WireAction interface).
// Returns an error for unknown action tags, missing fields, or
// invalid side values.
func DecodeWireAction(data []byte) (WireAction, error) {
	var tag struct {
		Action string `json:"action"`
	}
	if err := json.Unmarshal(data, &tag); err != nil {
		return nil, err
	}
	if tag.Action == "" {
		return nil, fmt.Errorf("wire action: missing 'action' tag")
	}

	switch tag.Action {
	case "split":
		var a SplitAction
		if err := strictUnmarshal(data, &a, "stack_index", "card_index"); err != nil {
			return nil, err
		}
		return a, nil

	case "merge_stack":
		var a MergeStackAction
		if err := strictUnmarshal(data, &a, "source_stack", "target_stack", "side"); err != nil {
			return nil, err
		}
		if err := validateSide(a.Side); err != nil {
			return nil, err
		}
		return a, nil

	case "merge_hand":
		var a MergeHandAction
		if err := strictUnmarshal(data, &a, "hand_card", "target_stack", "side"); err != nil {
			return nil, err
		}
		if err := validateSide(a.Side); err != nil {
			return nil, err
		}
		return a, nil

	case "place_hand":
		var a PlaceHandAction
		if err := strictUnmarshal(data, &a, "hand_card", "loc"); err != nil {
			return nil, err
		}
		return a, nil

	case "move_stack":
		var a MoveStackAction
		if err := strictUnmarshal(data, &a, "stack_index", "new_loc"); err != nil {
			return nil, err
		}
		return a, nil

	case "complete_turn":
		return CompleteTurnAction{}, nil

	case "undo":
		return UndoAction{}, nil

	default:
		return nil, fmt.Errorf("wire action: unknown action %q", tag.Action)
	}
}

// strictUnmarshal decodes into dest and verifies the named
// required fields are present in the raw JSON. JSON's default
// "zero value on missing" silently accepts {"action":"split"}
// as a valid Split with stack_index=0 and card_index=0, which
// would hide real bugs. This checker rejects it.
func strictUnmarshal(data []byte, dest interface{}, required ...string) error {
	if err := json.Unmarshal(data, dest); err != nil {
		return err
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	for _, name := range required {
		if _, ok := fields[name]; !ok {
			return fmt.Errorf("wire action: missing required field %q", name)
		}
	}
	return nil
}

func validateSide(s Side) error {
	if s != LeftSide && s != RightSide {
		return fmt.Errorf("wire action: invalid side %q", s)
	}
	return nil
}
