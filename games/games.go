// Package games provides a simple game event bus.
//
// A game has 1-2 players and an ordered sequence of opaque JSON
// events. Angry Gopher doesn't understand the game rules — it
// just relays payloads between authenticated players.
//
// Endpoints:
//   POST /gopher/games          — create a game (caller is player 1)
//   POST /gopher/games/{id}/join — join an existing game (caller is player 2)
//   GET  /gopher/games          — list games for the current user
//   POST /gopher/games/{id}/events — post a game event
//   GET  /gopher/games/{id}/events?after=N — poll for new events

package games

import (
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"angry-gopher/auth"
	"angry-gopher/respond"
)

var DB *sql.DB

// Per-game notification: when an event is posted, all waiting
// long-poll requests for that game wake up and re-query.
var (
	waitersMu sync.Mutex
	waiters   = map[int][]chan struct{}{} // game_id → list of channels
)

func notifyWaiters(gameID int) {
	waitersMu.Lock()
	defer waitersMu.Unlock()
	for _, ch := range waiters[gameID] {
		close(ch)
	}
	delete(waiters, gameID)
}

func addWaiter(gameID int) chan struct{} {
	waitersMu.Lock()
	defer waitersMu.Unlock()
	ch := make(chan struct{})
	waiters[gameID] = append(waiters[gameID], ch)
	return ch
}


// HandleGames routes to create or list based on method.
func HandleGames(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "POST":
		handleCreate(w, r)
	case "GET":
		handleList(w, r)
	default:
		respond.Error(w, "Method not allowed")
	}
}

// HandleGameSub routes /gopher/games/{id}/join and /gopher/games/{id}/events.
func HandleGameSub(w http.ResponseWriter, r *http.Request) {
	// Path: /gopher/games/{id}/action
	parts := strings.Split(r.URL.Path, "/")
	// Expected: ["", "gopher", "games", "{id}", "{action}"]
	if len(parts) < 5 {
		respond.Error(w, "Invalid game path")
		return
	}

	gameID, err := strconv.Atoi(parts[3])
	if err != nil || gameID <= 0 {
		respond.Error(w, "Invalid game ID")
		return
	}

	action := parts[4]
	switch action {
	case "join":
		handleJoin(w, r, gameID)
	case "events":
		switch r.Method {
		case "POST":
			handlePostEvent(w, r, gameID)
		case "GET":
			handleGetEvents(w, r, gameID)
		default:
			respond.Error(w, "Method not allowed")
		}
	default:
		respond.Error(w, "Unknown game action: "+action)
	}
}

func handleCreate(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Authentication required")
		return
	}

	// Optional JSON body: { "puzzle_name": "puzzle_24" }.
	// A regular game is created with no body or an empty body —
	// the server only stores puzzle_name as an opaque label and
	// never interprets puzzle contents.
	var body struct {
		PuzzleName *string `json:"puzzle_name"`
	}
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}

	var puzzleName interface{}
	if body.PuzzleName != nil && *body.PuzzleName != "" {
		puzzleName = *body.PuzzleName
	}

	now := time.Now().Unix()
	result, err := DB.Exec(
		`INSERT INTO games (player1_id, player2_id, created_at, puzzle_name) VALUES (?, NULL, ?, ?)`,
		userID, now, puzzleName,
	)
	if err != nil {
		respond.Error(w, "Failed to create game: "+err.Error())
		return
	}

	gameID, _ := result.LastInsertId()
	respond.Success(w, map[string]interface{}{
		"game_id": gameID,
	})
}

func handleJoin(w http.ResponseWriter, r *http.Request, gameID int) {
	if r.Method != "POST" {
		respond.Error(w, "Method not allowed")
		return
	}

	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Authentication required")
		return
	}

	var player1ID int
	var player2ID sql.NullInt64
	err := DB.QueryRow(
		`SELECT player1_id, player2_id FROM games WHERE id = ?`, gameID,
	).Scan(&player1ID, &player2ID)
	if err != nil {
		respond.Error(w, "Game not found")
		return
	}

	if player1ID == userID {
		respond.Error(w, "You are already player 1 in this game")
		return
	}

	if player2ID.Valid {
		respond.Error(w, "Game already has two players")
		return
	}

	_, err = DB.Exec(
		`UPDATE games SET player2_id = ? WHERE id = ?`,
		userID, gameID,
	)
	if err != nil {
		respond.Error(w, "Failed to join game: "+err.Error())
		return
	}

	respond.Success(w, nil)
}

