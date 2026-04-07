// Tests for HTTP Basic authentication.
// Verifies that valid credentials return the correct user ID and
// that invalid/missing/malformed credentials are rejected.

package main

import (
	"net/http/httptest"
	"testing"

	"angry-gopher/auth"
)

func TestAuthenticateValidCredentials(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("GET", "/", nil)
	steveAuth(req)
	if id := auth.Authenticate(req); id != 1 {
		t.Errorf("expected user ID 1 for Steve, got %d", id)
	}
}

func TestAuthenticateInvalidAPIKey(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("GET", "/", nil)
	setAuth(req, "steve@example.com", "wrong-key")
	if id := auth.Authenticate(req); id != 0 {
		t.Errorf("expected 0 for invalid API key, got %d", id)
	}
}

func TestAuthenticateMissingHeader(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("GET", "/", nil)
	if id := auth.Authenticate(req); id != 0 {
		t.Errorf("expected 0 for missing auth header, got %d", id)
	}
}

func TestAuthenticateMalformedBase64(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("Authorization", "Basic !!!not-base64!!!")
	if id := auth.Authenticate(req); id != 0 {
		t.Errorf("expected 0 for malformed base64, got %d", id)
	}
}
