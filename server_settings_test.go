package main

import (
	"net/http/httptest"
	"testing"
)

func TestServerSettingsReturnsGeneration(t *testing.T) {
	resetDB()
	recordServerStart()

	req := httptest.NewRequest("GET", "/api/v1/server_settings", nil)
	rec := httptest.NewRecorder()
	handleServerSettings(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}
	gen, ok := body["generation"].(float64)
	if !ok || gen < 1 {
		t.Fatalf("expected generation >= 1, got %v", body["generation"])
	}
}

func TestServerSettingsNoAuthRequired(t *testing.T) {
	resetDB()
	recordServerStart()

	// No auth header — should still succeed.
	req := httptest.NewRequest("GET", "/api/v1/server_settings", nil)
	rec := httptest.NewRecorder()
	handleServerSettings(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success without auth, got %v", body)
	}
}

func TestServerGenerationIncrements(t *testing.T) {
	resetDB()

	recordServerStart()
	gen1 := currentGeneration

	recordServerStart()
	gen2 := currentGeneration

	if gen2 != gen1+1 {
		t.Fatalf("expected generation to increment: gen1=%d gen2=%d", gen1, gen2)
	}
}

func TestUserSessionRecorded(t *testing.T) {
	resetDB()
	recordServerStart()

	recordUserLogin(1) // Steve

	var count int
	DB.QueryRow(`SELECT COUNT(*) FROM user_sessions WHERE user_id = 1 AND generation = ?`,
		currentGeneration).Scan(&count)
	if count != 1 {
		t.Fatalf("expected 1 user session row, got %d", count)
	}
}
