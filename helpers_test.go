// Shared test infrastructure for all test files.
//
// All test files are in package main, so these helpers are available
// everywhere. Each test calls resetDB() to get a fresh in-memory
// SQLite database seeded with users.

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"angry-gopher/ratelimit"
)

// resetDB creates a fresh in-memory SQLite database and wires up
// all package-level DB references. Each call gives us a brand new
// database with empty tables, so tests are fully isolated.
func resetDB() {
	initDB(":memory:")
	wireDB()
	ratelimit.Reset()
	seedData(false)
}

// --- Auth helpers ---

func setAuth(req *http.Request, nameOrEmail string, _ ...string) {
	name := nameOrEmail
	if at := strings.Index(nameOrEmail, "@"); at > 0 {
		slug := nameOrEmail[:at]
		switch slug {
		case "steve":
			name = "Steve"
		case "claude":
			name = "Claude"
		default:
			name = "Claude"
		}
	}
	req.Header.Set("X-Gopher-User", name)
}

func steveAuth(req *http.Request)  { setAuth(req, "Steve") }
func claudeAuth(req *http.Request) { setAuth(req, "Claude") }
func joeAuth(req *http.Request)    { setAuth(req, "Claude") }

// --- Response helpers ---

func parseJSON(t *testing.T, rec *httptest.ResponseRecorder) map[string]interface{} {
	t.Helper()
	var result map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil {
		t.Fatalf("failed to parse JSON response: %v", err)
	}
	return result
}
