// GameSetup — the "photo" the dealer returns, consumed by the Elm
// client to open a session. The old diff-based host dispatch path
// (CheckEvent / ParseMoveEvent / ReconstructBoard and the wire*
// types) was ripped 2026-04-21 after confirming zero live callers;
// the current flow is WireAction → DecodeWireAction →
// ReplayActionsSeeded (see wire_action.go and replay.go).

package lynrummy

import "encoding/json"

// GameSetup matches the TS `GameSetup` shape and is the first event
// of every game: the board, both players' hands, and the remaining
// deck.
type GameSetup struct {
	Board []CardStack `json:"board"`
	Hands [2][]Card   `json:"hands"`
	Deck  []Card      `json:"deck"`
}

var _ json.Marshaler = (*CardStack)(nil)
