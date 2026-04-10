// Tests for the event queue system: register, long-poll, and event delivery.

package main

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"

	"angry-gopher/events"
)

func TestEventRegisterReturnsQueueID(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("POST", "/api/v1/register", nil)
	steveAuth(req)
	rec := httptest.NewRecorder()
	events.HandleRegister(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}
	queueID, ok := body["queue_id"].(string)
	if !ok || queueID == "" {
		t.Fatal("expected non-empty queue_id")
	}
	if body["last_event_id"] != float64(-1) {
		t.Errorf("expected last_event_id=-1, got %v", body["last_event_id"])
	}
}

func TestEventRegisterRequiresAuth(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("POST", "/api/v1/register", nil)
	rec := httptest.NewRecorder()
	events.HandleRegister(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for unauthenticated register, got %v", body["result"])
	}
}

func TestEventPollBadQueue(t *testing.T) {
	req := httptest.NewRequest("GET", "/api/v1/events?queue_id=nonexistent&last_event_id=-1", nil)
	rec := httptest.NewRecorder()
	events.HandleEvents(rec, req)

	body := parseJSON(t, rec)
	if body["code"] != "BAD_EVENT_QUEUE_ID" {
		t.Errorf("expected BAD_EVENT_QUEUE_ID, got %v", body["code"])
	}
}

func TestEventPollReceivesEvents(t *testing.T) {
	resetDB()

	// Register a queue as Steve.
	regReq := httptest.NewRequest("POST", "/api/v1/register", nil)
	steveAuth(regReq)
	regRec := httptest.NewRecorder()
	events.HandleRegister(regRec, regReq)
	regBody := parseJSON(t, regRec)
	queueID := regBody["queue_id"].(string)

	// Push an event to all queues.
	events.PushToAll(map[string]interface{}{
		"type": "test_event",
	})

	// Poll — should receive the event.
	pollReq := httptest.NewRequest("GET",
		"/api/v1/events?queue_id="+queueID+"&last_event_id=-1", nil)
	pollRec := httptest.NewRecorder()
	events.HandleEvents(pollRec, pollReq)

	body := parseJSON(t, pollRec)
	evts := body["events"].([]interface{})
	found := false
	for _, e := range evts {
		evt := e.(map[string]interface{})
		if evt["type"] == "test_event" {
			found = true
		}
	}
	if !found {
		t.Errorf("expected to find test_event in poll response, got %v", evts)
	}
}

// registerQueue is a test helper that registers an event queue for a
// user and returns the queue_id.
func registerQueue(t *testing.T, authFn func(*http.Request)) string {
	t.Helper()
	req := httptest.NewRequest("POST", "/api/v1/register", nil)
	authFn(req)
	rec := httptest.NewRecorder()
	events.HandleRegister(rec, req)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("register failed: %v", body)
	}
	return body["queue_id"].(string)
}

// pollEvents is a test helper that polls the event queue and returns
// the parsed events array.
func pollEvents(t *testing.T, queueID string, lastEventID int) []map[string]interface{} {
	t.Helper()
	path := "/api/v1/events?queue_id=" + queueID + "&last_event_id=" + strconv.Itoa(lastEventID)
	req := httptest.NewRequest("GET", path, nil)
	rec := httptest.NewRecorder()
	events.HandleEvents(rec, req)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("poll failed: %v", body)
	}
	raw, ok := body["events"].([]interface{})
	if !ok {
		return nil
	}
	result := make([]map[string]interface{}, len(raw))
	for i, e := range raw {
		result[i] = e.(map[string]interface{})
	}
	return result
}

// No heartbeat fabrication: polling with no pending events should
// return an empty array, not a synthetic heartbeat. Fabricated
// heartbeats used lastEventID+1 as their ID, which collided with
// the next real event's auto-increment ID and caused it to be
// silently skipped.
func TestEventPollNoHeartbeat(t *testing.T) {
	resetDB()
	queueID := registerQueue(t, steveAuth)

	// Push one event so we can advance past it, then poll again
	// with nothing pending.
	events.PushToAll(map[string]interface{}{"type": "setup"})
	evts := pollEvents(t, queueID, -1)
	if len(evts) != 1 {
		t.Fatalf("expected 1 event, got %d", len(evts))
	}
	lastID := int(evts[0]["id"].(float64))

	// Second poll: no new events. Should get empty array.
	evts = pollEvents(t, queueID, lastID)
	if len(evts) != 0 {
		t.Errorf("expected empty events, got %v", evts)
	}
}

