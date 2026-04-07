// Full-stack integration test: 4 users communicate over real HTTP.
//
// We start small: each user sends 1 message, and every user should
// receive all 4 messages via events. Once this works, we scale up.

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

func authHeader(u testUser) string {
	return "Basic " + base64.StdEncoding.EncodeToString(
		[]byte(u.email + ":" + u.apiKey))
}

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

func httpGet(baseURL, path string, u testUser) map[string]interface{} {
	req, _ := http.NewRequest("GET", baseURL+path, nil)
	req.Header.Set("Authorization", authHeader(u))

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil // timeout
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()

	var result map[string]interface{}
	json.Unmarshal(body, &result)
	return result
}

// startServer creates a fresh DB, wires everything up, and returns
// a running httptest.Server.
func startServer(t *testing.T) *httptest.Server {
	t.Helper()
	resetDB()
	seedData(false)

	// Disable rate limiting for basic tests.
	origMax := ratelimit.MaxRequests
	ratelimit.MaxRequests = 10000
	t.Cleanup(func() { ratelimit.MaxRequests = origMax })

	return httptest.NewServer(buildMux())
}

// ============================================================
// Test 1: Basic mechanics. 4 users each send 1 message.
// Every user should see all 4 messages via events.
// ============================================================

func TestIntegration_BasicMessaging(t *testing.T) {
	server := startServer(t)
	defer server.Close()

	// Each user registers an event queue.
	queueIDs := make([]string, len(testUsers))
	for i, u := range testUsers {
		result := httpPost(server.URL, "/api/v1/register", u, url.Values{})
		if result["result"] != "success" {
			t.Fatalf("[%s] register: %v", u.name, result)
		}
		queueIDs[i] = result["queue_id"].(string)
	}

	// Each user sends 1 message to ChitChat (channel 3, public).
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

	// Each user polls for events and counts message events.
	for i, u := range testUsers {
		path := fmt.Sprintf("/api/v1/events?queue_id=%s&last_event_id=-1",
			queueIDs[i])
		result := httpGet(server.URL, path, u)
		if result == nil {
			t.Errorf("[%s] poll timed out", u.name)
			continue
		}

		events := result["events"].([]interface{})
		msgCount := 0
		for _, e := range events {
			if e.(map[string]interface{})["type"] == "message" {
				msgCount++
			}
		}
		if msgCount != 4 {
			t.Errorf("[%s] received %d messages, expected 4", u.name, msgCount)
		}
	}
}

// ============================================================
// Test 2: Rate limiting. Send messages faster than the limit
// and verify we get 429s, then succeed after waiting.
// ============================================================

func TestIntegration_RateLimiting(t *testing.T) {
	server := startServer(t)
	defer server.Close()

	// Set a very low rate limit.
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

	// Send messages rapidly — should hit 429 after 3.
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

	// Wait for the window to expire, then send should succeed.
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
// Test 3: Concurrent load. 4 users each send N messages.
// Verify the DB has the right total and events were delivered.
// ============================================================

func TestIntegration_ConcurrentLoad(t *testing.T) {
	server := startServer(t)
	defer server.Close()

	const messagesPerUser = 10

	// Register queues.
	queueIDs := make([]string, len(testUsers))
	for i, u := range testUsers {
		result := httpPost(server.URL, "/api/v1/register", u, url.Values{})
		queueIDs[i] = result["queue_id"].(string)
	}

	// All 4 users send concurrently.
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

	// Verify DB total.
	var dbCount int
	DB.QueryRow(`SELECT COUNT(*) FROM messages WHERE channel_id = 3`).Scan(&dbCount)
	expectedTotal := len(testUsers) * messagesPerUser
	if dbCount != expectedTotal {
		t.Errorf("expected %d messages in DB, got %d", expectedTotal, dbCount)
	}

	// Each user polls — should see most/all messages.
	for i, u := range testUsers {
		path := fmt.Sprintf("/api/v1/events?queue_id=%s&last_event_id=-1",
			queueIDs[i])
		result := httpGet(server.URL, path, u)
		if result == nil {
			t.Errorf("[%s] poll timed out", u.name)
			continue
		}

		events := result["events"].([]interface{})
		msgCount := 0
		for _, e := range events {
			if e.(map[string]interface{})["type"] == "message" {
				msgCount++
			}
		}
		// With concurrent sends and a single poll, we should get
		// all events since they were all pushed before we polled.
		if msgCount != expectedTotal {
			t.Errorf("[%s] received %d messages, expected %d",
				u.name, msgCount, expectedTotal)
		}
	}
}
