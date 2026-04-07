package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"angry-gopher/auth"
	"angry-gopher/channels"
	"angry-gopher/flags"
	"angry-gopher/messages"
)

// --- Test helpers ---

// resetDB creates a fresh in-memory SQLite database and wires up
// all package-level DB references. Each call gives us a brand new
// database with empty tables, so tests are fully isolated.
func resetDB() {
	initDB(":memory:")
	auth.DB = DB
	channels.DB = DB
	messages.DB = DB
	flags.DB = DB
	channels.RenderMarkdown = renderMarkdown
	messages.RenderMarkdown = renderMarkdown
}

// setAuth adds a Basic auth header for the given user. The credentials
// must match what seedData() inserts (e.g. "steve@example.com" / "steve-api-key").
func setAuth(req *http.Request, email, apiKey string) {
	encoded := base64.StdEncoding.EncodeToString([]byte(email + ":" + apiKey))
	req.Header.Set("Authorization", "Basic "+encoded)
}

// steveAuth adds Steve's auth header — the default test user.
func steveAuth(req *http.Request) {
	setAuth(req, "steve@example.com", "steve-api-key")
}

// seedMessage inserts a message into the test DB. The users and
// channels already exist from seedData() (called by resetDB), so we
// only need to ensure the topic exists and insert the message.
// "OR IGNORE" makes repeated calls with different message IDs safe —
// they share the same topic row without conflicting on the primary key.
func seedMessage(t *testing.T, messageID int) {
	t.Helper()
	DB.Exec(`INSERT OR IGNORE INTO topics (topic_id, channel_id, topic_name) VALUES (1, 1, 'test')`)
	DB.Exec(`INSERT OR IGNORE INTO messages (id, content, sender_id, channel_id, topic_id, timestamp) VALUES (?, '<p>test</p>', 1, 1, 1, 1000)`, messageID)
}

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

// postFlags calls HandleUpdateFlags with form-encoded parameters and
// returns the recorded response. httptest.NewRecorder() captures the
// response in memory (no real HTTP).
func postFlags(t *testing.T, op, flag, messagesJSON string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{}
	form.Set("op", op)
	form.Set("flag", flag)
	form.Set("messages", messagesJSON)

	req := httptest.NewRequest("POST", "/api/v1/messages/flags", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	rec := httptest.NewRecorder()
	flags.HandleUpdateFlags(rec, req)
	return rec
}

// getMessages calls HandleGetMessages and returns the parsed "messages"
// array. JSON numbers decode as float64 in Go, so callers that need
// integer fields (like message id) must convert with int(f).
func getMessages(t *testing.T, anchor string) []map[string]interface{} {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/v1/messages?anchor="+anchor+"&num_before=100", nil)
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

// parseJSON unmarshals the response body into a generic map.
func parseJSON(t *testing.T, rec *httptest.ResponseRecorder) map[string]interface{} {
	t.Helper()
	var result map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &result); err != nil {
		t.Fatalf("failed to parse JSON response: %v", err)
	}
	return result
}

// flagsFor extracts the "flags" string slice from a message map.
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

// --- Tests ---

func TestMessagesDefaultToRead(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	msgs := getMessages(t, "newest")
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}

	f := flagsFor(t, msgs[0])
	if !hasFlag(f, "read") {
		t.Errorf("expected 'read' flag, got %v", f)
	}
}

func TestMarkUnreadThenRead(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	postFlags(t, "remove", "read", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if hasFlag(f, "read") {
			t.Errorf("should be unread, got %v", f)
		}
	}

	postFlags(t, "add", "read", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(f, "read") {
			t.Errorf("should be read again, got %v", f)
		}
	}
}

func TestStarredFlag(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	postFlags(t, "add", "starred", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(f, "starred") {
			t.Errorf("should be starred, got %v", f)
		}
		if !hasFlag(f, "read") {
			t.Errorf("starring should not remove read, got %v", f)
		}
	}

	postFlags(t, "remove", "starred", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if hasFlag(f, "starred") {
			t.Errorf("should no longer be starred, got %v", f)
		}
	}
}

func TestBatchFlagUpdate(t *testing.T) {
	resetDB()
	seedMessage(t, 1)
	seedMessage(t, 2)
	seedMessage(t, 3)

	// Mark 1 and 3 as unread; 2 stays read.
	postFlags(t, "remove", "read", "[1,3]")

	for _, msg := range getMessages(t, "newest") {
		id := int(msg["id"].(float64))
		f := flagsFor(t, msg)
		switch id {
		case 1, 3:
			if hasFlag(f, "read") {
				t.Errorf("message %d should be unread, got %v", id, f)
			}
		case 2:
			if !hasFlag(f, "read") {
				t.Errorf("message %d should still be read, got %v", id, f)
			}
		}
	}
}

