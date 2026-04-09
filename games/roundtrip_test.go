package games_test

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"angry-gopher/games"
)

// TestFullRoundTrip simulates a complete two-player game session:
// Steve creates a game, posts an event, Mom joins, posts an event,
// then both players poll for events and see only the other's.
func TestFullRoundTrip(t *testing.T) {
	setupTestDB(t)

	// Steve creates a game.
	w := httptest.NewRecorder()
	games.HandleGames(w, authRequest("POST", "/gopher/games", "", "steve"))
	resp := parseResponse(t, w)
	assertSuccess(t, resp)
	gameID := int(resp["game_id"].(float64))

	// Steve posts a game event (opaque JSON — Gopher doesn't care what's inside).
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest(
		"POST", "/gopher/games/1/events",
		`{"json_game_event":{"type":"PLAYER_ACTION"},"addr":"1"}`,
		"steve",
	))
	resp = parseResponse(t, w)
	assertSuccess(t, resp)
	steveEventID := int(resp["event_id"].(float64))

	// Mom joins the game.
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest("POST", "/gopher/games/1/join", "", "mom"))
	resp = parseResponse(t, w)
	assertSuccess(t, resp)

	// Mom posts a game event.
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest(
		"POST", "/gopher/games/1/events",
		`{"json_game_event":{"type":"ADVANCE_TURN"},"addr":"2"}`,
		"mom",
	))
	resp = parseResponse(t, w)
	assertSuccess(t, resp)

	// Steve polls for events after his own — should see Mom's event only.
	w = httptest.NewRecorder()
	req := authRequest("GET", "/gopher/games/1/events?after="+itoa(steveEventID), "", "steve")
	games.HandleGameSub(w, req)
	resp = parseResponse(t, w)
	assertSuccess(t, resp)

	events := resp["events"].([]interface{})
	if len(events) != 1 {
		t.Fatalf("Steve should see 1 new event, got %d", len(events))
	}
	momEvent := events[0].(map[string]interface{})
	if int(momEvent["user_id"].(float64)) != 2 {
		t.Fatalf("Expected Mom's user_id=2, got %v", momEvent["user_id"])
	}

	// The payload should be the exact JSON Mom posted.
	payload := momEvent["payload"].(map[string]interface{})
	inner := payload["json_game_event"].(map[string]interface{})
	if inner["type"] != "ADVANCE_TURN" {
		t.Fatalf("Expected ADVANCE_TURN, got %v", inner["type"])
	}

	// Mom polls from the beginning — should see both events.
	w = httptest.NewRecorder()
	games.HandleGameSub(w, authRequest("GET", "/gopher/games/1/events?after=0", "", "mom"))
	resp = parseResponse(t, w)
	events = resp["events"].([]interface{})
	if len(events) != 2 {
		t.Fatalf("Mom should see 2 total events, got %d", len(events))
	}

	// The game list should show both players and the event count.
	w = httptest.NewRecorder()
	games.HandleGames(w, authRequest("GET", "/gopher/games", "", "steve"))
	resp = parseResponse(t, w)
	gamesList := resp["games"].([]interface{})
	game := gamesList[0].(map[string]interface{})

	if int(game["id"].(float64)) != gameID {
		t.Fatalf("Expected game_id=%d, got %v", gameID, game["id"])
	}
	if int(game["event_count"].(float64)) != 2 {
		t.Fatalf("Expected event_count=2, got %v", game["event_count"])
	}
	if game["player2_id"] == nil {
		t.Fatal("Expected player2_id to be set after Mom joined")
	}

	_ = json.Marshal // keep import
}

func assertSuccess(t *testing.T, resp map[string]interface{}) {
	t.Helper()
	if resp["result"] != "success" {
		t.Fatalf("Expected success, got: %v", resp)
	}
}

func itoa(n int) string {
	return json.Number(json.Number(string(rune('0' + n)))).String()
}
