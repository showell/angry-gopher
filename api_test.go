package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
)

// --- Test helpers ---

// resetDB creates a fresh in-memory SQLite database. Each call to
// initDB(":memory:") gives us a brand new database with empty tables,
// so tests are fully isolated from each other.
func resetDB() {
	initDB(":memory:")
}

// seedMessage inserts a message into the test DB. The users and
// channels already exist from seedData() (called by resetDB), so we
// only need to ensure the topic exists and insert the message.
// "OR IGNORE" makes repeated calls with different message IDs safe —
// they share the same topic row without conflicting on the primary key.
func seedMessage(t *testing.T, messageID int) {
	t.Helper()
	DB.Exec(`INSERT OR IGNORE INTO topics (topic_id, channel_id, topic_name) VALUES (1, 1, 'test')`)
	DB.Exec(`INSERT OR IGNORE INTO messages (id, content, sender_id, stream_id, topic_id, timestamp) VALUES (?, '<p>test</p>', 1, 1, 1, 1000)`, messageID)
}

// sendMessage calls handleSendMessage and returns the recorded response.
func sendMessage(t *testing.T, streamID int, topic, content string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{}
	form.Set("to", strconv.Itoa(streamID))
	form.Set("topic", topic)
	form.Set("content", content)
	form.Set("type", "stream")

	req := httptest.NewRequest("POST", "/api/v1/messages", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	rec := httptest.NewRecorder()
	handleSendMessage(rec, req)
	return rec
}

// postFlags calls handleUpdateFlags with form-encoded parameters and
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
	handleUpdateFlags(rec, req)
	return rec
}

// getMessages calls handleMessages and returns the parsed "messages"
// array. JSON numbers decode as float64 in Go, so callers that need
// integer fields (like message id) must convert with int(f).
func getMessages(t *testing.T, anchor string) []map[string]interface{} {
	t.Helper()
	req := httptest.NewRequest("GET", "/api/v1/messages?anchor="+anchor+"&num_before=100", nil)
	rec := httptest.NewRecorder()
	handleMessages(rec, req)

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
	flags := make([]string, len(raw))
	for i, f := range raw {
		flags[i] = f.(string)
	}
	return flags
}

func hasFlag(flags []string, target string) bool {
	for _, f := range flags {
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

	flags := flagsFor(t, msgs[0])
	if !hasFlag(flags, "read") {
		t.Errorf("expected 'read' flag, got %v", flags)
	}
}

func TestMarkUnreadThenRead(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	postFlags(t, "remove", "read", "[1]")
	{
		flags := flagsFor(t, getMessages(t, "newest")[0])
		if hasFlag(flags, "read") {
			t.Errorf("should be unread, got %v", flags)
		}
	}

	postFlags(t, "add", "read", "[1]")
	{
		flags := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(flags, "read") {
			t.Errorf("should be read again, got %v", flags)
		}
	}
}

func TestStarredFlag(t *testing.T) {
	resetDB()
	seedMessage(t, 1)

	postFlags(t, "add", "starred", "[1]")
	{
		flags := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(flags, "starred") {
			t.Errorf("should be starred, got %v", flags)
		}
		if !hasFlag(flags, "read") {
			t.Errorf("starring should not remove read, got %v", flags)
		}
	}

	postFlags(t, "remove", "starred", "[1]")
	{
		flags := flagsFor(t, getMessages(t, "newest")[0])
		if hasFlag(flags, "starred") {
			t.Errorf("should no longer be starred, got %v", flags)
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
		flags := flagsFor(t, msg)
		switch id {
		case 1, 3:
			if hasFlag(flags, "read") {
				t.Errorf("message %d should be unread, got %v", id, flags)
			}
		case 2:
			if !hasFlag(flags, "read") {
				t.Errorf("message %d should still be read, got %v", id, flags)
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
	handleUpdateFlags(rec, req)

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
		flags := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(flags, "read") {
			t.Errorf("should still be read after double add, got %v", flags)
		}
	}

	// Starring twice should not error (INSERT OR IGNORE in SQLite
	// silently skips if the row already exists).
	postFlags(t, "add", "starred", "[1]")
	postFlags(t, "add", "starred", "[1]")
	{
		flags := flagsFor(t, getMessages(t, "newest")[0])
		if !hasFlag(flags, "starred") {
			t.Errorf("should still be starred after double add, got %v", flags)
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

	// The response includes the new message ID.
	if body["id"] == nil {
		t.Fatal("expected id in response")
	}

	// Verify the message is retrievable and has HTML content.
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

	// Should contain both the link and an appended inline image preview.
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

	// Both messages should share the same topic.
	if msgs[0]["subject"] != msgs[1]["subject"] {
		t.Errorf("topics should match: %v vs %v", msgs[0]["subject"], msgs[1]["subject"])
	}
}

func TestSendMessageDefaultsToRead(t *testing.T) {
	resetDB()

	sendMessage(t, 1, "test", "content")

	flags := flagsFor(t, getMessages(t, "newest")[0])
	if !hasFlag(flags, "read") {
		t.Errorf("sent messages should default to read, got %v", flags)
	}
}

func TestSendMessageMissingParams(t *testing.T) {
	resetDB()

	form := url.Values{}
	form.Set("to", "1")
	// Missing topic and content.
	req := httptest.NewRequest("POST", "/api/v1/messages", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	handleSendMessage(rec, req)

	body := parseJSON(t, rec)
	if body["result"] != "error" {
		t.Errorf("expected error for missing params, got %v", body["result"])
	}
}
