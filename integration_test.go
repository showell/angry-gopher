// Full-stack integration tests: real HTTP requests against a live
// httptest.Server, exercising auth, event delivery, rate limiting,
// and concurrent message sending.
//
// Fast tests (run on every checkin):
//   go test ./...
//
// Slow/stress tests (run periodically):
//   go test -run TestStress -timeout 120s ./...
//
// Configure stress test scale:
//   STRESS_MESSAGES=500 go test -run TestStress -timeout 300s ./...
//
// See EVENTS.md for how the event system works.

package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"angry-gopher/ratelimit"
)

// --- Test users (must match seedData) ---

type testUser struct {
	name   string
	email  string
	apiKey string
}

var testUsers = []testUser{
	{"Steve", "steve@example.com", "steve-api-key"},
	{"Apoorva", "apoorva@example.com", "apoorva-api-key"},
	{"Claude", "claude@example.com", "claude-api-key"},
	{"Joe", "joe@example.com", "joe-api-key"},
}

// --- HTTP helpers ---

// authHeader builds the HTTP Basic auth header that the withCORS
// middleware extracts to identify the user.
func authHeader(u testUser) string {
	return "Basic " + base64.StdEncoding.EncodeToString(
		[]byte(u.email + ":" + u.apiKey))
}

// httpPost sends a form-encoded POST as the given user.
func httpPost(baseURL, path string, u testUser, params url.Values) map[string]interface{} {
	req, _ := http.NewRequest("POST", baseURL+path,
		strings.NewReader(params.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Authorization", authHeader(u))

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return map[string]interface{}{"result": "error", "msg": err.Error()}
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()

	var result map[string]interface{}
	json.Unmarshal(body, &result)
	return result
}

// httpGet sends an authenticated GET with a short timeout. The timeout
// prevents tests from blocking on the 50-second long-poll when there
// are no events waiting.
func httpGet(baseURL, path string, u testUser) map[string]interface{} {
	req, _ := http.NewRequest("GET", baseURL+path, nil)
	req.Header.Set("Authorization", authHeader(u))

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil // timeout — no events arrived
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()

	var result map[string]interface{}
	json.Unmarshal(body, &result)
	return result
}

// --- Server setup ---

// startServerInMemory creates a fresh in-memory DB, wires up all
// packages, seeds users and channels, and returns a running server.
// Used by fast tests that don't need file-based persistence.
func startServerInMemory(t *testing.T) *httptest.Server {
	t.Helper()
	resetDB()
	seedData(false)

	origMax := ratelimit.MaxRequests
	ratelimit.MaxRequests = 10000
	t.Cleanup(func() { ratelimit.MaxRequests = origMax })

	return httptest.NewServer(buildMux())
}

// startServerWithFile creates a file-based SQLite DB at the given
// path, mimicking production. The file is cleaned up after the test.
// Used by stress tests to exercise the real persistence path.
func startServerWithFile(t *testing.T, dbPath string) *httptest.Server {
	t.Helper()

	os.Setenv("GOPHER_RESET_DB", "1")
	defer os.Unsetenv("GOPHER_RESET_DB")

	initDB(dbPath)
	wireDB()
	seedData(false)

	origMax := ratelimit.MaxRequests
	ratelimit.MaxRequests = 10000
	t.Cleanup(func() {
		ratelimit.MaxRequests = origMax
		os.Remove(dbPath)
	})

	return httptest.NewServer(buildMux())
}

// --- Helper ---

func countMessageEvents(result map[string]interface{}) int {
	events := result["events"].([]interface{})
	count := 0
	for _, e := range events {
		if e.(map[string]interface{})["type"] == "message" {
			count++
		}
	}
	return count
}

// ============================================================
// FAST TESTS — run on every checkin
// ============================================================

// Test: 4 users each register a queue, send 1 message to a public
// channel. Because event delivery is synchronous (see EVENTS.md),
// all events are in every queue by the time the sends complete.
// Each user polls once and should see all 4.
func TestIntegration_BasicMessaging(t *testing.T) {
	server := startServerInMemory(t)
	defer server.Close()

	queueIDs := make([]string, len(testUsers))
	for i, u := range testUsers {
		result := httpPost(server.URL, "/api/v1/register", u, url.Values{})
		if result["result"] != "success" {
			t.Fatalf("[%s] register: %v", u.name, result)
		}
		queueIDs[i] = result["queue_id"].(string)
	}

	// PushFiltered delivers each event to all queues synchronously.
	for _, u := range testUsers {
		result := httpPost(server.URL, "/api/v1/messages", u, url.Values{
			"to":      {"3"},
			"topic":   {"test"},
			"content": {fmt.Sprintf("hello from %s", u.name)},
			"type":    {"stream"},
		})
		if result["result"] != "success" {
			t.Fatalf("[%s] send: %v", u.name, result)
		}
	}

	for i, u := range testUsers {
		path := fmt.Sprintf("/api/v1/events?queue_id=%s&last_event_id=-1",
			queueIDs[i])
		result := httpGet(server.URL, path, u)
		if result == nil {
			t.Errorf("[%s] poll timed out", u.name)
			continue
		}

		msgCount := countMessageEvents(result)
		if msgCount != 4 {
			t.Errorf("[%s] received %d message events, expected 4", u.name, msgCount)
		}
	}
}

// Test: rapid sends trigger 429, then succeed after the sliding
// window expires. Event polling is exempt (see EVENTS.md).
func TestIntegration_RateLimiting(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping slow rate limiting test")
	}
	server := startServerInMemory(t)
	defer server.Close()

	origMax := ratelimit.MaxRequests
	origWindow := ratelimit.Window
	ratelimit.MaxRequests = 3
	ratelimit.Window = 2 * time.Second
	defer func() {
		ratelimit.MaxRequests = origMax
		ratelimit.Window = origWindow
	}()

	u := testUsers[0]
	got429 := false

	for i := 0; i < 10; i++ {
		result := httpPost(server.URL, "/api/v1/messages", u, url.Values{
			"to":      {"3"},
			"topic":   {"rate test"},
			"content": {fmt.Sprintf("msg %d", i)},
			"type":    {"stream"},
		})
		if result["msg"] == "Rate limit exceeded" {
			got429 = true
			break
		}
	}

	if !got429 {
		t.Error("expected 429 rate limit, but all requests succeeded")
	}

	time.Sleep(ratelimit.Window + 100*time.Millisecond)
	ratelimit.Reset()

	result := httpPost(server.URL, "/api/v1/messages", u, url.Values{
		"to":      {"3"},
		"topic":   {"rate test"},
		"content": {"after rate limit"},
		"type":    {"stream"},
	})
	if result["result"] != "success" {
		t.Errorf("expected success after rate limit expired, got %v", result)
	}
}

// ============================================================
// STRESS TESTS — run periodically, not on every checkin
//
//   go test -run TestStress -timeout 120s ./...
//
// Configure scale via environment variable:
//   STRESS_MESSAGES=500 go test -run TestStress -timeout 300s ./...
//
// Uses a file-based SQLite DB to match the production persistence
// path, ensuring we test the same I/O characteristics.
// ============================================================

func getStressMessageCount() int {
	if s := os.Getenv("STRESS_MESSAGES"); s != "" {
		n, err := strconv.Atoi(s)
		if err == nil && n > 0 {
			return n
		}
	}
	return 25 // default
}

// Test: 4 users send N messages concurrently to the same channel.
// Verifies the DB has the correct total and each user receives all
// events via a single poll. Uses a real file-based DB.
func TestStress_ConcurrentLoad(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping slow stress test")
	}
	messagesPerUser := getStressMessageCount()
	dbPath := "test_stress.db"

	server := startServerWithFile(t, dbPath)
	defer server.Close()

	t.Logf("Stress test: %d messages per user, %d users, %d total",
		messagesPerUser, len(testUsers), messagesPerUser*len(testUsers))

	// Register a queue for each user before the sends start.
	queueIDs := make([]string, len(testUsers))
	for i, u := range testUsers {
		result := httpPost(server.URL, "/api/v1/register", u, url.Values{})
		if result["result"] != "success" {
			t.Fatalf("[%s] register: %v", u.name, result)
		}
		queueIDs[i] = result["queue_id"].(string)
	}

	// All 4 users send concurrently. With the transaction-based
	// SendMessage, all writes should succeed — zero errors.
	var wg sync.WaitGroup
	for _, u := range testUsers {
		wg.Add(1)
		go func(user testUser) {
			defer wg.Done()
			for j := 0; j < messagesPerUser; j++ {
				result := httpPost(server.URL, "/api/v1/messages", user, url.Values{
					"to":      {"3"},
					"topic":   {"stress"},
					"content": {fmt.Sprintf("%s msg %d", user.name, j)},
					"type":    {"stream"},
				})
				if result["result"] != "success" {
					t.Errorf("[%s] send error on msg %d: %v", user.name, j, result["msg"])
				}
			}
		}(u)
	}
	wg.Wait()

	// Verify the database has the exact expected total.
	expectedTotal := len(testUsers) * messagesPerUser
	var dbCount int
	DB.QueryRow(`SELECT COUNT(*) FROM messages WHERE channel_id = 3`).Scan(&dbCount)
	if dbCount != expectedTotal {
		t.Errorf("expected %d messages in DB, got %d", expectedTotal, dbCount)
	}
	t.Logf("DB count: %d (expected %d)", dbCount, expectedTotal)

	// Each user polls once. Because event delivery is synchronous
	// (PushFiltered runs inside each send handler), all events are
	// already in every queue.
	for i, u := range testUsers {
		path := fmt.Sprintf("/api/v1/events?queue_id=%s&last_event_id=-1",
			queueIDs[i])
		result := httpGet(server.URL, path, u)
		if result == nil {
			t.Errorf("[%s] poll timed out", u.name)
			continue
		}

		msgCount := countMessageEvents(result)
		if msgCount != expectedTotal {
			t.Errorf("[%s] received %d message events, expected %d",
				u.name, msgCount, expectedTotal)
		}
	}

	t.Logf("All %d events delivered to all %d users", expectedTotal, len(testUsers))
}
