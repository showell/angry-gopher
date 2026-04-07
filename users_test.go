// Tests for GET /api/v1/users.

package main

import (
	"net/http/httptest"
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