func TestFlagUpdateResponse(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	rec := postFlags(t, "add", "starred", "[1]")
	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rec.Code)
	}
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Errorf("expected result=success, got %v", body["result"])
	}
}

func TestFlagUpdateMissingParams(t *testing.T) {
	resetDB()

	req := httptest.NewRequest("POST", "/api/v1/messages/flags", nil)
	rec := httptest.NewRecorder()
	flags.HandleUpdateFlags(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for missing params, got %v", body["result"])
	}
}

func TestFlagUpdateInvalidOp(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	rec := postFlags(t, "toggle", "read", "[1]")
	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for invalid op, got %v", body["result"])
	}
}

func TestIdempotentFlagOperations(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	// Adding read twice (already read by default) should not error.
	postFlags(t, "add", "read", "[1]")
	postFlags(t, "add", "read", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(f, "read") {
			t.Errorf("should still be read after double add, got %v", f)
		}
	}

	// Starring twice should not error (INSERT OR IGNORE in SQLite
	// silently skips if the row already exists).
	postFlags(t, "add", "starred", "[1]")
	postFlags(t, "add", "starred", "[1]")
	{
		f := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(f, "starred") {
			t.Errorf("should still be starred after double add, got %v", f)
		}
	}
}

// --- Send message tests ---

func TestSendMessage(t *testing.T) {
	resetDB()

	rec := sendMessage(t, 1, "greetings", "hello world")
	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}

	if body["id"] == nil {
		t.Fatal("expected id in response")
	}

	msgs := getMessages(t, "newest")
	if len(msgs) != 1 {
		t.Fatalf("expected 1 message, got %d", len(msgs))
	}
	msg := msgs[0]
	if msg["subject"] != "greetings" {
		t.Errorf("expected topic 'greetings', got %v", msg["subject"])
	}
	// Goldmark wraps plain text in <p> tags.
	if msg["content"] != "<p>hello world</p>\n" {
		t.Errorf("expected HTML content, got %q", msg["content"])
	}
}

func TestSendMessageMarkdown(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "code", "here is `inline code` and **bold**")

	msg := getMessages(t, "newest")[0]
	content := msg["content"].(string)

	if !strings.Contains(content, "<code>inline code</code>") {
		t.Errorf("expected inline code in HTML, got %q", content)
	}
	if !strings.Contains(content, "<strong>bold</strong>") {
		t.Errorf("expected bold in HTML, got %q", content)
	}
}

func TestSendMessageImagePreview(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "photos", "check this out [photo](/user_uploads/1/cat.png)")

	msg := getMessages(t, "newest")[0]
	content := msg["content"].(string)

	if !strings.Contains(content, `<a href="/user_uploads/1/cat.png">`) {
		t.Errorf("expected link in HTML, got %q", content)
	}
	if !strings.Contains(content, `<img src="/user_uploads/1/cat.png">`) {
		t.Errorf("expected img preview in HTML, got %q", content)
	}
}

func TestSendMessageNoPreviewForNonImage(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "files", "get the doc [report](/user_uploads/1/report.pdf)")

	msg := getMessages(t, "newest")[0]
	content := msg["content"].(string)

	if strings.Contains(content, "<img") {
		t.Errorf("should not have image preview for PDF, got %q", content)
	}
}

func TestSendMessageCreatesNewTopic(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "new topic", "first message")
	sendMessage(t, 1, "new topic", "second message")

	msgs := getMessages(t, "newest")
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(msgs))
	}

	if msgs[0]["subject"] != msgs[1]["subject"] {
		t.Errorf("topics should match: %v vs %v", msgs[0]["subject"], msgs[1]["subject"])
	}
}

func TestSendMessageDefaultsToRead(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "test", "content")

	f := flagsFor(t, getMessages(t, "newest")[0])
	if !hasFlag(f, "read") {
		t.Errorf("sent messages should default to read, got %v", f)
	}
}

func TestSendMessageMissingParams(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("to", "1")
	req := httptest.NewRequest("POST", "/api/v1/messages", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	messages.HandleSendMessage(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for missing params, got %v", body["result"])
	}
}

// --- Update channel description tests ---

func TestUpdateChannelDescription(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("description", "A channel for **testing**")
	req := httptest.NewRequest("PATCH", "/api/v1/streams/1", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	channels.HandleUpdateChannel(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "success" {
		t.Fatalf("expected success, got %v", body["result"])
	}

	var desc, renderedDesc string
	DB.QueryRow(`SELECT description, rendered_description FROM channels WHERE channel_id = 1`).
		Scan(&desc, &renderedDesc)

	if desc != "A channel for **testing**" {
		t.Errorf("expected raw description stored, got %q", desc)
	}
	if !strings.Contains(renderedDesc, "<strong>testing</strong>") {
		t.Errorf("expected rendered HTML, got %q", renderedDesc)
	}
}
