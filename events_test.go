// Tests for the event queue system: register, long-poll, and event delivery.

package main

import (
	"net/http/httptest"
	"testing"

	"angry-gopher/events"
)

func TestEventRegisterReturnsQueueID(t *testing.T) {
	req := httptest.NewRequest("POST", "/api/v1/register", nil)
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
	// Register a queue.
	regReq := httptest.NewRequest("POST", "/api/v1/register", nil)
	regRec := httptest.NewRecorder()
	events.HandleRegister(regRec, regReq)
	regBody := parseJSON(t, regRec)
	queueID := regBody["queue_id"].(string)

	// Push an event.
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
