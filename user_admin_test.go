package main

import (
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func adminPost(t *testing.T, path string, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("POST", path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req) // Steve is admin
	rec := httptest.NewRecorder()
	mux := buildMux()
	mux.ServeHTTP(rec, req)
	return rec
}

func nonAdminPost(t *testing.T, path string, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("POST", path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	joeAuth(req) // Joe is NOT admin
	rec := httptest.NewRecorder()
	mux := buildMux()
	mux.ServeHTTP(rec, req)
	return rec
}

// --- Create user ---

func TestCreateUserAsAdmin(t *testing.T) {
	resetDB()
	form := url.Values{"email": {"new@example.com"}, "full_name": {"New User"}}
	rec := adminPost(t, "/api/v1/users", form)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}
	if body["api_key"] == nil || body["api_key"] == "" {
		t.Fatal("expected api_key in response")
	}
}

func TestCreateUserNonAdminRejected(t *testing.T) {
	resetDB()
	form := url.Values{"email": {"hacker@example.com"}, "full_name": {"Hacker"}}
	rec := nonAdminPost(t, "/api/v1/users", form)
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("non-admin should not create users, got %v", body)
	}
}

func TestCreateUserDuplicateEmail(t *testing.T) {
	resetDB()
	form := url.Values{"email": {"steve@example.com"}, "full_name": {"Duplicate"}}
	rec := adminPost(t, "/api/v1/users", form)
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("duplicate email should fail, got %v", body)
	}
}

// --- Deactivate user ---

// --- Update user (admin) ---

func TestUpdateUserAsAdmin(t *testing.T) {
	resetDB()
	form := url.Values{"full_name": {"Joseph Random"}}
	req := httptest.NewRequest("PATCH", "/api/v1/users/4", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)
	rec := httptest.NewRecorder()
	mux := buildMux()
	mux.ServeHTTP(rec, req)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}

	// Verify the name changed.
	var name string
	DB.QueryRow(`SELECT full_name FROM users WHERE id = 4`).Scan(&name)
	if name != "Joseph Random" {
		t.Fatalf("expected 'Joseph Random', got %q", name)
	}
}

func TestUpdateUserNonAdminRejected(t *testing.T) {
	resetDB()
	form := url.Values{"full_name": {"Hacked Name"}}
	req := httptest.NewRequest("PATCH", "/api/v1/users/1", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	joeAuth(req)
	rec := httptest.NewRecorder()
	mux := buildMux()
	mux.ServeHTTP(rec, req)
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("non-admin should not update other users, got %v", body)
	}
}
