package main

import (
	"bytes"
	"net/http/httptest"
	"testing"

	"angry-gopher/buddies"
	"angry-gopher/events"
)

func putBuddies(t *testing.T, email, apiKey, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("PUT", "/api/v1/buddies", bytes.NewReader([]byte(body)))
	req.Header.Set("Content-Type", "application/json")
	setAuth(req, email, apiKey)
	rec := httptest.NewRecorder()
	buddies.HandleBuddies(rec, req)
	return rec
}

func getBuddies(t *testing.T, email, apiKey string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/v1/buddies", nil)
	setAuth(req, email, apiKey)
	rec := httptest.NewRecorder()
	buddies.HandleBuddies(rec, req)
	return rec
}

func buddyIDs(t *testing.T, rec *httptest.ResponseRecorder) []int {
	t.Helper()
	body := parseJSON(t, rec)
	raw := body["ids"].([]interface{})
	ids := make([]int, len(raw))
	for i, v := range raw {
		ids[i] = int(v.(float64))
	}
	return ids
}

func TestBuddiesBasicRoundtrip(t *testing.T) {
	resetDB()

	// Steve starts with no buddies.
	rec := getBuddies(t, "steve@example.com", "steve-api-key")
	ids := buddyIDs(t, rec)
	if len(ids) != 0 {
		t.Fatalf("expected empty buddy list, got %v", ids)
	}

	// Steve sets buddies to [2, 3].
	rec = putBuddies(t, "steve@example.com", "steve-api-key", `{"ids": [2, 3]}`)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}

	// Steve reads back [2, 3].
	rec = getBuddies(t, "steve@example.com", "steve-api-key")
	ids = buddyIDs(t, rec)
	if len(ids) != 2 {
		t.Fatalf("expected 2 buddies, got %v", ids)
	}
}

func TestBuddiesPutReplaces(t *testing.T) {
	resetDB()

	// Steve sets [2, 3], then replaces with [4].
	putBuddies(t, "steve@example.com", "steve-api-key", `{"ids": [2, 3]}`)
	putBuddies(t, "steve@example.com", "steve-api-key", `{"ids": [4]}`)

	rec := getBuddies(t, "steve@example.com", "steve-api-key")
	ids := buddyIDs(t, rec)
	if len(ids) != 1 || ids[0] != 4 {
		t.Fatalf("expected [4], got %v", ids)
	}
}

func TestBuddiesPutEmptyClears(t *testing.T) {
	resetDB()

	putBuddies(t, "steve@example.com", "steve-api-key", `{"ids": [2, 3]}`)
	putBuddies(t, "steve@example.com", "steve-api-key", `{"ids": []}`)

	rec := getBuddies(t, "steve@example.com", "steve-api-key")
	ids := buddyIDs(t, rec)
	if len(ids) != 0 {
		t.Fatalf("expected empty after clear, got %v", ids)
	}
}

func TestBuddiesPrivacy(t *testing.T) {
	resetDB()

	// Steve sets his buddies.
	putBuddies(t, "steve@example.com", "steve-api-key", `{"ids": [2, 3]}`)

	// Joe's buddy list is independent — should be empty.
	rec := getBuddies(t, "joe@example.com", "joe-api-key")
	ids := buddyIDs(t, rec)
	if len(ids) != 0 {
		t.Fatalf("Joe should not see Steve's buddies, got %v", ids)
	}

	// Joe sets his own buddies.
	putBuddies(t, "joe@example.com", "joe-api-key", `{"ids": [1]}`)

	// Steve's list is unchanged.
	rec = getBuddies(t, "steve@example.com", "steve-api-key")
	ids = buddyIDs(t, rec)
	if len(ids) != 2 {
		t.Fatalf("Steve's buddies should be unchanged, got %v", ids)
	}

	// Joe sees only his own.
	rec = getBuddies(t, "joe@example.com", "joe-api-key")
	ids = buddyIDs(t, rec)
	if len(ids) != 1 || ids[0] != 1 {
		t.Fatalf("Joe should see [1], got %v", ids)
	}
}

func TestBuddiesRequiresAuth(t *testing.T) {
	resetDB()

	// No auth header.
	req := httptest.NewRequest("GET", "/api/v1/buddies", nil)
	rec := httptest.NewRecorder()
	buddies.HandleBuddies(rec, req)
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("expected error without auth, got %v", body)
	}
}

func TestBuddiesNoEventLeakage(t *testing.T) {
	resetDB()
	events.Reset()

	// Register a queue for Joe (user 4).
	req := httptest.NewRequest("POST", "/api/v1/register", nil)
	joeAuth(req)
	rec := httptest.NewRecorder()
	events.HandleRegister(rec, req)
	regBody := parseJSON(t, rec)
	if regBody["result"] != "success" {
		t.Fatalf("failed to register queue: %v", regBody)
	}

	// Steve updates his buddy list. This should NOT push any events.
	putBuddies(t, "steve@example.com", "steve-api-key", `{"ids": [2, 3, 4]}`)

	// Check Joe's queue — should have zero pending events.
	stats := events.Stats()
	for _, q := range stats {
		if q.EventCount > 0 {
			t.Fatalf("queue %s has %d events after buddy update — buddy data is leaking into event queues",
				q.ID, q.EventCount)
		}
	}
}
