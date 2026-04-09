package games_test

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"angry-gopher/auth"
	"angry-gopher/games"

	_ "modernc.org/sqlite"
)

func setupTestDB(t *testing.T) {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)

	db.Exec(`CREATE TABLE IF NOT EXISTS users (
		id INTEGER PRIMARY KEY,
		email TEXT NOT NULL,
		full_name TEXT NOT NULL,
		api_key TEXT NOT NULL DEFAULT ''
	)`)
	db.Exec(`INSERT INTO users (id, email, full_name, api_key) VALUES (1, 'steve@example.com', 'Steve', 'steve-key')`)
	db.Exec(`INSERT INTO users (id, email, full_name, api_key) VALUES (2, 'mom@example.com', 'Mom', 'mom-key')`)

	auth.DB = db
	games.DB = db
	games.InitSchema()
}

func authRequest(method, path, body, apiKey string) *http.Request {
	var r *http.Request
	if body != "" {
		r = httptest.NewRequest(method, path, strings.NewReader(body))
		r.Header.Set("Content-Type", "application/json")
	} else {
		r = httptest.NewRequest(method, path, nil)
	}
	// Basic auth: email:api_key
	r.SetBasicAuth(apiKey+"@example.com", apiKey+"-key")
	return r
}

func parseResponse(t *testing.T, w *httptest.ResponseRecorder) map[string]interface{} {
	t.Helper()
	var result map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatalf("Failed to parse response: %v\nbody: %s", err, w.Body.String())
	}
	return result
}

func TestCreateAndListGame(t *testing.T) {
	setupTestDB(t)

	// Steve creates a game.
	w := httptest.NewRecorder()
	games.HandleGames(w, authRequest("POST", "/gopher/games", "", "steve"))
	resp := parseResponse(t, w)

	if resp["result"] != "success" {
		t.Fatalf("Expected success, got: %v", resp)
	}
	gameID := resp["game_id"].(float64)
	if gameID != 1 {
		t.Fatalf("Expected game_id=1, got %v", gameID)
	}

	// Steve lists games — should see 1 game.
	w = httptest.NewRecorder()
	games.HandleGames(w, authRequest("GET", "/gopher/games", "", "steve"))
	resp = parseResponse(t, w)

	gamesList := resp["games"].([]interface{})
	if len(gamesList) != 1 {
		t.Fatalf("Expected 1 game, got %d", len(gamesList))
	}
	game := gamesList[0].(map[string]interface{})
	if game["player2_id"] != nil {
		t.Fatalf("Expected player2_id to be nil, got %v", game["player2_id"])
	}
	// Regular games have a null puzzle_name.
	if game["puzzle_name"] != nil {
		t.Fatalf("Expected puzzle_name to be nil for a regular game, got %v", game["puzzle_name"])
	}

	// Mom lists games — should see 1 (Steve's open game she can join).
	w = httptest.NewRecorder()
	games.HandleGames(w, authRequest("GET", "/gopher/games", "", "mom"))
	resp = parseResponse(t, w)

	gamesList = resp["games"].([]interface{})
	if len(gamesList) != 1 {
		t.Fatalf("Expected 1 open game for mom, got %d", len(gamesList))
	}
}

func TestCreatePuzzleGame(t *testing.T) {
	setupTestDB(t)

	// Steve creates a puzzle game by passing a puzzle_name in the body.
	w := httptest.NewRecorder()
	games.HandleGames(w, authRequest(
		"POST", "/gopher/games",
		`{"puzzle_name":"puzzle_24"}`, "steve",
	))
	resp := parseResponse(t, w)
	if resp["result"] != "success" {
		t.Fatalf("Expected success, got: %v", resp)
	}

	// List games and verify puzzle_name comes back through the lobby
	// API without any extra round-trip into events.
	w = httptest.NewRecorder()
	games.HandleGames(w, authRequest("GET", "/gopher/games", "", "steve"))
	resp = parseResponse(t, w)
	gamesList := resp["games"].([]interface{})
	if len(gamesList) != 1 {
		t.Fatalf("Expected 1 game, got %d", len(gamesList))
	}
	game := gamesList[0].(map[string]interface{})
	if game["puzzle_name"] != "puzzle_24" {
		t.Fatalf("Expected puzzle_name=puzzle_24, got %v", game["puzzle_name"])
	}
}

func TestCreateGameEmptyBodyStillWorks(t *testing.T) {
	setupTestDB(t)

	// Steve creates a regular game by sending an empty JSON object.
	// Existing clients send no body at all, but we want both to work.
	w := httptest.NewRecorder()
	games.HandleGames(w, authRequest(
		"POST", "/gopher/games",
		`{}`, "steve",
	))
	resp := parseResponse(t, w)
	if resp["result"] != "success" {
		t.Fatalf("Expected success, got: %v", resp)
	}

	// Verify it's stored as a non-puzzle game.
	w = httptest.NewRecorder()
	games.HandleGames(w, authRequest("GET", "/gopher/games", "", "steve"))
	resp = parseResponse(t, w)
	gamesList := resp["games"].([]interface{})
	game := gamesList[0].(map[string]interface{})
	if game["puzzle_name"] != nil {
		t.Fatalf("Expected puzzle_name=nil for empty body, got %v", game["puzzle_name"])
	}
}

