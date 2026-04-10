// Tests for GET /api/v1/users and PATCH /api/v1/settings.

package main

import (
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"angry-gopher/users"
)

func TestHandleUsers(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("GET", "/api/v1/users", nil)
	rec := httptest.NewRecorder()
	users.HandleUsers(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}

	members := body["members"].([]interface{})
	if len(members) != 4 {
		t.Fatalf("expected 4 users, got %d", len(members))
	}

	for _, m := range members {
		user := m.(map[string]interface{})
		name := user["full_name"].(string)
		isAdmin := user["is_admin"].(bool)
		switch name {
		case "Steve Howell":
			if !isAdmin {
				t.Errorf("Steve should be admin")
			}
		case "Joe Random":
			if isAdmin {
				t.Errorf("Joe should not be admin")
			}
		}
	}
}

// patchSettings calls users.HandleUpdateSettings with a form
// body. Mirrors the helper pattern used elsewhere in the test
// suite (sendMessage, editMessage, etc.).
func patchSettings(t *testing.T, fullName string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{}
	form.Set("full_name", fullName)

	req := httptest.NewRequest("PATCH", "/api/v1/settings", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)

	rec := httptest.NewRecorder()
	users.HandleUpdateSettings(rec, req)
	return rec
}

func TestUpdateSettingsFullName(t *testing.T) {
	resetDB()

	rec := patchSettings(t, "Stephen Howell")
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v (msg=%v)", body["result"], body["msg"])
	}
	if body["full_name"] != "Stephen Howell" {
		t.Errorf("expected echoed full_name, got %v", body["full_name"])
	}

	// Verify the update actually landed in the database.
	var stored string
	DB.QueryRow(`SELECT full_name FROM users WHERE id = 1`).Scan(&stored)
	if stored != "Stephen Howell" {
		t.Errorf("expected stored full_name=Stephen Howell, got %q", stored)
	}
}

func TestUpdateSettingsTrimsWhitespace(t *testing.T) {
	resetDB()

	patchSettings(t, "  Stevarino  ")

	var stored string
	DB.QueryRow(`SELECT full_name FROM users WHERE id = 1`).Scan(&stored)
	if stored != "Stevarino" {
		t.Errorf("expected trimmed full_name=Stevarino, got %q", stored)
	}
}

func TestUpdateSettingsRejectsEmpty(t *testing.T) {
	resetDB()

	rec := patchSettings(t, "   ")
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error, got %v", body["result"])
	}

	// Steve's name in the DB should be unchanged.
	var stored string
	DB.QueryRow(`SELECT full_name FROM users WHERE id = 1`).Scan(&stored)
	if stored != "Steve Howell" {
		t.Errorf("expected unchanged full_name=Steve Howell, got %q", stored)
	}
}

func TestUpdateSettingsRequiresAuth(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("full_name", "Hacker")

	req := httptest.NewRequest("PATCH", "/api/v1/settings", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	// No auth header.

	rec := httptest.NewRecorder()
	users.HandleUpdateSettings(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error from unauthenticated request, got %v", body["result"])
	}
}

func TestUpdateSettingsRejectsWrongMethod(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("full_name", "Stevarino")

	req := httptest.NewRequest("POST", "/api/v1/settings", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)

	rec := httptest.NewRecorder()
	users.HandleUpdateSettings(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error from POST, got %v", body["result"])
	}
}
