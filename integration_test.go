// Full-stack integration tests: real HTTP requests against a live
// httptest.Server, exercising auth, event delivery, rate limiting,
// and concurrent message sending.
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

// startServer creates a fresh in-memory DB, wires up all packages,
// seeds users and channels (no test messages), and returns a running
// httptest.Server backed by buildMux().
func startServer(t *testing.T) *httptest.Server {
	t.Helper()
	resetDB()
	seedData(false)

	// Effectively disable rate limiting for most tests so they run
	// fast. The rate limiting test overrides this.
	origMax := ratelimit.MaxRequests
	ratelimit.MaxRequests = 10000
	t.Cleanup(func() { ratelimit.MaxRequests = origMax })

	return httptest.NewServer(buildMux())
}

// --- Helper: count message events in a poll response ---

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
// Test 1: Basic event delivery.
//
// 4 users each register a queue, then each sends 1 message to
// a public channel. Because event delivery is synchronous (see
// EVENTS.md), all events are in every queue by the time the
// sends complete. Each user polls once and should see all 4.
// ============================================================

func TestIntegration_BasicMessaging(t *testing.T) {
	server := startServer(t)
	defer server.Close()

	// Step 1: Each user registers an event queue.
	queueIDs := make([]string, len(testUsers))
	for i, u := range testUsers {
		result := httpPost(server.URL, "/api/v1/register", u, url.Values{})
		if result["result"] != "success" {
			t.Fatalf("[%s] register: %v", u.name, result)
		}
		queueIDs[i] = result["queue_id"].(string)
	}

	// Step 2: Each user sends 1 message to ChitChat (channel 3, public).
	// PushFiltered delivers each event to all queues synchronously,
	// so by the time this loop finishes, every queue has 4 events.
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

	// Step 3: Each user long-polls. Since events were delivered
	// synchronously during the sends above, the poll returns
	// immediately with all pending events — no waiting needed.
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

// ============================================================
// Test 2: Rate limiting.
//
// With a very low limit (3 requests per 2-second window), rapid
// sends trigger 429 responses. After the window expires, normal
// service resumes. Note: event polling is exempt from rate
// limiting (see EVENTS.md — it's a passive listener).
// ============================================================

func TestIntegration_RateLimiting(t *testing.T) {
	server := startServer(t)
	defer server.Close()

	// Override: 3 requests per 2-second sliding window.
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

	// Send messages as fast as possible. The first 3 succeed; the
	// 4th should get 429 Too Many Requests.
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

	// Wait for the sliding window to expire, then verify that
	// normal service resumes.
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
// Test 3: Concurrent message sending.
//
// 4 users each send 10 messages concurrently to the same channel.
// The single-connection SQLite DB serializes all writes, so this
// tests that concurrent HTTP requests don't corrupt state.
//
// Because all sends complete before we poll, and event delivery
// is synchronous, a single poll per user retrieves all 40 events.
// ============================================================

func TestIntegration_ConcurrentLoad(t *testing.T) {
	server := startServer(t)
	defer server.Close()

	const messagesPerUser = 10

	// Register a queue for each user before the sends start.
	queueIDs := make([]string, len(testUsers))
	for i, u := range testUsers {
		result := httpPost(server.URL, "/api/v1/register", u, url.Values{})
		queueIDs[i] = result["queue_id"].(string)
	}

	// All 4 users send concurrently. Each goroutine sends 10 messages.
	var wg sync.WaitGroup
	for _, u := range testUsers {
		wg.Add(1)
		go func(user testUser) {
			defer wg.Done()
			for j := 0; j < messagesPerUser; j++ {
				httpPost(server.URL, "/api/v1/messages", user, url.Values{
					"to":      {"3"},
					"topic":   {"concurrent"},
					"content": {fmt.Sprintf("%s msg %d", user.name, j)},
					"type":    {"stream"},
				})
			}
		}(u)
	}
	wg.Wait()

	// Verify the database has the expected total. Since SQLite
	// serializes writes via SetMaxOpenConns(1), no messages are
	// lost even under concurrent load.
	expectedTotal := len(testUsers) * messagesPerUser
	var dbCount int
	DB.QueryRow(`SELECT COUNT(*) FROM messages WHERE channel_id = 3`).Scan(&dbCount)
	if dbCount != expectedTotal {
		t.Errorf("expected %d messages in DB, got %d", expectedTotal, dbCount)
	}

	// Each user polls once. Because event delivery is synchronous
	// (PushFiltered runs inside each send handler), all 40 events
	// are already in every queue by the time we get here.
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
}