func TestJoinGame(t *testing.T) {
	setupTestDB(t)

	// Steve creates a game.
	w := httptest.NewRecorder()
	games.HandleGames(w, authRequest("POST", "/gopher/games", "", "steve"))
	parseResponse(t, w)

	// Mom joins.
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest("POST", "/gopher/games/1/join", "", "mom"))
	resp := parseResponse(t, w)

	if resp["result"] != "success" {
		t.Fatalf("Expected success, got: %v", resp)
	}

	// Mom now sees the game in her list.
	w = httptest.NewRecorder()
	games.HandleGames(w, authRequest("GET", "/gopher/games", "", "mom"))
	resp = parseResponse(t, w)

	gamesList := resp["games"].([]interface{})
	if len(gamesList) != 1 {
		t.Fatalf("Expected 1 game for mom, got %d", len(gamesList))
	}
	game := gamesList[0].(map[string]interface{})
	if game["player2_id"].(float64) != 2 {
		t.Fatalf("Expected player2_id=2, got %v", game["player2_id"])
	}
}

func TestJoinGameErrors(t *testing.T) {
	setupTestDB(t)

	// Steve creates a game.
	w := httptest.NewRecorder()
	games.HandleGames(w, authRequest("POST", "/gopher/games", "", "steve"))
	parseResponse(t, w)

	// Steve can't join his own game.
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest("POST", "/gopher/games/1/join", "", "steve"))
	resp := parseResponse(t, w)
	if resp["result"] != "error" {
		t.Fatalf("Expected error for self-join, got: %v", resp)
	}

	// Mom joins.
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest("POST", "/gopher/games/1/join", "", "mom"))
	parseResponse(t, w)

	// Can't join again (game is full).
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest("POST", "/gopher/games/1/join", "", "mom"))
	resp = parseResponse(t, w)
	if resp["result"] != "error" {
		t.Fatalf("Expected error for full game, got: %v", resp)
	}
}

func TestPostAndGetEvents(t *testing.T) {
	setupTestDB(t)

	// Steve creates a game.
	w := httptest.NewRecorder()
	games.HandleGames(w, authRequest("POST", "/gopher/games", "", "steve"))
	parseResponse(t, w)

	// Steve posts an event.
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest(
		"POST", "/gopher/games/1/events",
		`{"type":"ADVANCE_TURN"}`, "steve",
	))
	resp := parseResponse(t, w)
	if resp["result"] != "success" {
		t.Fatalf("Expected success, got: %v", resp)
	}
	if resp["event_id"].(float64) != 1 {
		t.Fatalf("Expected event_id=1, got %v", resp["event_id"])
	}

	// Steve posts another event.
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest(
		"POST", "/gopher/games/1/events",
		`{"type":"PLAYER_ACTION","data":"test"}`, "steve",
	))
	parseResponse(t, w)

	// Get all events.
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest("GET", "/gopher/games/1/events", "", "steve"))
	resp = parseResponse(t, w)

	events := resp["events"].([]interface{})
	if len(events) != 2 {
		t.Fatalf("Expected 2 events, got %d", len(events))
	}

	// Get events after the first one.
	w = httptest.NewRecorder()
	req := authRequest("GET", "/gopher/games/1/events?after=1", "", "steve")
	games.HandleGameSub(w, req)
	resp = parseResponse(t, w)

	events = resp["events"].([]interface{})
	if len(events) != 1 {
		t.Fatalf("Expected 1 event after=1, got %d", len(events))
	}

	event := events[0].(map[string]interface{})
	if event["user_id"].(float64) != 1 {
		t.Fatalf("Expected user_id=1, got %v", event["user_id"])
	}
	payload := event["payload"].(map[string]interface{})
	if payload["type"] != "PLAYER_ACTION" {
		t.Fatalf("Expected PLAYER_ACTION, got %v", payload["type"])
	}
}

func TestEventAccessControl(t *testing.T) {
	setupTestDB(t)

	// Steve creates a game.
	w := httptest.NewRecorder()
	games.HandleGames(w, authRequest("POST", "/gopher/games", "", "steve"))
	parseResponse(t, w)

	// Mom can't post events (not in the game yet).
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest(
		"POST", "/gopher/games/1/events",
		`{"type":"ADVANCE_TURN"}`, "mom",
	))
	resp := parseResponse(t, w)
	if resp["result"] != "error" {
		t.Fatalf("Expected error for non-player, got: %v", resp)
	}

	// Mom can't read events either.
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest("GET", "/gopher/games/1/events", "", "mom"))
	resp = parseResponse(t, w)
	if resp["result"] != "error" {
		t.Fatalf("Expected error for non-player read, got: %v", resp)
	}

	// Mom joins, now she can.
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest("POST", "/gopher/games/1/join", "", "mom"))
	parseResponse(t, w)

	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest("GET", "/gopher/games/1/events", "", "mom"))
	resp = parseResponse(t, w)
	if resp["result"] != "success" {
		t.Fatalf("Expected success after join, got: %v", resp)
	}
}
