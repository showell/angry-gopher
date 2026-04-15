// Shared test infrastructure for all test files.
//
// All test files are in package main, so these helpers are available
// everywhere. Each test calls resetDB() to get a fresh in-memory
// SQLite database seeded with users, channels, and subscriptions.

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"angry-gopher/flags"
	"angry-gopher/messages"
	"angry-gopher/presence"
	"angry-gopher/ratelimit"
	"angry-gopher/reactions"
)

// resetDB creates a fresh in-memory SQLite database and wires up
// all package-level DB references. Each call gives us a brand new
// database with empty tables, so tests are fully isolated.
func resetDB() {
	// Always use in-memory DB for tests — never touch a file.
	initDB(":memory:")
	wireDB()
	ratelimit.Reset()
	presence.Reset()
	seedData(false)
}

// --- Auth helpers ---
//
// Post-user-rip: auth is trust-on-assertion. setAuth sets the
// X-Gopher-User header which auth.Authenticate reads.
//
// The signature keeps a legacy (email, apiKey) overload so older
// tests compile without edits — any arg that looks like an email
// is mapped to a current user name. Joe/Apoorva map to Claude.

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
			name = "Claude" // joe, apoorva, and any other legacy user → Claude
		}
	}
	req.Header.Set("X-Gopher-User", name)
}

func steveAuth(req *http.Request)  { setAuth(req, "Steve") }
func claudeAuth(req *http.Request) { setAuth(req, "Claude") }
func joeAuth(req *http.Request)    { setAuth(req, "Claude") } // legacy shim

// --- Data helpers ---

// seedMessage inserts a message into the test DB. The users and
// channels already exist from seedData() (called by resetDB), so we
// only need to ensure the topic exists and insert the message.
// "OR IGNORE" makes repeated calls with different message IDs safe —
// they share the same topic row without conflicting on the primary key.
func seedMessage(t *testing.T, messageID int) {
	t.Helper()
	DB.Exec(`INSERT OR IGNORE INTO message_content (content_id, markdown, html) VALUES (?, 'test', '<p>test</p>')`, messageID)
	DB.Exec(`INSERT OR IGNORE INTO topics (topic_id, channel_id, topic_name) VALUES (1, 1, 'test')`)
	DB.Exec(`INSERT OR IGNORE INTO messages (id, content_id, sender_id, channel_id, topic_id, timestamp) VALUES (?, ?, 1, 1, 1, 1000)`, messageID, messageID)
}

// --- Request helpers ---

// sendMessage calls HandleSendMessage as Steve and returns the recorded response.
func sendMessage(t *testing.T, channelID int, topic, content string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{}
	form.Set("to", strconv.Itoa(channelID))
	form.Set("topic", topic)
	form.Set("content", content)
	form.Set("type", "stream")

	req := httptest.NewRequest("POST", "/api/v1/messages", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)

	rec := httptest.NewRecorder()
	messages.HandleSendMessage(rec, req)
	return rec
}

func editMessage(t *testing.T, messageID int, content string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{}
	form.Set("content", content)

	path := "/api/v1/messages/" + strconv.Itoa(messageID)
	req := httptest.NewRequest("PATCH", path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)

	rec := httptest.NewRecorder()
	messages.HandleEditMessage(rec, req)
	return rec
}

// postFlags calls HandleUpdateFlags as Steve.
func postFlags(t *testing.T, op, flag, messagesJSON string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{}
	form.Set("op", op)
	form.Set("flag", flag)
	form.Set("messages", messagesJSON)

	req := httptest.NewRequest("POST", "/api/v1/messages/flags", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)

	rec := httptest.NewRecorder()
	flags.HandleUpdateFlags(rec, req)
	return rec
}

func postReaction(t *testing.T, method string, messageID int, emojiName, emojiCode string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{}
	form.Set("emoji_name", emojiName)
	form.Set("emoji_code", emojiCode)
	form.Set("reaction_type", "unicode_emoji")

	path := "/api/v1/messages/" + strconv.Itoa(messageID) + "/reactions"
	req := httptest.NewRequest(method, path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	steveAuth(req)

	rec := httptest.NewRecorder()
	reactions.HandleReaction(rec, req)
	return rec
}

// getMessages calls HandleGetMessages as Steve and returns the parsed
// "messages" array. JSON numbers decode as float64 in Go, so callers
// that need integer fields (like message id) must convert with int(f).
func getMessages(t *testing.T, anchor string) []map[string]interface{} {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/v1/messages?anchor="+anchor+"&num_before=100", nil)
	steveAuth(req)
	rec := httptest.NewRecorder()
	messages.HandleGetMessages(rec, req)

	body := parseJSON(t, rec)
	raw := body["messages"].([]interface{})
	msgs := make([]map[string]interface{}, len(raw))
	for i, m := range raw {
		msgs[i] = m.(map[string]interface{})
	}
	return msgs
}

// --- Response helpers ---

func parseJSON(t *testing.T, rec *httptest.ResponseRecorder) map[string]interface{} {
	t.Helper()
	var result map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil {
		t.Fatalf("failed to parse JSON response: %v", err)
	}
	return result
}

func flagsFor(t *testing.T, msg map[string]interface{}) []string {
	t.Helper()
	raw := msg["flags"].([]interface{})
	f := make([]string, len(raw))
	for i, v := range raw {
		f[i] = v.(string)
	}
	return f
}

func hasFlag(flagList []string, target string) bool {
	for _, f := range flagList {
		if f == target {
			return true
		}
	}
	return false
}
