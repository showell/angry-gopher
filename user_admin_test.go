package main

import (
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"angry-gopher/users"
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

func TestDeactivateUserAsAdmin(t *testing.T) {
	resetDB()
	// Deactivate Joe (user 4).
	rec := adminPost(t, "/api/v1/users/4/deactivate", url.Values{})
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}

	// Joe should no longer be able to authenticate.
	req := httptest.NewRequest("GET", "/api/v1/users/me", nil)
	joeAuth(req)
	rec = httptest.NewRecorder()
	users.HandleGetOwnUser(rec, req)
	body = parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("deactivated user should not authenticate, got %v", body)
	}
}

func TestDeactivateUserNonAdminRejected(t *testing.T) {
	resetDB()
	rec := nonAdminPost(t, "/api/v1/users/1/deactivate", url.Values{})
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("non-admin should not deactivate users, got %v", body)
	}
}

func TestAdminCannotDeactivateSelf(t *testing.T) {
	resetDB()
	// Steve (user 1) tries to deactivate himself via admin endpoint.
	rec := adminPost(t, "/api/v1/users/1/deactivate", url.Values{})
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("admin should not deactivate self via admin endpoint, got %v", body)
	}
}

// --- Reactivate user ---

func TestReactivateUser(t *testing.T) {
	resetDB()
	// Deactivate then reactivate Joe.
	adminPost(t, "/api/v1/users/4/deactivate", url.Values{})
	rec := adminPost(t, "/api/v1/users/4/reactivate", url.Values{})
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}

	// Joe should be able to authenticate again.
	req := httptest.NewRequest("GET", "/api/v1/users/me", nil)
	joeAuth(req)
	rec = httptest.NewRecorder()
	users.HandleGetOwnUser(rec, req)
	body = parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("reactivated user should authenticate, got %v", body)
	}
}

func TestReactivateNonAdminRejected(t *testing.T) {
	resetDB()
	rec := nonAdminPost(t, "/api/v1/users/4/reactivate", url.Values{})
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("non-admin should not reactivate users, got %v", body)
	}
}

// --- Deactivate own account ---

func TestDeactivateOwnAccount(t *testing.T) {
	resetDB()
	// Joe deactivates himself.
	req := httptest.NewRequest("DELETE", "/api/v1/users/me", nil)
	joeAuth(req)
	rec := httptest.NewRecorder()
	users.HandleDeactivateOwnUser(rec, req)
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body)
	}

	// Joe should no longer authenticate.
	req = httptest.NewRequest("GET", "/api/v1/users/me", nil)
	joeAuth(req)
	rec = httptest.NewRecorder()
	users.HandleGetOwnUser(rec, req)
	body = parseJSON(t, rec)
	if body["result"] != "error" {
		t.Fatalf("self-deactivated user should not authenticate, got %v", body)
	}
}

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
