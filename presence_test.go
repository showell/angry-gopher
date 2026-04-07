// Tests for user presence tracking.

package main

import (
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"angry-gopher/presence"
)

func sendPresence(t *testing.T, email, apiKey string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{}
	form.Set("status", "active")

	req := httptest.NewRequest("POST", "/api/v1/users/me/presence", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	setAuth(req, email, apiKey)
	rec := httptest.NewRecorder()
	presence.HandleUpdatePresence(rec, req)
	return rec
}

func getPresence(t *testing.T) map[string]interface{} {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/v1/users/me/presence", nil)
	rec := httptest.NewRecorder()
	presence.HandleGetPresence(rec, req)
	return parseJSON(t, rec)
}

func TestSendAndGetPresence(t *testing.T) {
	resetDB()

	rec := sendPresence(t, "steve@example.com", "steve-api-key")
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}

	data := getPresence(t)
	presences := data["presences"].(map[string]interface{})

	stevePresence, ok := presences["1"].(map[string]interface{})
	if !ok {
		t.Fatal("expected Steve's presence in response")
	}
	if stevePresence["status"] != "active" {
		t.Errorf("expected active, got %v", stevePresence["status"])
	}
}

func TestPresenceRequiresAuth(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("status", "active")
	req := httptest.NewRequest("POST", "/api/v1/users/me/presence", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	presence.HandleUpdatePresence(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for unauthenticated presence, got %v", body["result"])
	}
}

func TestPresenceMultipleUsers(t *testing.T) {
	resetDB()

	sendPresence(t, "steve@example.com", "steve-api-key")
	sendPresence(t, "claude@example.com", "claude-api-key")

	data := getPresence(t)
	presences := data["presences"].(map[string]interface{})

	if len(presences) != 2 {
		t.Fatalf("expected 2 presences, got %d", len(presences))
	}
}
