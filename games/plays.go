// LynRummy plays endpoint — strategic metadata about each move.
//
// A "play" is one mechanical move (stacks_to_remove / stacks_to_add
// / hand_cards_to_release) PLUS strategic metadata describing the
// trick used, cards highlighted, and a human-readable narration.
// The mechanical side still gets written to game_events (so the
// existing replay flow keeps working); the strategic side lives in
// the lynrummy_plays table.
//
// Endpoints:
//   POST /gopher/games/{id}/plays          — record a play
//   GET  /gopher/games/{id}/plays          — list plays for a game
//   PATCH /gopher/plays/{event_id}         — annotate a play (note)

package games

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"angry-gopher/auth"
	"angry-gopher/respond"
)

// PlayRecord mirrors the TypeScript PlayRecord shape. JSON fields
// use snake_case to match the Angry Cat client.
type PlayRecord struct {
	TrickID     string          `json:"trick_id"`
	Description string          `json:"description"`
	HandCards   json.RawMessage `json:"hand_cards"`
	BoardCards  json.RawMessage `json:"board_cards"`
	Detail      json.RawMessage `json:"detail"`
	Note        string          `json:"note,omitempty"`

	// The mechanical half — same shape as the existing event payload.
	// Written to game_events.payload verbatim so replay stays
	// backwards-compatible.
	BoardEvent json.RawMessage `json:"board_event"`

	// Which player made the move. Redundant with the user_id but
	// useful for queries and replays.
	Player int `json:"player"`
}

// handlePostPlay accepts a PlayRecord, stores the mechanical side
// in game_events, and the strategic side in lynrummy_plays.
func handlePostPlay(w http.ResponseWriter, r *http.Request, gameID int) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Authentication required")
		return
	}
	if !isPlayerInGame(userID, gameID) {
		respond.Error(w, "You are not a player in this game")
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		respond.Error(w, "Failed to read request body")
		return
	}
	var play PlayRecord
	if err := json.Unmarshal(body, &play); err != nil {
		respond.Error(w, "Invalid PlayRecord JSON: "+err.Error())
		return
	}
	if play.TrickID == "" {
		respond.Error(w, "trick_id is required")
		return
	}
	if len(play.BoardEvent) == 0 {
		respond.Error(w, "board_event is required")
		return
	}

	// Referee validates the mechanical side exactly as the legacy
	// events endpoint does.
	if refErr := refereeCheck(gameID, play.BoardEvent); refErr != nil {
		respond.Error(w, "Referee rejected move: "+refErr.Error())
		return
	}

	// Two inserts, one transaction — the strategic row references
	// the mechanical row's id.
	tx, err := DB.Begin()
	if err != nil {
		respond.Error(w, "DB begin: "+err.Error())
		return
	}
	defer tx.Rollback()

	now := time.Now().Unix()
	result, err := tx.Exec(
		`INSERT INTO game_events (game_id, user_id, payload, created_at) VALUES (?, ?, ?, ?)`,
		gameID, userID, string(play.BoardEvent), now,
	)
	if err != nil {
		respond.Error(w, "Failed to insert event: "+err.Error())
		return
	}
	eventID, _ := result.LastInsertId()

	_, err = tx.Exec(
		`INSERT INTO lynrummy_plays
		 (event_id, game_id, player, trick_id, description,
		  hand_cards_json, board_cards_json, detail_json, note, created_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		eventID, gameID, play.Player, play.TrickID, play.Description,
		string(rawOrEmpty(play.HandCards)),
		string(rawOrEmpty(play.BoardCards)),
		string(rawOrEmpty(play.Detail)),
		play.Note,
		now,
	)
	if err != nil {
		respond.Error(w, "Failed to insert play: "+err.Error())
		return
	}

	if err := tx.Commit(); err != nil {
		respond.Error(w, "DB commit: "+err.Error())
		return
	}

	notifyWaiters(gameID)
	respond.Success(w, map[string]interface{}{
		"event_id": eventID,
	})
}

// handleGetPlays returns every play for a game, ordered by event_id.
func handleGetPlays(w http.ResponseWriter, r *http.Request, gameID int) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Authentication required")
		return
	}
	if !isPlayerInGame(userID, gameID) {
		respond.Error(w, "You are not a player in this game")
		return
	}

	rows, err := DB.Query(`
		SELECT event_id, player, trick_id, description,
		       hand_cards_json, board_cards_json, detail_json, note, created_at
		FROM lynrummy_plays
		WHERE game_id = ?
		ORDER BY event_id ASC
	`, gameID)
	if err != nil {
		respond.Error(w, "Failed to query plays: "+err.Error())
		return
	}
	defer rows.Close()

	type playOut struct {
		EventID     int64           `json:"event_id"`
		Player      int             `json:"player"`
		TrickID     string          `json:"trick_id"`
		Description string          `json:"description"`
		HandCards   json.RawMessage `json:"hand_cards"`
		BoardCards  json.RawMessage `json:"board_cards"`
		Detail      json.RawMessage `json:"detail"`
		Note        string          `json:"note"`
		CreatedAt   int64           `json:"created_at"`
	}
	out := []playOut{}
	for rows.Next() {
		var p playOut
		var hc, bc, det string
		if err := rows.Scan(
			&p.EventID, &p.Player, &p.TrickID, &p.Description,
			&hc, &bc, &det, &p.Note, &p.CreatedAt,
		); err != nil {
			respond.Error(w, "Scan failed: "+err.Error())
			return
		}
		p.HandCards = json.RawMessage(hc)
		p.BoardCards = json.RawMessage(bc)
		p.Detail = json.RawMessage(det)
		out = append(out, p)
	}
	respond.Success(w, map[string]interface{}{"plays": out})
}

// HandlePlaysRoot is the entry point for /gopher/plays/{event_id}.
// Currently only supports PATCH (annotate).
func HandlePlaysRoot(w http.ResponseWriter, r *http.Request) {
	parts := strings.Split(strings.TrimSuffix(r.URL.Path, "/"), "/")
	// /gopher/plays/{event_id}
	if len(parts) != 4 {
		respond.Error(w, "Invalid plays path")
		return
	}
	eventID, err := strconv.Atoi(parts[3])
	if err != nil || eventID <= 0 {
		respond.Error(w, "Invalid event ID")
		return
	}
	switch r.Method {
	case "PATCH":
		handleAnnotatePlay(w, r, eventID)
	default:
		respond.Error(w, "Method not allowed")
	}
}

func handleAnnotatePlay(w http.ResponseWriter, r *http.Request, eventID int) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Authentication required")
		return
	}

	// Only a player in the game can annotate. Look up the game_id
	// via the join table.
	var gameID int
	if err := DB.QueryRow(
		`SELECT game_id FROM lynrummy_plays WHERE event_id = ?`, eventID,
	).Scan(&gameID); err != nil {
		respond.Error(w, "Play not found")
		return
	}
	if !isPlayerInGame(userID, gameID) {
		respond.Error(w, "You are not a player in this game")
		return
	}

	var body struct {
		Note string `json:"note"`
	}
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}

	if _, err := DB.Exec(
		`UPDATE lynrummy_plays SET note = ? WHERE event_id = ?`,
		body.Note, eventID,
	); err != nil {
		respond.Error(w, "Failed to update note: "+err.Error())
		return
	}
	respond.Success(w, map[string]interface{}{"event_id": eventID})
}

func rawOrEmpty(r json.RawMessage) json.RawMessage {
	if len(r) == 0 {
		return json.RawMessage("null")
	}
	return r
}
