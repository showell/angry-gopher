// Games tests — using the main package's resetDB() and seedData()
// so all tests share the single source of authority for the schema.

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"angry-gopher/games"
)

func gameRequest(t *testing.T, method, path, body string, email, apiKey string) map[string]interface{} {
	t.Helper()
	var req *http.Request
	if body != "" {
		req = httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
	} else {
		req = httptest.NewRequest(method, path, nil)
	}
	setAuth(req, email, apiKey)
	rec := httptest.NewRecorder()
	switch {
	case method == "GET" && path == "/gopher/games",
		method == "POST" && path == "/gopher/games":
		games.HandleGames(rec, req)
	default:
		games.HandleGameSub(rec, req)
	}
	var result map[string]interface{}
	json.Unmarshal(rec.Body.Bytes(), &result)
	return result
}

func steveGame(t *testing.T, method, path, body string) map[string]interface{} {
	return gameRequest(t, method, path, body, "steve@example.com", "steve-api-key")
}

func joeGame(t *testing.T, method, path, body string) map[string]interface{} {
	return gameRequest(t, method, path, body, "joe@example.com", "joe-api-key")
}

func TestCreateAndListGame(t *testing.T) {
	resetDB()

	resp := steveGame(t, "POST", "/gopher/games", "")
	if resp["result"] != "success" {
		t.Fatalf("Expected success, got: %v", resp)
	}
	gameID := resp["game_id"].(float64)
	if gameID < 1 {
		t.Fatalf("Expected positive game_id, got %v", gameID)
	}

	resp = steveGame(t, "GET", "/gopher/games", "")
	gamesList := resp["games"].([]interface{})
	if len(gamesList) != 1 {
		t.Fatalf("Expected 1 game, got %d", len(gamesList))
	}

	// Joe sees the open game too.
	resp = joeGame(t, "GET", "/gopher/games", "")
	gamesList = resp["games"].([]interface{})
	if len(gamesList) != 1 {
		t.Fatalf("Expected 1 open game for Joe, got %d", len(gamesList))
	}
}

func TestCreatePuzzleGame(t *testing.T) {
	resetDB()

	resp := steveGame(t, "POST", "/gopher/games", `{"puzzle_name":"puzzle_24"}`)
	if resp["result"] != "success" {
		t.Fatalf("Expected success, got: %v", resp)
	}

	resp = steveGame(t, "GET", "/gopher/games", "")
	gamesList := resp["games"].([]interface{})
	game := gamesList[0].(map[string]interface{})
	if game["puzzle_name"] != "puzzle_24" {
		t.Fatalf("Expected puzzle_name=puzzle_24, got %v", game["puzzle_name"])
	}
}

func TestCreateGameEmptyBodyStillWorks(t *testing.T) {
	resetDB()

	resp := steveGame(t, "POST", "/gopher/games", `{}`)
	if resp["result"] != "success" {
		t.Fatalf("Expected success, got: %v", resp)
	}

	resp = steveGame(t, "GET", "/gopher/games", "")
	gamesList := resp["games"].([]interface{})
	game := gamesList[0].(map[string]interface{})
	if game["puzzle_name"] != nil {
		t.Fatalf("Expected puzzle_name=nil for empty body, got %v", game["puzzle_name"])
	}
}

func TestJoinGame(t *testing.T) {
	resetDB()

	steveGame(t, "POST", "/gopher/games", "")

	resp := joeGame(t, "POST", "/gopher/games/1/join", "")
	if resp["result"] != "success" {
		t.Fatalf("Expected success, got: %v", resp)
	}

	resp = joeGame(t, "GET", "/gopher/games", "")
	gamesList := resp["games"].([]interface{})
	if len(gamesList) != 1 {
		t.Fatalf("Expected 1 game for Joe, got %d", len(gamesList))
	}
	game := gamesList[0].(map[string]interface{})
	if game["player2_id"].(float64) != 4 { // Joe is user 4
		t.Fatalf("Expected player2_id=4, got %v", game["player2_id"])
	}
}

func TestJoinGameErrors(t *testing.T) {
	resetDB()
	steveGame(t, "POST", "/gopher/games", "")

	// Steve can't join his own game.
	resp := steveGame(t, "POST", "/gopher/games/1/join", "")
	if resp["result"] != "error" {
		t.Fatalf("Expected error for self-join, got: %v", resp)
	}

	// Joe joins.
	joeGame(t, "POST", "/gopher/games/1/join", "")

	// Can't join again (game is full).
	resp = joeGame(t, "POST", "/gopher/games/1/join", "")
	if resp["result"] != "error" {
		t.Fatalf("Expected error for full game, got: %v", resp)
	}
}

func TestPostAndGetEvents(t *testing.T) {
	resetDB()
	steveGame(t, "POST", "/gopher/games", "")

	resp := steveGame(t, "POST", "/gopher/games/1/events", `{"type":"ADVANCE_TURN"}`)
	if resp["result"] != "success" {
		t.Fatalf("Expected success, got: %v", resp)
	}

	steveGame(t, "POST", "/gopher/games/1/events", `{"type":"PLAYER_ACTION","data":"test"}`)

	resp = steveGame(t, "GET", "/gopher/games/1/events", "")
	events := resp["events"].([]interface{})
	if len(events) != 2 {
		t.Fatalf("Expected 2 events, got %d", len(events))
	}

	resp = steveGame(t, "GET", "/gopher/games/1/events?after=1", "")
	events = resp["events"].([]interface{})
	if len(events) != 1 {
		t.Fatalf("Expected 1 event after=1, got %d", len(events))
	}
}

func TestEventAccessControl(t *testing.T) {
	resetDB()
	steveGame(t, "POST", "/gopher/games", "")

	// Joe can't post events (not in the game yet).
	resp := joeGame(t, "POST", "/gopher/games/1/events", `{"type":"ADVANCE_TURN"}`)
	if resp["result"] != "error" {
		t.Fatalf("Expected error for non-player, got: %v", resp)
	}

	// Joe can't read events either.
	resp = joeGame(t, "GET", "/gopher/games/1/events", "")
	if resp["result"] != "error" {
		t.Fatalf("Expected error for non-player read, got: %v", resp)
	}

	// Joe joins, now he can.
	joeGame(t, "POST", "/gopher/games/1/join", "")

	resp = joeGame(t, "GET", "/gopher/games/1/events", "")
	if resp["result"] != "success" {
		t.Fatalf("Expected success after join, got: %v", resp)
	}
}

func TestFullRoundTrip(t *testing.T) {
	resetDB()

	steveGame(t, "POST", "/gopher/games", "")
	joeGame(t, "POST", "/gopher/games/1/join", "")
	steveGame(t, "POST", "/gopher/games/1/events", `{"type":"MOVE","x":1}`)
	joeGame(t, "POST", "/gopher/games/1/events", `{"type":"MOVE","x":2}`)

	resp := steveGame(t, "GET", "/gopher/games/1/events", "")
	events := resp["events"].([]interface{})
	if len(events) != 2 {
		t.Fatalf("Expected 2 events, got %d", len(events))
	}
}