func handleList(w http.ResponseWriter, r *http.Request) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Authentication required")
		return
	}

	// Return games the user is in, plus open games they could join.
	rows, err := DB.Query(`
		SELECT g.id, g.player1_id, g.player2_id, g.created_at, g.puzzle_name,
		       (SELECT COUNT(*) FROM game_events WHERE game_id = g.id) AS event_count
		FROM games g
		WHERE g.player1_id = ? OR g.player2_id = ?
		   OR (g.player2_id IS NULL AND g.player1_id != ?)
		ORDER BY g.created_at DESC
	`, userID, userID, userID)
	if err != nil {
		respond.Error(w, "Failed to list games: "+err.Error())
		return
	}
	defer rows.Close()

	type gameInfo struct {
		ID         int     `json:"id"`
		Player1ID  int     `json:"player1_id"`
		Player2ID  *int    `json:"player2_id"`
		CreatedAt  int64   `json:"created_at"`
		EventCount int     `json:"event_count"`
		PuzzleName *string `json:"puzzle_name"`
	}

	games := []gameInfo{}
	for rows.Next() {
		var g gameInfo
		var p2 sql.NullInt64
		var puzzle sql.NullString
		rows.Scan(&g.ID, &g.Player1ID, &p2, &g.CreatedAt, &puzzle, &g.EventCount)
		if p2.Valid {
			p2val := int(p2.Int64)
			g.Player2ID = &p2val
		}
		if puzzle.Valid {
			s := puzzle.String
			g.PuzzleName = &s
		}
		games = append(games, g)
	}

	respond.Success(w, map[string]interface{}{
		"games": games,
	})
}

func isPlayerInGame(userID, gameID int) bool {
	var count int
	DB.QueryRow(
		`SELECT COUNT(*) FROM games WHERE id = ? AND (player1_id = ? OR player2_id = ?)`,
		gameID, userID, userID,
	).Scan(&count)
	return count > 0
}

func handlePostEvent(w http.ResponseWriter, r *http.Request, gameID int) {
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

	// Validate that the payload is valid JSON.
	var payload json.RawMessage
	if err := json.Unmarshal(body, &payload); err != nil {
		respond.Error(w, "Invalid JSON payload")
		return
	}

	now := time.Now().Unix()
	result, err := DB.Exec(
		`INSERT INTO game_events (game_id, user_id, payload, created_at) VALUES (?, ?, ?, ?)`,
		gameID, userID, string(payload), now,
	)
	if err != nil {
		respond.Error(w, "Failed to post event: "+err.Error())
		return
	}

	eventID, _ := result.LastInsertId()
	notifyWaiters(gameID)
	respond.Success(w, map[string]interface{}{
		"event_id": eventID,
	})
}

func queryEvents(gameID, after int) ([]eventInfo, error) {
	rows, err := DB.Query(`
		SELECT id, user_id, payload, created_at
		FROM game_events
		WHERE game_id = ? AND id > ?
		ORDER BY id ASC
	`, gameID, after)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var events []eventInfo
	for rows.Next() {
		var e eventInfo
		var payloadStr string
		rows.Scan(&e.ID, &e.UserID, &payloadStr, &e.CreatedAt)
		e.Payload = json.RawMessage(payloadStr)
		events = append(events, e)
	}
	return events, nil
}

type eventInfo struct {
	ID        int             `json:"id"`
	UserID    int             `json:"user_id"`
	Payload   json.RawMessage `json:"payload"`
	CreatedAt int64           `json:"created_at"`
}

func handleGetEvents(w http.ResponseWriter, r *http.Request, gameID int) {
	userID := auth.Authenticate(r)
	if userID == 0 {
		respond.Error(w, "Authentication required")
		return
	}

	if !isPlayerInGame(userID, gameID) {
		respond.Error(w, "You are not a player in this game")
		return
	}

	afterStr := r.URL.Query().Get("after")
	after := 0
	if afterStr != "" {
		after, _ = strconv.Atoi(afterStr)
	}

	// First check: are there already events waiting?
	events, err := queryEvents(gameID, after)
	if err != nil {
		respond.Error(w, "Failed to get events: "+err.Error())
		return
	}

	// If no events and long-polling requested, block until one arrives
	// or the timeout expires or the client disconnects.
	if len(events) == 0 {
		timeoutStr := r.URL.Query().Get("timeout")
		timeoutSec := 0
		if timeoutStr != "" {
			timeoutSec, _ = strconv.Atoi(timeoutStr)
		}

		if timeoutSec > 0 {
			ch := addWaiter(gameID)
			timer := time.NewTimer(time.Duration(timeoutSec) * time.Second)
			defer timer.Stop()

			select {
			case <-ch:
				// New event posted — re-query.
			case <-timer.C:
				// Timeout — return empty.
			case <-r.Context().Done():
				// Client disconnected.
				return
			}

			events, err = queryEvents(gameID, after)
			if err != nil {
				respond.Error(w, "Failed to get events: "+err.Error())
				return
			}
		}
	}

	respond.Success(w, map[string]interface{}{
		"events": events,
	})
}