// Event IDs within a queue are strictly sequential. Pushing three
// events should produce IDs 0, 1, 2.
func TestEventIDsAreSequential(t *testing.T) {
	resetDB()
	queueID := registerQueue(t, steveAuth)

	events.PushToAll(map[string]interface{}{"type": "a"})
	events.PushToAll(map[string]interface{}{"type": "b"})
	events.PushToAll(map[string]interface{}{"type": "c"})

	evts := pollEvents(t, queueID, -1)
	if len(evts) != 3 {
		t.Fatalf("expected 3 events, got %d", len(evts))
	}
	for i, evt := range evts {
		id := int(evt["id"].(float64))
		if id != i {
			t.Errorf("event %d: expected id=%d, got %d", i, i, id)
		}
	}
}

// Consecutive polls advance through events correctly. The client
// passes last_event_id from the previous batch to get only newer
// events — no gaps, no duplicates.
func TestEventPollAdvances(t *testing.T) {
	resetDB()
	queueID := registerQueue(t, steveAuth)

	events.PushToAll(map[string]interface{}{"type": "first"})
	evts := pollEvents(t, queueID, -1)
	if len(evts) != 1 || evts[0]["type"] != "first" {
		t.Fatalf("first poll: expected [first], got %v", evts)
	}
	lastID := int(evts[0]["id"].(float64))

	events.PushToAll(map[string]interface{}{"type": "second"})
	evts = pollEvents(t, queueID, lastID)
	if len(evts) != 1 || evts[0]["type"] != "second" {
		t.Fatalf("second poll: expected [second], got %v", evts)
	}
	lastID = int(evts[0]["id"].(float64))

	events.PushToAll(map[string]interface{}{"type": "third"})
	evts = pollEvents(t, queueID, lastID)
	if len(evts) != 1 || evts[0]["type"] != "third" {
		t.Fatalf("third poll: expected [third], got %v", evts)
	}
}

// PushFiltered delivers events only to queues whose owner passes
// the filter function.
func TestEventPushFiltered(t *testing.T) {
	resetDB()
	steveQueue := registerQueue(t, steveAuth)
	joeQueue := registerQueue(t, joeAuth)

	// Push a filtered event only to Steve (user_id=1), then push
	// a broadcast so Joe also has something pending. Without a
	// pending event, Joe's poll would block for the full 50s
	// long-poll timeout.
	events.PushFiltered(
		map[string]interface{}{"type": "private_thing"},
		func(userID int) bool { return userID == 1 },
	)
	events.PushToAll(map[string]interface{}{"type": "broadcast"})

	steveEvts := pollEvents(t, steveQueue, -1)
	joeEvts := pollEvents(t, joeQueue, -1)

	// Steve should have both: the filtered event and the broadcast.
	if len(steveEvts) != 2 {
		t.Fatalf("Steve: expected 2 events, got %d: %v", len(steveEvts), steveEvts)
	}
	if steveEvts[0]["type"] != "private_thing" {
		t.Errorf("Steve event 0: expected private_thing, got %v", steveEvts[0]["type"])
	}

	// Joe should have only the broadcast — the filtered event
	// should not have reached him.
	if len(joeEvts) != 1 {
		t.Fatalf("Joe: expected 1 event, got %d: %v", len(joeEvts), joeEvts)
	}
	if joeEvts[0]["type"] != "broadcast" {
		t.Errorf("Joe event 0: expected broadcast, got %v", joeEvts[0]["type"])
	}
}

// Each queue gets its own independent ID sequence. Two queues
// receiving the same PushToAll event both assign id=0 to their
// first event.
func TestEventIDsPerQueue(t *testing.T) {
	resetDB()
	steveQueue := registerQueue(t, steveAuth)

	// Push one event before Joe registers.
	events.PushToAll(map[string]interface{}{"type": "before_joe"})

	joeQueue := registerQueue(t, joeAuth)

	// Push another event to both.
	events.PushToAll(map[string]interface{}{"type": "after_joe"})

	steveEvts := pollEvents(t, steveQueue, -1)
	joeEvts := pollEvents(t, joeQueue, -1)

	// Steve should have events 0 and 1.
	if len(steveEvts) != 2 {
		t.Fatalf("Steve: expected 2 events, got %d", len(steveEvts))
	}
	if int(steveEvts[0]["id"].(float64)) != 0 || int(steveEvts[1]["id"].(float64)) != 1 {
		t.Errorf("Steve: expected ids [0,1], got [%v,%v]",
			steveEvts[0]["id"], steveEvts[1]["id"])
	}

	// Joe should have only event 0 (the one after he registered).
	if len(joeEvts) != 1 {
		t.Fatalf("Joe: expected 1 event, got %d", len(joeEvts))
	}
	if int(joeEvts[0]["id"].(float64)) != 0 {
		t.Errorf("Joe: expected id=0, got %v", joeEvts[0]["id"])
	}
}
